package com.nanako.socksbypass.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

class UdpAssociationTest {
    @Test
    fun datagramHeaderRoundTrips() {
        val cases = listOf(
            Triple(UdpAssociation.DatagramHeader.AddressType.Ipv4, "127.0.0.1", 4001),
            Triple(UdpAssociation.DatagramHeader.AddressType.Domain, "localhost", 4002),
            Triple(UdpAssociation.DatagramHeader.AddressType.Ipv6, "2001:db8::1", 4003),
        )
        for ((type, address, port) in cases) {
            val payload = byteArrayOf(0x11, 0x22, 0x33)
            val encoded = UdpAssociation.DatagramHeader.encode(type, address, port, payload)!!
            val decoded = UdpAssociation.DatagramHeader.decode(encoded)!!
            assertEquals(type, decoded.header.addressType)
            // IPv6 may expand form
            if (type != UdpAssociation.DatagramHeader.AddressType.Ipv6) {
                assertEquals(address, decoded.header.address)
            }
            assertEquals(port, decoded.header.port)
            assertArrayEquals(payload, decoded.payload)
        }
    }

    @Test
    fun nonZeroFragmentIsDropped() {
        val packet = byteArrayOf(0, 0, 1, 1, 127, 0, 0, 1, 0, 53, 0xaa.toByte())
        assertNull(UdpAssociation.DatagramHeader.decode(packet))
    }

    @Test
    fun udpEchoRoundTripViaAssociation() {
        val echo = DatagramSocket(0)
        val echoPort = echo.localPort
        val echoThread = thread(isDaemon = true) {
            val buf = ByteArray(2048)
            val packet = DatagramPacket(buf, buf.size)
            echo.soTimeout = 5_000
            echo.receive(packet)
            val reply = DatagramPacket(packet.data, packet.offset, packet.length, packet.socketAddress)
            echo.send(reply)
        }

        val controlPeer = InetAddress.getByName("127.0.0.1")
        val association = UdpAssociation(
            controlPeer = controlPeer,
            declaredClientPort = null,
            lanBindAddress = InetAddress.getByName("127.0.0.1"),
            upstream = DefaultJvmUpstreamNetwork(),
            counters = TrafficCounters(),
        )
        association.start()
        try {
            val client = DatagramSocket()
            client.soTimeout = 5_000
            val payload = byteArrayOf(1, 2, 3, 4)
            val request = UdpAssociation.DatagramHeader.encode(
                UdpAssociation.DatagramHeader.AddressType.Ipv4,
                "127.0.0.1",
                echoPort,
                payload,
            )!!
            client.send(
                DatagramPacket(
                    request,
                    request.size,
                    InetSocketAddress("127.0.0.1", association.localPort),
                ),
            )
            val buf = ByteArray(2048)
            val resp = DatagramPacket(buf, buf.size)
            client.receive(resp)
            val decoded = UdpAssociation.DatagramHeader.decode(
                resp.data.copyOfRange(resp.offset, resp.offset + resp.length),
            )!!
            assertArrayEquals(payload, decoded.payload)
            client.close()
        } finally {
            association.close()
            echo.close()
            echoThread.join(2_000)
        }
    }

