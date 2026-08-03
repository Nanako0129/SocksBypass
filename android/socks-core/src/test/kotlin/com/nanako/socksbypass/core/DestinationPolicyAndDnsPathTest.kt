package com.nanako.socksbypass.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.InputStream
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

/**
 * Drives real [Socks5Server] / CONNECT entry points for N1 (DNS purity) and N2 (destination policy).
 */
class DestinationPolicyAndDnsPathTest {
    @Test
    fun productionPolicyRejectsLoopbackConnectWithNonSuccessRep() {
        val listening = AtomicInteger(0)
        // Target would be loopback — production policy must refuse before open.
        val upstream = object : UpstreamNetwork {
            override val isAvailable: Boolean = true
            override fun resolve(host: String): List<InetAddress> =
                listOf(InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)))
            override fun createTcpSocket(): Socket {
                listening.incrementAndGet()
                return Socket()
            }
            override fun createUdpSocket() = DatagramSocket()
        }
        val server = Socks5Server(
            bindHost = "127.0.0.1",
            port = 0,
            upstream = upstream,
            destinationPolicy = DestinationPolicy.PRODUCTION,
        )
        val port = server.start()
        try {
            Socket("127.0.0.1", port).use { client ->
                client.soTimeout = 5_000
                client.getOutputStream().write(byteArrayOf(0x05, 0x01, 0x00))
                client.getOutputStream().flush()
                readExact(client.getInputStream(), 2)
                // CONNECT 127.0.0.1:9
                val req = byteArrayOf(0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1, 0, 9)
                client.getOutputStream().write(req)
                client.getOutputStream().flush()
                val rep = readExact(client.getInputStream(), 10)
                assertEquals(0x05, rep[0].toInt() and 0xFF)
                assertTrue("loopback CONNECT must fail, was ${rep[1].toInt() and 0xFF}", (rep[1].toInt() and 0xFF) != 0x00)
                assertEquals(0x02, rep[1].toInt() and 0xFF)
            }
            assertEquals("must not open TCP socket for denied destination", 0, listening.get())
        } finally {
            server.stop()
        }
    }

    @Test
    fun nonLiteralHostGoesThroughUpstreamResolveNotProcessDefault() {
        val resolveHosts = mutableListOf<String>()
        val target = ServerSocket(0)
        val targetPort = target.localPort
        thread(isDaemon = true) {
            target.accept().use { s -> s.getInputStream().read() }
        }
        val upstream = object : UpstreamNetwork {
            override val isAvailable: Boolean = true
            override fun resolve(host: String): List<InetAddress> {
                resolveHosts.add(host)
                // Evil shapes that used to hit getByName DNS must arrive here instead.
                return listOf(InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)))
            }
            override fun createTcpSocket() = Socket()
            override fun createUdpSocket() = DatagramSocket()
        }
        val server = Socks5Server(
            bindHost = "127.0.0.1",
            port = 0,
            upstream = upstream,
            destinationPolicy = DestinationPolicy.ALLOW_ALL,
        )
        val listen = server.start()
        try {
            // Domain that "looks like" broken IPv4 — must use upstream.resolve
            Socket("127.0.0.1", listen).use { client ->
                client.soTimeout = 5_000
                client.getOutputStream().write(byteArrayOf(0x05, 0x01, 0x00))
                client.getOutputStream().flush()
                readExact(client.getInputStream(), 2)
                val host = "999.1.2.3".toByteArray()
                val req = byteArrayOf(0x05, 0x01, 0x00, 0x03, host.size.toByte()) +
                    host +
                    byteArrayOf((targetPort shr 8).toByte(), (targetPort and 0xFF).toByte())
                client.getOutputStream().write(req)
                client.getOutputStream().flush()
                val rep = readExact(client.getInputStream(), 10)
                assertEquals(0, rep[1].toInt() and 0xFF)
            }
            assertTrue(resolveHosts.contains("999.1.2.3"))
        } finally {
            server.stop()
            target.close()
        }
    }

    @Test
    fun colonHostnameGoesThroughUpstreamResolve() {
        val resolveHosts = mutableListOf<String>()
        val upstream = object : UpstreamNetwork {
            override val isAvailable: Boolean = true
            override fun resolve(host: String): List<InetAddress> {
                resolveHosts.add(host)
                // resolve fails → CONNECT failure, but we only care path was resolve()
                return emptyList()
            }
            override fun createTcpSocket() = Socket()
            override fun createUdpSocket() = DatagramSocket()
        }
        val server = Socks5Server(
            bindHost = "127.0.0.1",
            port = 0,
            upstream = upstream,
            destinationPolicy = DestinationPolicy.ALLOW_ALL,
        )
        val listen = server.start()
        try {
            Socket("127.0.0.1", listen).use { client ->
                client.soTimeout = 5_000
                client.getOutputStream().write(byteArrayOf(0x05, 0x01, 0x00))
                client.getOutputStream().flush()
                readExact(client.getInputStream(), 2)
                val host = "evil:name".toByteArray()
                val req = byteArrayOf(0x05, 0x01, 0x00, 0x03, host.size.toByte()) +
                    host + byteArrayOf(0, 80)
                client.getOutputStream().write(req)
                client.getOutputStream().flush()
                val rep = readExact(client.getInputStream(), 10)
                assertTrue((rep[1].toInt() and 0xFF) != 0x00)
            }
            assertTrue(resolveHosts.contains("evil:name"))
        } finally {
            server.stop()
        }
    }

    @Test
    fun productionPolicyRejectsMulticastAndLinkLocal() {
        assertFalse(DestinationPolicy.PRODUCTION.isAllowed(InetAddress.getByName("224.0.0.1")))
        assertFalse(DestinationPolicy.PRODUCTION.isAllowed(InetAddress.getByName("169.254.1.1")))
        assertFalse(DestinationPolicy.PRODUCTION.isAllowed(InetAddress.getByName("0.0.0.0")))
        assertTrue(DestinationPolicy.PRODUCTION.isAllowed(InetAddress.getByName("8.8.8.8")))
        assertTrue(DestinationPolicy.ALLOW_ALL.isAllowed(InetAddress.getByName("127.0.0.1")))
    }

    private fun readExact(input: InputStream, n: Int): ByteArray {
        val out = ByteArray(n)
        var off = 0
        while (off < n) {
            val r = input.read(out, off, n - off)
            if (r < 0) throw IllegalStateException("eof")
            off += r
        }
        return out
    }
}
