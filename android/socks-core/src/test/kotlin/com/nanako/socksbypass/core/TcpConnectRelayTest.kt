package com.nanako.socksbypass.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

class TcpConnectRelayTest {
    @Test
    fun connectRefusedPortReturnsNonSuccessRep() {
        val upstream = TrackingUpstreamNetwork(DefaultJvmUpstreamNetwork())
        val server = Socks5Server(
            bindHost = "127.0.0.1",
            port = 0,
            upstream = upstream,
        )
        val listenPort = server.start()
        try {
            // Target that refuses connections
            val free = ServerSocket(0)
            val refusedPort = free.localPort
            free.close()
            Thread.sleep(50)

            Socket("127.0.0.1", listenPort).use { client ->
                client.soTimeout = 5_000
                client.getOutputStream().write(byteArrayOf(0x05, 0x01, 0x00))
                client.getOutputStream().flush()
                val method = readExact(client.getInputStream(), 2)
                assertArrayEquals(byteArrayOf(0x05, 0x00), method)

                val req = byteArrayOf(
                    0x05, 0x01, 0x00, 0x01,
                    127, 0, 0, 1,
                    (refusedPort shr 8).toByte(), (refusedPort and 0xFF).toByte(),
                )
                client.getOutputStream().write(req)
                client.getOutputStream().flush()
                val rep = readExact(client.getInputStream(), 10)
                assertEquals(0x05, rep[0].toInt() and 0xFF)
                assertTrue("REP should be failure, was ${rep[1].toInt() and 0xFF}", (rep[1].toInt() and 0xFF) != 0x00)
            }
        } finally {
            server.stop()
        }
    }

    @Test
    fun failClosedWhenUpstreamUnavailableDoesNotOpenDefaultSocket() {
        val base = DefaultJvmUpstreamNetwork().also { it.available = false }
        val upstream = TrackingUpstreamNetwork(base)
        val server = Socks5Server(
            bindHost = "127.0.0.1",
            port = 0,
            upstream = upstream,
        )
        val listenPort = server.start()
        try {
            Socket("127.0.0.1", listenPort).use { client ->
                client.soTimeout = 5_000
                client.getOutputStream().write(byteArrayOf(0x05, 0x01, 0x00))
                client.getOutputStream().flush()
                readExact(client.getInputStream(), 2)
                val req = byteArrayOf(0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1, 0x00, 0x50)
                client.getOutputStream().write(req)
                client.getOutputStream().flush()
                val rep = readExact(client.getInputStream(), 10)
                assertEquals(0x05, rep[0].toInt() and 0xFF)
                assertTrue((rep[1].toInt() and 0xFF) != 0x00)
            }
            assertEquals(0, upstream.tcpSocketsCreated)
        } finally {
            server.stop()
        }
    }

