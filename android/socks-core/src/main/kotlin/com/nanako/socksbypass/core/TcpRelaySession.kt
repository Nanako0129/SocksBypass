package com.nanako.socksbypass.core

import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketException
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

/**
 * One accepted client TCP connection: SOCKS handshake + CONNECT bidirectional relay
 * with proper half-close, or UDP ASSOCIATE lifecycle ownership.
 */
class TcpRelaySession(
    private val client: Socket,
    private val upstream: UpstreamNetwork,
    private val counters: TrafficCounters,
    private val connectTimeoutMs: Int = 10_000,
    private val soTimeoutMs: Int = 0,
    private val emit: (RelayEvent) -> Unit,
    private val onClosed: (UUID) -> Unit,
    private val udpFactory: (
        controlPeer: InetAddress,
        declared: Socks5HandshakeParser.Target,
        localBind: InetAddress?,
    ) -> UdpAssociation? = { peer, declared, local ->
        UdpAssociation(
            controlPeer = peer,
            declaredClientPort = declared.port.takeIf { it != 0 },
            lanBindAddress = local,
            upstream = upstream,
            counters = counters,
        )
    },
) {
    val id: UUID = UUID.randomUUID()
    private val cleaned = AtomicBoolean(false)
    private var target: Socket? = null
    private var udp: UdpAssociation? = null
    private val clientIn: InputStream = client.getInputStream()
    private val clientOut: OutputStream = client.getOutputStream()

    fun start() {
        counters.sessionOpened(id)
        emit(RelayEvent.SessionOpened)
        thread(name = "socks-session-$id", isDaemon = true) {
            try {
                runHandshakeAndRelay()
            } catch (_: Exception) {
                // cleanup below
            } finally {
                cleanup()
            }
        }
    }

    fun cancel() {
        cleanup()
    }

    private fun runHandshakeAndRelay() {
        client.soTimeout = 30_000
        val parser = Socks5HandshakeParser()
        val buf = ByteArray(8 * 1024)
        while (!parser.isActive && !parser.isClosed) {
            val n = clientIn.read(buf)
            if (n < 0) {
                val finished = parser.finish()
                writeAll(finished.replies)
                return
            }
            val output = parser.feed(buf.copyOf(n))
            writeAll(output.replies)
            if (output.shouldClose && output.request == null) return
            val request = output.request ?: continue
            when (request.command) {
                Socks5HandshakeParser.Command.Connect -> handleConnect(request)
                Socks5HandshakeParser.Command.UdpAssociate -> handleUdp(request)
            }
            return
        }
    }

    private fun handleConnect(request: Socks5HandshakeParser.Request) {
        if (!upstream.isAvailable) {
            writeAll(listOf(Socks5HandshakeParser.requestReply(0x03)))
            emit(RelayEvent.ConnectRejected(0x03))
            return
        }
        val socket: Socket
        try {
            socket = connectUpstream(request.target)
        } catch (e: UpstreamUnavailableException) {
            writeAll(listOf(Socks5HandshakeParser.requestReply(0x03)))
            emit(RelayEvent.ConnectRejected(0x03))
            return
        } catch (_: Exception) {
            writeAll(listOf(Socks5HandshakeParser.requestReply(0x05)))
            emit(RelayEvent.ConnectRejected(0x05))
            return
        }
        target = socket
        val bound = boundEndpoint(socket)
        writeAll(listOf(Socks5HandshakeParser.requestReply(0x00, bound)))
        emit(RelayEvent.ConnectEstablished)
        client.soTimeout = soTimeoutMs
        socket.soTimeout = soTimeoutMs
        if (request.firstPayload.isNotEmpty()) {
            socket.getOutputStream().write(request.firstPayload)
            socket.getOutputStream().flush()
            counters.recordCommitted(request.firstPayload.size, TrafficCounters.Direction.Upload)
        }
        pumpBidirectional(client, socket)
    }

    private fun handleUdp(request: Socks5HandshakeParser.Request) {
        if (!upstream.isAvailable) {
            writeAll(listOf(Socks5HandshakeParser.requestReply(0x03)))
            emit(RelayEvent.UdpAssociateFailed)
            return
        }
        val peer = client.inetAddress
            ?: run {
                writeAll(listOf(Socks5HandshakeParser.requestReply(0x01)))
                emit(RelayEvent.UdpAssociateFailed)
                return
            }
        val local = try {
            client.localAddress
        } catch (_: Exception) {
            null
        }
        val association = try {
            udpFactory(peer, request.target, local)
        } catch (_: Exception) {
            null
        }
        if (association == null) {
            writeAll(listOf(Socks5HandshakeParser.requestReply(0x01)))
            emit(RelayEvent.UdpAssociateFailed)
            return
        }
        udp = association
        counters.associationOpened(id)
        val reply = association.successReply()
        writeAll(listOf(reply))
        emit(RelayEvent.UdpAssociated)
        association.start()
        // Hold control connection open; end association when client closes.
        try {
            val buf = ByteArray(1024)
            while (true) {
                val n = clientIn.read(buf)
                if (n < 0) break
            }
        } catch (_: Exception) {
            // control closed
        } finally {
            association.close()
            counters.associationClosed(id)
        }
    }

    private fun connectUpstream(target: Socks5HandshakeParser.Target): Socket {
        if (!upstream.isAvailable) throw UpstreamUnavailableException()
        val addresses = try {
            // Prefer numeric parse to avoid DNS when ATYP was IP
            val numeric = tryParseNumeric(target.address)
            if (numeric != null) listOf(numeric) else upstream.resolve(target.address)
        } catch (e: UpstreamUnavailableException) {
            throw e
        } catch (_: Exception) {
            emptyList()
        }
        if (addresses.isEmpty()) throw IOException("resolve failed")

        var last: Exception? = null
        for (addr in addresses) {
            var socket: Socket? = null
            try {
                socket = upstream.createTcpSocket()
                socket.tcpNoDelay = true
                socket.connect(InetSocketAddress(addr, target.port), connectTimeoutMs)
                return socket
            } catch (e: Exception) {
                last = e
                try {
                    socket?.close()
                } catch (_: Exception) {
                }
            }
        }
        throw last ?: IOException("connect failed")
    }

    private fun tryParseNumeric(host: String): InetAddress? = try {
        if (host.matches(Regex("""\d+\.\d+\.\d+\.\d+"""))) {
            InetAddress.getByName(host)
        } else if (host.contains(':')) {
            InetAddress.getByName(host)
        } else {
            null
        }
    } catch (_: Exception) {
        null
    }

    private fun boundEndpoint(socket: Socket): Socks5HandshakeParser.Companion.BoundEndpoint? {
        val addr = socket.localAddress ?: return null
        val port = socket.localPort
        val raw = addr.address
        return when (raw.size) {
            4 -> Socks5HandshakeParser.Companion.BoundEndpoint(0x01, raw, port)
            16 -> Socks5HandshakeParser.Companion.BoundEndpoint(0x04, raw, port)
            else -> null
        }
    }

    /**
     * Two pumps; on clean EOF call [Socket.shutdownOutput] on the other side.
     * Errors close both ends. Cleanup is idempotent.
     */
    private fun pumpBidirectional(client: Socket, target: Socket) {
        val clientToTargetDone = AtomicBoolean(false)
        val targetToClientDone = AtomicBoolean(false)
        val error = AtomicBoolean(false)

        val upload = thread(name = "socks-up-$id", isDaemon = true) {
            try {
                pumpOneWay(
                    from = client.getInputStream(),
                    to = target.getOutputStream(),
                    direction = TrafficCounters.Direction.Upload,
                    peer = target,
                    onCleanEof = {
                        try {
                            target.shutdownOutput()
                        } catch (_: Exception) {
                        }
                    },
                )
            } catch (_: Exception) {
                error.set(true)
            } finally {
                clientToTargetDone.set(true)
                if (error.get()) {
                    forceClose(client, target)
                }
            }
        }
        val download = thread(name = "socks-down-$id", isDaemon = true) {
            try {
                pumpOneWay(
                    from = target.getInputStream(),
                    to = client.getOutputStream(),
                    direction = TrafficCounters.Direction.Download,
                    peer = client,
                    onCleanEof = {
                        try {
                            client.shutdownOutput()
                        } catch (_: Exception) {
                        }
                    },
                )
            } catch (_: Exception) {
                error.set(true)
            } finally {
                targetToClientDone.set(true)
                if (error.get()) {
                    forceClose(client, target)
                }
            }
        }
        upload.join()
        download.join()
        if (error.get()) {
            forceClose(client, target)
        }
    }

    private fun pumpOneWay(
        from: InputStream,
        to: OutputStream,
        direction: TrafficCounters.Direction,
        peer: Socket,
        onCleanEof: () -> Unit,
    ) {
        val buf = ByteArray(64 * 1024)
        while (true) {
            val n = try {
                from.read(buf)
            } catch (e: SocketException) {
                if (cleaned.get()) return
                throw e
            }
            if (n < 0) {
                onCleanEof()
                return
            }
            if (n == 0) continue
            try {
                to.write(buf, 0, n)
                to.flush()
            } catch (e: Exception) {
                if (cleaned.get()) return
                throw e
            }
            counters.recordCommitted(n, direction)
        }
    }

    private fun forceClose(vararg sockets: Socket) {
        for (s in sockets) {
            try {
                s.close()
            } catch (_: Exception) {
            }
        }
    }

    private fun writeAll(replies: List<ByteArray>) {
        for (r in replies) {
            clientOut.write(r)
        }
        clientOut.flush()
    }

    private fun cleanup() {
        if (!cleaned.compareAndSet(false, true)) return
        try {
            udp?.close()
        } catch (_: Exception) {
        }
        udp = null
        try {
            target?.close()
        } catch (_: Exception) {
        }
        target = null
        try {
            client.close()
        } catch (_: Exception) {
        }
        counters.sessionClosed(id)
        emit(RelayEvent.SessionClosed)
        onClosed(id)
    }
}