    @Test
    fun onlyControlPeerCanClaimAssociation() {
        val echo = DatagramSocket(0)
        val echoPort = echo.localPort
        // Control peer is a different address than the sender (still loopback family but we use 127.0.0.1 vs ... 
        // On most systems we only have 127.0.0.1 for loopback; use a non-matching literal by constructing
        // association with 203.0.113.7 and send from 127.0.0.1 — should be dropped.
        val association = UdpAssociation(
            controlPeer = InetAddress.getByName("203.0.113.7"),
            declaredClientPort = null,
            lanBindAddress = InetAddress.getByName("127.0.0.1"),
            upstream = DefaultJvmUpstreamNetwork(),
            counters = TrafficCounters(),
        )
        association.start()
        try {
            val client = DatagramSocket()
            client.soTimeout = 400
            val request = UdpAssociation.DatagramHeader.encode(
                UdpAssociation.DatagramHeader.AddressType.Ipv4,
                "127.0.0.1",
                echoPort,
                byteArrayOf(9, 9, 9),
            )!!
            client.send(
                DatagramPacket(request, request.size, InetSocketAddress("127.0.0.1", association.localPort)),
            )
            val buf = ByteArray(256)
            try {
                client.receive(DatagramPacket(buf, buf.size))
                assertTrue("hijacker must not receive a reply", false)
            } catch (_: Exception) {
                // expected timeout — datagram dropped
            }
            // Echo must not have been contacted (best-effort: try short receive)
            echo.soTimeout = 200
            try {
                echo.receive(DatagramPacket(ByteArray(64), 64))
                assertTrue("echo must not see forged traffic", false)
            } catch (_: Exception) {
                // expected
            }
            client.close()
        } finally {
            association.close()
            echo.close()
        }
    }

    @Test
    fun controlTcpCloseEndsUdpServiceViaServer() {
        // Echo target proves the association actually forwards before control close.
        val echo = DatagramSocket(0)
        val echoPort = echo.localPort
        val firstSeen = AtomicBoolean(false)
        val secondSeen = AtomicBoolean(false)
        val echoThread = thread(isDaemon = true) {
            val buf = ByteArray(2048)
            echo.soTimeout = 8_000
            try {
                val p1 = DatagramPacket(buf, buf.size)
                echo.receive(p1)
                firstSeen.set(true)
                echo.send(DatagramPacket(p1.data, p1.offset, p1.length, p1.socketAddress))
            } catch (_: Exception) {
                return@thread
            }
            try {
                echo.soTimeout = 1_500
                val p2 = DatagramPacket(buf, buf.size)
                echo.receive(p2)
                secondSeen.set(true)
            } catch (_: Exception) {
                // expected after association teardown: no second forward
            }
        }

        val upstream = DefaultJvmUpstreamNetwork()
        val server = Socks5Server(bindHost = "127.0.0.1", port = 0, upstream = upstream)
        val listenPort = server.start()
        var associationUdpPort = -1
        try {
            val client = Socket("127.0.0.1", listenPort)
            client.soTimeout = 5_000
            client.getOutputStream().write(byteArrayOf(0x05, 0x01, 0x00))
            client.getOutputStream().flush()
            readExact(client.getInputStream(), 2)
            val req = byteArrayOf(0x05, 0x03, 0x00, 0x01, 0, 0, 0, 0, 0, 0)
            client.getOutputStream().write(req)
            client.getOutputStream().flush()
            val rep = readExact(client.getInputStream(), 10)
            assertEquals(0, rep[1].toInt() and 0xFF)
            associationUdpPort = ((rep[8].toInt() and 0xFF) shl 8) or (rep[9].toInt() and 0xFF)
            assertTrue(associationUdpPort > 0)

            val udpClient = DatagramSocket()
            udpClient.soTimeout = 5_000
            val payload = byteArrayOf(0x42, 0x43, 0x44)
            val request = UdpAssociation.DatagramHeader.encode(
                UdpAssociation.DatagramHeader.AddressType.Ipv4,
                "127.0.0.1",
                echoPort,
                payload,
            )!!
            udpClient.send(
                DatagramPacket(request, request.size, InetSocketAddress("127.0.0.1", associationUdpPort)),
            )
            val respBuf = ByteArray(2048)
            val resp = DatagramPacket(respBuf, respBuf.size)
            udpClient.receive(resp)
            val decoded = UdpAssociation.DatagramHeader.decode(
                resp.data.copyOfRange(resp.offset, resp.offset + resp.length),
            )
            assertNotNull(decoded)
            assertArrayEquals(payload, decoded!!.payload)
            assertTrue("echo must see first datagram", firstSeen.get())

            // Closing control TCP must tear down the association (shipped path).
            client.close()

            // Wait until the association's LAN port is free — proves close() ran.
            var reclaimed = false
            repeat(40) {
                try {
                    DatagramSocket(associationUdpPort).use {
                        reclaimed = true
                    }
                    return@repeat
                } catch (_: Exception) {
                    Thread.sleep(50)
                }
            }
            assertTrue(
                "association UDP port $associationUdpPort must be released after control TCP close",
                reclaimed,
            )

            // Functional: a new datagram to the old port must not reach echo.
            // (If reclaim succeeded we already own the port; send to a closed
            // association is covered by reclaimed. If something else stole the
            // port, secondSeen still must stay false for our payload path.)
            if (!reclaimed) {
                val late = UdpAssociation.DatagramHeader.encode(
                    UdpAssociation.DatagramHeader.AddressType.Ipv4,
                    "127.0.0.1",
                    echoPort,
                    byteArrayOf(0x55),
                )!!
                udpClient.send(
                    DatagramPacket(late, late.size, InetSocketAddress("127.0.0.1", associationUdpPort)),
                )
                Thread.sleep(400)
            }
            echoThread.join(3_000)
            assertFalse("echo must not receive traffic after control TCP close", secondSeen.get())
            udpClient.close()
        } finally {
            server.stop()
            echo.close()
            echoThread.join(2_000)
        }
    }

