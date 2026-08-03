package com.nanako.socksbypass.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class Socks5HandshakeParserTest {
    private val greeting = byteArrayOf(0x05, 0x01, 0x00)
    private val request = byteArrayOf(0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1, 0x1F, 0x90.toByte())

    @Test
    fun greetingEverySplitPoint() {
        for (split in 0..greeting.size) {
            val parser = Socks5HandshakeParser()
            val first = parser.feed(greeting.copyOfRange(0, split))
            val second = parser.feed(greeting.copyOfRange(split, greeting.size))
            val replies = first.replies + second.replies
            assertEquals(1, replies.size)
            assertArrayEquals(byteArrayOf(0x05, 0x00), replies[0])
            assertFalse(parser.isClosed)
        }
    }

    @Test
    fun requestEverySplitPoint() {
        for (split in 0..request.size) {
            val parser = Socks5HandshakeParser()
            parser.feed(greeting)
            val first = parser.feed(request.copyOfRange(0, split))
            val second = parser.feed(request.copyOfRange(split, request.size))
            val connect = first.request ?: second.request
            assertEquals("127.0.0.1", connect?.target?.address)
            assertEquals(8080, connect?.target?.port)
            assertEquals(0, connect?.firstPayload?.size)
        }
    }

    @Test
    fun fullyCoalescedHandshakePreservesFirstPayload() {
        val parser = Socks5HandshakeParser()
        val payload = byteArrayOf(0xDE.toByte(), 0xAD.toByte(), 0xBE.toByte(), 0xEF.toByte(), 0x00, 0xFF.toByte())
        val output = parser.feed(greeting + request + payload)
        assertEquals(1, output.replies.size)
        assertArrayEquals(byteArrayOf(0x05, 0x00), output.replies[0])
        assertEquals("127.0.0.1", output.request?.target?.address)
        assertArrayEquals(payload, output.request?.firstPayload)
    }

    @Test
    fun invalidGreetingVersionRepliesAndCloses() {
        val parser = Socks5HandshakeParser()
        val output = parser.feed(byteArrayOf(0x04, 0x01, 0x00))
        assertArrayEquals(byteArrayOf(0x05, 0xFF.toByte()), output.replies[0])
        assertTrue(output.shouldClose)
        assertTrue(parser.isClosed)
    }

    @Test
    fun invalidRequestFieldsUseRfcReplyCodes() {
        assertInvalidRequest(byteArrayOf(0x04, 0x01, 0x00, 0x01), 0x01)
        assertInvalidRequest(byteArrayOf(0x05, 0x01, 0x01, 0x01), 0x01)
        assertInvalidRequest(byteArrayOf(0x05, 0x02, 0x00, 0x01), 0x07)
        assertInvalidRequest(byteArrayOf(0x05, 0x01, 0x00, 0x02), 0x08)
    }

    @Test
    fun domainRequest() {
        val domain = "example.com".toByteArray()
        val req = byteArrayOf(0x05, 0x01, 0x00, 0x03, domain.size.toByte()) + domain + byteArrayOf(0x01, 0xBB.toByte())
        val parser = Socks5HandshakeParser()
        val out = parser.feed(greeting + req)
        assertEquals("example.com", out.request?.target?.address)
        assertEquals(443, out.request?.target?.port)
    }

    @Test
    fun udpAssociateCommand() {
        val req = byteArrayOf(0x05, 0x03, 0x00, 0x01, 0, 0, 0, 0, 0, 0)
        val parser = Socks5HandshakeParser()
        val out = parser.feed(greeting + req)
        assertEquals(Socks5HandshakeParser.Command.UdpAssociate, out.request?.command)
    }

    private fun assertInvalidRequest(header: ByteArray, reply: Int) {
        val parser = Socks5HandshakeParser()
        parser.feed(greeting)
        val out = parser.feed(header)
        assertTrue(out.shouldClose)
        assertNull(out.request)
        assertEquals(0x05, out.replies[0][0].toInt() and 0xFF)
        assertEquals(reply, out.replies[0][1].toInt() and 0xFF)
    }
}
