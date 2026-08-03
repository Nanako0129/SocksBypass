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
 *
 * [TrafficCounters.activeTcp] counts CONNECT relays only (iOS parity), not control
 * sockets that later become UDP ASSOCIATE.
 */
class TcpRelaySession(
    private val client: Socket,
    private val upstream: UpstreamNetwork,
    private val counters: TrafficCounters,
    private val connectTimeoutMs: Int = 10_000,
    private val soTimeoutMs: Int = 0,
    private val destinationPolicy: DestinationPolicy = DestinationPolicy.PRODUCTION,
    private val emit: (RelayEvent) -> Unit,
    private val onClosed: (UUID) -> Unit,
    private val udpFactory: (
        controlPeer: InetAddress,
        declared: Socks5HandshakeParser.Target,
        localBind: InetAddress?,
        onFailure: () -> Unit,
    ) -> UdpAssociation? = { peer, declared, local, onFail ->
        UdpAssociation(
            controlPeer = peer,
            declaredClientPort = declared.port.takeIf { it != 0 },
            lanBindAddress = local,
            upstream = upstream,
            counters = counters,
            destinationPolicy = destinationPolicy,
            onFailure = onFail,
        )
    },
) {
    val id: UUID = UUID.randomUUID()
    private val cleaned = AtomicBoolean(false)
    private val started = AtomicBoolean(false)
    private var target: Socket? = null
    private var udp: UdpAssociation? = null
    private val clientIn: InputStream = client.getInputStream()
    private val clientOut: OutputStream = client.getOutputStream()
    /** True only after CONNECT success reply; gates activeTcp counter. */
    private val tcpCounted = AtomicBoolean(false)

    /**
     * Begin the session worker. Idempotent: cancel-before-start or double-start
     * does not open counters or emit SessionOpened.
     */
    fun start() {
        if (cleaned.get()) return
        if (!started.compareAndSet(false, true)) return
        if (cleaned.get()) return
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
        if (cleaned.get()) return
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
        } catch (_: DestinationDeniedException) {
            // RFC 1928 REP 0x02 not allowed by ruleset
            writeAll(listOf(Socks5HandshakeParser.requestReply(0x02)))
            emit(RelayEvent.ConnectRejected(0x02))
            return
        } catch (_: Exception) {
            writeAll(listOf(Socks5HandshakeParser.requestReply(0x05)))
            emit(RelayEvent.ConnectRejected(0x05))
            return
        }
        // cancel() may have run while DNS/connect was blocked — never publish a late socket.
        if (cleaned.get()) {
            try {
                socket.close()
            } catch (_: Exception) {
            }
            return
        }
        target = socket
        if (cleaned.get()) {
            try {
                socket.close()
            } catch (_: Exception) {
            }
            target = null
            return
        }
        val bound = boundEndpoint(socket)
        writeAll(listOf(Socks5HandshakeParser.requestReply(0x00, bound)))
        // CONNECT-only metric (matches iOS activeTCP). Must be cancel-safe: if
        // stop()/cleanup raced after the success reply, do not leave a stale
        // activeTcp entry for the next proxy start (Codex P2).
        if (!registerTcpCounter()) {
            try {
                socket.close()
            } catch (_: Exception) {
            }
            target = null
            return
        }
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

    /**
     * @return false if the session was already cleaned — caller must not pump.
     */
    private fun registerTcpCounter(): Boolean {
        if (cleaned.get()) return false
        if (!tcpCounted.compareAndSet(false, true)) return !cleaned.get()
        counters.sessionOpened(id)
        if (cleaned.get()) {
            // cleanup() already ran without seeing tcpCounted; undo the late open.
            counters.sessionClosed(id)
            tcpCounted.set(false)
            return false
        }
        return true
    }

    private fun handleUdp(request: Socks5HandshakeParser.Request) {
        if (cleaned.get()) return
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
            udpFactory(peer, request.target, local) {
                // Cellular/socket death: drop control TCP so the session cleans up.
                try {
                    client.close()
                } catch (_: Exception) {
                }
            }
        } catch (_: Exception) {
            null
        }
        if (association == null) {
            writeAll(listOf(Socks5HandshakeParser.requestReply(0x01)))
            emit(RelayEvent.UdpAssociateFailed)
            return
        }
        // Counter + reply must share a cleanup path even if writeAll throws.
        udp = association
        counters.associationOpened(id)
        var associationCounted = true
        try {
            if (cleaned.get()) return
            val reply = association.successReply()
            writeAll(listOf(reply))
            emit(RelayEvent.UdpAssociated)
            association.start()
            // Handshake used a 30s read timeout so a stuck client cannot hang forever.
            // UDP ASSOCIATE keeps the control TCP open indefinitely (RFC 1928); idle
            // must not tear the association down — only real EOF / error should.
            client.soTimeout = 0
            val buf = ByteArray(1024)
            while (true) {
                val n = clientIn.read(buf)
                if (n < 0) break
            }
        } catch (_: Exception) {
            // control closed, reset, or reply write failed
        } finally {
            association.close()
            if (associationCounted) {
                counters.associationClosed(id)
                associationCounted = false
            }
            udp = null
        }
    }

    private fun connectUpstream(target: Socks5HandshakeParser.Target): Socket {
        if (cleaned.get()) throw IOException("session cancelled")
        if (!upstream.isAvailable) throw UpstreamUnavailableException()
        val addresses = try {
            // Strict literal only — never process-default DNS (see StrictIpLiteral).
            val numeric = StrictIpLiteral.parse(target.address)
            if (numeric != null) listOf(numeric) else upstream.resolve(target.address)
        } catch (e: UpstreamUnavailableException) {
            throw e
        } catch (_: Exception) {
            emptyList()
        }
        if (addresses.isEmpty()) throw IOException("resolve failed")
        if (cleaned.get()) throw IOException("session cancelled")

        val allowed = addresses.filter { destinationPolicy.isAllowed(it) }
        if (allowed.isEmpty()) {
            throw DestinationDeniedException("all resolved addresses denied by policy")
        }

        var last: Exception? = null
        for (addr in allowed) {
            if (cleaned.get()) throw IOException("session cancelled")
            var socket: Socket? = null
            try {
                socket = upstream.createTcpSocket()
                socket.tcpNoDelay = true
                socket.connect(InetSocketAddress(addr, target.port), connectTimeoutMs)
                if (cleaned.get()) {
                    try {
                        socket.close()
                    } catch (_: Exception) {
                    }
                    throw IOException("session cancelled")
                }
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
        val association = udp
        udp = null
        try {
            association?.close()
        } catch (_: Exception) {
        }
        // If handleUdp never entered its finally (e.g. cancelled mid-setup),
        // still drop the UDP counter so activeUdp cannot stick.
        if (association != null) {
            try {
                counters.associationClosed(id)
            } catch (_: Exception) {
            }
        }
        try {
            target?.close()
        } catch (_: Exception) {
        }
        target = null
        try {
            client.close()
        } catch (_: Exception) {
        }
        if (tcpCounted.get()) {
            counters.sessionClosed(id)
        }
        // Only emit closed if we actually started (avoid cancel-before-start noise).
        if (started.get()) {
            emit(RelayEvent.SessionClosed)
        }
        onClosed(id)
    }
}