    @Test
    fun halfCloseTransfersMultiMegabytePatternBothWays() {
        val patternBase = ByteArray(256) { i -> ((i * 31 + 17) and 0xFF).toByte() }
        fun pattern(offset: Int, length: Int): ByteArray {
            val out = ByteArray(length)
            for (i in 0 until length) {
                out[i] = patternBase[(offset + i) % patternBase.size]
            }
            return out
        }

        val uploadBytes = 3 * 1024 * 1024
        val downloadBytes = 3 * 1024 * 1024

        val target = ServerSocket(0)
        val targetPort = target.localPort
        val targetReady = CountDownLatch(1)
        val targetThread = thread(isDaemon = true) {
            val s = target.accept()
            targetReady.countDown()
            s.use { socket ->
                val input = socket.getInputStream()
                val output = socket.getOutputStream()
                // Read all upload, then half-close from client should allow us to still write full download
                var got = 0
                val buf = ByteArray(64 * 1024)
                while (got < uploadBytes) {
                    val n = input.read(buf)
                    if (n < 0) break
                    // verify pattern
                    val expected = pattern(got, n)
                    assertArrayEquals(expected, buf.copyOf(n))
                    got += n
                }
                assertEquals(uploadBytes, got)
                var sent = 0
                while (sent < downloadBytes) {
                    val chunk = pattern(sent, minOf(64 * 1024, downloadBytes - sent))
                    output.write(chunk)
                    sent += chunk.size
                }
                output.flush()
            }
        }

        val upstream = DefaultJvmUpstreamNetwork()
        val server = Socks5Server(
            bindHost = "127.0.0.1",
            port = 0,
            upstream = upstream,
        )
        val listenPort = server.start()
        try {
            Socket("127.0.0.1", listenPort).use { client ->
                client.tcpNoDelay = true
                client.soTimeout = 60_000
                val out = client.getOutputStream()
                val input = client.getInputStream()
                out.write(byteArrayOf(0x05, 0x01, 0x00))
                out.flush()
                readExact(input, 2)
                val req = byteArrayOf(
                    0x05, 0x01, 0x00, 0x01,
                    127, 0, 0, 1,
                    (targetPort shr 8).toByte(), (targetPort and 0xFF).toByte(),
                )
                out.write(req)
                out.flush()
                val rep = readExact(input, 10)
                assertEquals(0, rep[1].toInt() and 0xFF)

                // Upload patterned bytes then half-close write side
                var sent = 0
                while (sent < uploadBytes) {
                    val chunk = pattern(sent, minOf(64 * 1024, uploadBytes - sent))
                    out.write(chunk)
                    sent += chunk.size
                }
                out.flush()
                client.shutdownOutput()

                // Must still receive full download
                var got = 0
                val buf = ByteArray(64 * 1024)
                while (got < downloadBytes) {
                    val n = input.read(buf)
                    assertTrue("truncated download at $got", n >= 0)
                    assertArrayEquals(pattern(got, n), buf.copyOf(n))
                    got += n
                }
                assertEquals(downloadBytes, got)
            }
            assertTrue(targetReady.await(5, TimeUnit.SECONDS))
            targetThread.join(10_000)
        } finally {
            server.stop()
            try {
                target.close()
            } catch (_: Exception) {
            }
        }
    }

    @Test
    fun domainConnectSucceedsViaUpstreamResolve() {
        val target = ServerSocket(0)
        val targetPort = target.localPort
        val accepted = AtomicInteger(0)
        thread(isDaemon = true) {
            target.accept().use { s ->
                accepted.incrementAndGet()
                s.getInputStream().read()
            }
        }
        val upstream = object : UpstreamNetwork {
            override val isAvailable: Boolean = true
            override fun resolve(host: String): List<InetAddress> {
                assertEquals("localhost", host)
                return listOf(InetAddress.getByName("127.0.0.1"))
            }
            override fun createTcpSocket(): Socket = Socket()
            override fun createUdpSocket() = java.net.DatagramSocket()
        }
        val server = Socks5Server(bindHost = "127.0.0.1", port = 0, upstream = upstream)
        val listenPort = server.start()
        try {
            Socket("127.0.0.1", listenPort).use { client ->
                client.soTimeout = 5_000
                client.getOutputStream().write(byteArrayOf(0x05, 0x01, 0x00))
                client.getOutputStream().flush()
                readExact(client.getInputStream(), 2)
                val host = "localhost".toByteArray()
                val req = byteArrayOf(0x05, 0x01, 0x00, 0x03, host.size.toByte()) +
                    host +
                    byteArrayOf((targetPort shr 8).toByte(), (targetPort and 0xFF).toByte())
                client.getOutputStream().write(req)
                client.getOutputStream().flush()
                val rep = readExact(client.getInputStream(), 10)
                assertEquals(0, rep[1].toInt() and 0xFF)
            }
            Thread.sleep(200)
            assertEquals(1, accepted.get())
        } finally {
            server.stop()
            target.close()
        }
    }

    private fun readExact(input: InputStream, n: Int): ByteArray {
        val out = ByteArray(n)
        var off = 0
        while (off < n) {
            val r = input.read(out, off, n - off)
            if (r < 0) throw IllegalStateException("eof at $off/$n")
            off += r
        }
        return out
    }
}