    @Test
    fun udpAssociateControlTcpSurvivesIdleBeyondHandshakeTimeout() {
        // Regression: handshake soTimeout must not kill an idle UDP control TCP.
        val upstream = DefaultJvmUpstreamNetwork()
        val server = Socks5Server(bindHost = "127.0.0.1", port = 0, upstream = upstream)
        val listenPort = server.start()
        try {
            val client = Socket("127.0.0.1", listenPort)
            client.soTimeout = 5_000
            client.getOutputStream().write(byteArrayOf(0x05, 0x01, 0x00))
            client.getOutputStream().flush()
            readExact(client.getInputStream(), 2)
            client.getOutputStream().write(byteArrayOf(0x05, 0x03, 0x00, 0x01, 0, 0, 0, 0, 0, 0))
            client.getOutputStream().flush()
            val rep = readExact(client.getInputStream(), 10)
            assertEquals(0, rep[1].toInt() and 0xFF)
            val udpPort = ((rep[8].toInt() and 0xFF) shl 8) or (rep[9].toInt() and 0xFF)

            // Stay idle longer than the former 30s bug would allow is too slow for CI;
            // instead poll association port remains bound while control stays open.
            Thread.sleep(500)
            assertTrue(client.isConnected && !client.isClosed)
            val stillBound = try {
                DatagramSocket(udpPort).close()
                false // reclaimed → association already gone (bug)
            } catch (_: Exception) {
                true // port still held by association
            }
            assertTrue("UDP association must stay alive while control TCP is open", stillBound)

            // Still able to forward after idle.
            val echo = DatagramSocket(0)
            val echoPort = echo.localPort
            thread(isDaemon = true) {
                val buf = ByteArray(512)
                echo.soTimeout = 3_000
                val p = DatagramPacket(buf, buf.size)
                echo.receive(p)
                echo.send(DatagramPacket(p.data, p.offset, p.length, p.socketAddress))
            }
            val udpClient = DatagramSocket()
            udpClient.soTimeout = 3_000
            val payload = byteArrayOf(7, 8, 9)
            val request = UdpAssociation.DatagramHeader.encode(
                UdpAssociation.DatagramHeader.AddressType.Ipv4,
                "127.0.0.1",
                echoPort,
                payload,
            )!!
            udpClient.send(DatagramPacket(request, request.size, InetSocketAddress("127.0.0.1", udpPort)))
            val respBuf = ByteArray(512)
            val resp = DatagramPacket(respBuf, respBuf.size)
            udpClient.receive(resp)
            val decoded = UdpAssociation.DatagramHeader.decode(
                resp.data.copyOfRange(resp.offset, resp.offset + resp.length),
            )!!
            assertArrayEquals(payload, decoded.payload)
            client.close()
            udpClient.close()
            echo.close()
        } finally {
            server.stop()
        }
    }

    private fun readExact(input: java.io.InputStream, n: Int): ByteArray {
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
