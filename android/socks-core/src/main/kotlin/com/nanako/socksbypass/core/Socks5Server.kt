package com.nanako.socksbypass.core

import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

/**
 * SOCKS5 listener bound to a specific host:port (never default 0.0.0.0 unless caller insists).
 * Each accepted connection becomes a [TcpRelaySession] that uses [upstream] for CONNECT/UDP.
 */
class Socks5Server(
    private val bindHost: String,
    private val port: Int = 9876,
    private val upstream: UpstreamNetwork,
    private val counters: TrafficCounters = TrafficCounters(),
    private val maxSessions: Int = 256,
    private val eventHandler: (RelayEvent) -> Unit = {},
) {
    enum class State { Stopped, Starting, Running, Stopping }

    @Volatile
    var state: State = State.Stopped
        private set

    private val running = AtomicBoolean(false)
    private var serverSocket: ServerSocket? = null
    private val sessions = ConcurrentHashMap<UUID, TcpRelaySession>()
    private val acceptThreadName = AtomicInteger(0)
    private val lifecycle = Any()

    val activeSessionCount: Int get() = sessions.size

    fun snapshot(): TrafficCounters.Snapshot = counters.snapshot()

    /**
     * Start listening. Returns the actual bound port.
     * @throws IllegalStateException if already running or bind fails
     * @throws IllegalArgumentException if bindHost is blank
     */
    fun start(): Int {
        synchronized(lifecycle) {
            check(state == State.Stopped) { "already running" }
            require(bindHost.isNotBlank()) { "bindHost required" }
            val addr = InetAddress.getByName(bindHost)
            // Never silently open on all interfaces / non-private targets.
            require(!addr.isAnyLocalAddress) {
                "bindHost must not be 0.0.0.0 / :: (select a private hotspot address)"
            }
            require(!addr.isLoopbackAddress || bindHost == "127.0.0.1" || bindHost == "::1") {
                "unexpected loopback bind"
            }
            // Production path: private IPv4 only (tests may use 127.0.0.1).
            if (addr is java.net.Inet4Address && !addr.isLoopbackAddress) {
                val host = addr.hostAddress ?: bindHost
                require(isPrivateIpv4(host)) {
                    "bindHost must be a private IPv4 address, got $host"
                }
            }
            state = State.Starting
            val ss = ServerSocket()
            try {
                ss.reuseAddress = true
                ss.bind(InetSocketAddress(addr, port))
            } catch (e: Exception) {
                state = State.Stopped
                try {
                    ss.close()
                } catch (_: Exception) {
                }
                throw e
            }
            serverSocket = ss
            running.set(true)
            state = State.Running
            thread(name = "socks-accept-${acceptThreadName.incrementAndGet()}", isDaemon = true) {
                acceptLoop(ss)
            }
            return ss.localPort
        }
    }

    fun stop() {
        val toCancel: List<TcpRelaySession>
        synchronized(lifecycle) {
            // Always drain sessions even if already Stopped after accept failure —
            // otherwise UI Stop can return without killing lingering relays.
            if (state == State.Stopping) return
            state = State.Stopping
            running.set(false)
            try {
                serverSocket?.close()
            } catch (_: Exception) {
            }
            serverSocket = null
            toCancel = sessions.values.toList()
            sessions.clear()
            counters.closeAllSessions()
            state = State.Stopped
        }
        toCancel.forEach { it.cancel() }
    }

    private fun acceptLoop(ss: ServerSocket) {
        while (running.get()) {
            val client: Socket = try {
                ss.accept()
            } catch (_: Exception) {
                if (running.get()) {
                    eventHandler(RelayEvent.ListenerFailed)
                }
                break
            }
            if (!running.get()) {
                try {
                    client.close()
                } catch (_: Exception) {
                }
                break
            }
            if (sessions.size >= maxSessions) {
                try {
                    client.close()
                } catch (_: Exception) {
                }
                continue
            }
            val session = TcpRelaySession(
                client = client,
                upstream = upstream,
                counters = counters,
                emit = eventHandler,
                onClosed = { id -> sessions.remove(id) },
            )
            // Coordinate with stop(): only start if still running after map insert.
            val started = synchronized(lifecycle) {
                if (!running.get() || state != State.Running) {
                    false
                } else {
                    sessions[session.id] = session
                    true
                }
            }
            if (!started) {
                try {
                    client.close()
                } catch (_: Exception) {
                }
                session.cancel()
                continue
            }
            session.start()
        }
        // Unexpected accept failure: tear down any live sessions so Stop cannot
        // leave relays open after the UI shows stopped.
        val leftover: List<TcpRelaySession>
        synchronized(lifecycle) {
            if (state != State.Running) {
                leftover = emptyList()
            } else {
                running.set(false)
                leftover = sessions.values.toList()
                sessions.clear()
                counters.closeAllSessions()
                state = State.Stopped
                try {
                    serverSocket?.close()
                } catch (_: Exception) {
                }
                serverSocket = null
            }
        }
        leftover.forEach { it.cancel() }
    }

    companion object {
        fun isPrivateIpv4(host: String): Boolean {
            val parts = host.split('.')
            if (parts.size != 4) return false
            val o = parts.mapNotNull { it.toIntOrNull() }
            if (o.size != 4 || o.any { it !in 0..255 }) return false
            return when {
                o[0] == 10 -> true
                o[0] == 172 && o[1] in 16..31 -> true
                o[0] == 192 && o[1] == 168 -> true
                else -> false
            }
        }
    }
}
