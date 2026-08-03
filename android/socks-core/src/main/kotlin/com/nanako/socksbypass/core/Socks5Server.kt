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

    val activeSessionCount: Int get() = sessions.size

    fun snapshot(): TrafficCounters.Snapshot = counters.snapshot()

    /**
     * Start listening. Returns the actual bound port.
     * @throws IllegalStateException if already running or bind fails
     * @throws IllegalArgumentException if bindHost is blank
     */
    fun start(): Int {
        check(state == State.Stopped) { "already running" }
        require(bindHost.isNotBlank()) { "bindHost required" }
        state = State.Starting
        val ss = ServerSocket()
        try {
            ss.reuseAddress = true
            val addr = InetAddress.getByName(bindHost)
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

    fun stop() {
        if (state == State.Stopped || state == State.Stopping) {
            if (state == State.Stopped) return
        }
        state = State.Stopping
        running.set(false)
        try {
            serverSocket?.close()
        } catch (_: Exception) {
        }
        serverSocket = null
        val copy = sessions.values.toList()
        sessions.clear()
        copy.forEach { it.cancel() }
        counters.closeAllSessions()
        state = State.Stopped
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
            if (!upstream.isAvailable) {
                // Still accept for handshake to return fail-closed REP, but sessions count
            }
            val session = TcpRelaySession(
                client = client,
                upstream = upstream,
                counters = counters,
                emit = eventHandler,
                onClosed = { id -> sessions.remove(id) },
            )
            sessions[session.id] = session
            session.start()
        }
        if (state == State.Running) {
            state = State.Stopped
            running.set(false)
        }
    }
}
