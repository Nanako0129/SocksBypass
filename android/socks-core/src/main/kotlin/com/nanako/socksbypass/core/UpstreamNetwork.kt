package com.nanako.socksbypass.core

import java.net.DatagramSocket
import java.net.InetAddress
import java.net.Socket

/**
 * Platform-owned upstream path. Production binds every socket to cellular;
 * tests inject fail-closed or loopback doubles without mocking the server itself.
 */
interface UpstreamNetwork {
    /** True when new CONNECT / UDP ASSOCIATE upstream work is allowed. */
    val isAvailable: Boolean

    /**
     * Resolve [host] on the upstream network only.
     * Must not use the process default DNS when a bound network is available.
     */
    fun resolve(host: String): List<InetAddress>

    /** Create a TCP socket bound to the upstream network (not connected). */
    fun createTcpSocket(): Socket

    /** Create a UDP socket bound to the upstream network. */
    fun createUdpSocket(): DatagramSocket
}

class UpstreamUnavailableException(message: String = "upstream network unavailable") :
    Exception(message)

/**
 * Loopback / JVM default sockets for unit tests. Not used by the Android app.
 */
class DefaultJvmUpstreamNetwork : UpstreamNetwork {
    @Volatile
    var available: Boolean = true

    override val isAvailable: Boolean
        get() = available

    override fun resolve(host: String): List<InetAddress> {
        if (!available) throw UpstreamUnavailableException()
        return InetAddress.getAllByName(host).toList()
    }

    override fun createTcpSocket(): Socket {
        if (!available) throw UpstreamUnavailableException()
        return Socket()
    }

    override fun createUdpSocket(): DatagramSocket {
        if (!available) throw UpstreamUnavailableException()
        return DatagramSocket()
    }
}

/**
 * Counting wrapper that fails closed and records whether a real socket was opened.
 */
class TrackingUpstreamNetwork(
    private val inner: UpstreamNetwork,
) : UpstreamNetwork {
    @Volatile
    var tcpSocketsCreated: Int = 0
        private set

    @Volatile
    var udpSocketsCreated: Int = 0
        private set

    @Volatile
    var resolveCalls: Int = 0
        private set

    override val isAvailable: Boolean
        get() = inner.isAvailable

    override fun resolve(host: String): List<InetAddress> {
        resolveCalls++
        if (!inner.isAvailable) throw UpstreamUnavailableException()
        return inner.resolve(host)
    }

    override fun createTcpSocket(): Socket {
        if (!inner.isAvailable) throw UpstreamUnavailableException()
        tcpSocketsCreated++
        return inner.createTcpSocket()
    }

    override fun createUdpSocket(): DatagramSocket {
        if (!inner.isAvailable) throw UpstreamUnavailableException()
        udpSocketsCreated++
        return inner.createUdpSocket()
    }
}
