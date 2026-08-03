package com.nanako.socksbypass.core

import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlin.concurrent.thread

/**
 * SOCKS5 listener bound to a specific host:port (never default 0.0.0.0 unless caller insists).
 * Each accepted connection becomes a [TcpRelaySession] that uses [upstream] for CONNECT/UDP.
 *
 * Start/stop uses a generation token so a dying accept thread cannot tear down a newer listener.
 */
class Socks5Server(
    private val bindHost: String,
    private val port: Int = 9876,
    private val upstream: UpstreamNetwork,
    private val counters: TrafficCounters = TrafficCounters(),
    private val maxSessions: Int = DEFAULT_MAX_SESSIONS,
    private val destinationPolicy: DestinationPolicy = DestinationPolicy.PRODUCTION,
    private val eventHandler: (RelayEvent) -> Unit = {},
) {
    enum class State { Stopped, Starting, Running, Stopping }

    @Volatile
    var state: State = State.Stopped
        private set

    private val running = AtomicBoolean(false)
    private val generation = AtomicLong(0)
    private var serverSocket: ServerSocket? = null
    private var acceptThread: Thread? = null
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
        // Wait for a previous accept thread outside the lifecycle lock.
        joinAcceptThread(JOIN_TIMEOUT_MS)

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
            val myGeneration = generation.incrementAndGet()
            serverSocket = ss
            running.set(true)
            state = State.Running
            val t = thread(
                name = "socks-accept-${acceptThreadName.incrementAndGet()}",
                isDaemon = true,
            ) {
                acceptLoop(ss, myGeneration)
            }
            acceptThread = t
            return ss.localPort
        }
    }

    fun stop() {
        val toCancel: List<TcpRelaySession>
        val threadToJoin: Thread?
        synchronized(lifecycle) {
            // Always drain sessions even if already Stopped after accept failure —
            // otherwise UI Stop can return without killing lingering relays.
            if (state == State.Stopping) return
            state = State.Stopping
            // Invalidate any in-flight accept generation before closing the socket.
            generation.incrementAndGet()
            running.set(false)
            try {
                serverSocket?.close()
            } catch (_: Exception) {
            }
            serverSocket = null
            toCancel = sessions.values.toList()
            sessions.clear()
            counters.closeAllSessions()
            threadToJoin = acceptThread
            acceptThread = null
            state = State.Stopped
        }
        toCancel.forEach { it.cancel() }
        joinThread(threadToJoin, JOIN_TIMEOUT_MS)
    }

    private fun acceptLoop(ss: ServerSocket, myGeneration: Long) {
        while (isCurrent(myGeneration) && running.get()) {
            val client: Socket = try {
                ss.accept()
            } catch (_: Exception) {
                if (isCurrent(myGeneration) && running.get()) {
                    eventHandler(RelayEvent.ListenerFailed)
                }
                break
            }
            if (!isCurrent(myGeneration) || !running.get()) {
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
                destinationPolicy = destinationPolicy,
                emit = eventHandler,
                onClosed = { id -> sessions.remove(id) },
            )
            // Insert + start under the same lock so stop() cannot cancel between
            // map insert and start() (stale counter / SessionOpened after Stop).
            val started = synchronized(lifecycle) {
                if (!isCurrent(myGeneration) || !running.get() || state != State.Running) {
                    false
                } else {
                    sessions[session.id] = session
                    session.start()
                    true
                }
            }
            if (!started) {
                try {
                    client.close()
                } catch (_: Exception) {
                }
                session.cancel()
            }
        }

        // Unexpected accept failure: tear down only if we still own this generation.
        val leftover: List<TcpRelaySession>
        synchronized(lifecycle) {
            if (!isCurrent(myGeneration) || state != State.Running || serverSocket !== ss) {
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
                if (acceptThread === Thread.currentThread()) {
                    acceptThread = null
                }
            }
        }
        leftover.forEach { it.cancel() }
    }

    private fun isCurrent(myGeneration: Long): Boolean =
        generation.get() == myGeneration

    private fun joinAcceptThread(timeoutMs: Long) {
        val t = synchronized(lifecycle) { acceptThread }
        joinThread(t, timeoutMs)
    }

    private fun joinThread(t: Thread?, timeoutMs: Long) {
        if (t == null || t === Thread.currentThread()) return
        try {
            t.join(timeoutMs)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }

    companion object {
        /** Conservative default for unauthenticated LAN proxies (was 256). */
        const val DEFAULT_MAX_SESSIONS = 64
        private const val JOIN_TIMEOUT_MS = 2_000L

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
