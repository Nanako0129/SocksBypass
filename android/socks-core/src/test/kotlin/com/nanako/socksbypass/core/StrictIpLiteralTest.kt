package com.nanako.socksbypass.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import java.net.InetAddress

class StrictIpLiteralTest {
    @Test
    fun parsesStrictIpv4() {
        val a = StrictIpLiteral.parse("127.0.0.1")
        assertNotNull(a)
        assertArrayEquals(byteArrayOf(127, 0, 0, 1), a!!.address)
    }

    @Test
    fun rejectsInvalidOctetWithoutDns() {
        // Must not throw and must not return a resolved address — null forces upstream.resolve
        assertNull(StrictIpLiteral.parse("999.1.2.3"))
        assertNull(StrictIpLiteral.parse("1.2.3"))
        assertNull(StrictIpLiteral.parse("01.2.3.4"))
    }

    @Test
    fun rejectsHostnameLookingStringsWithColon() {
        assertNull(StrictIpLiteral.parse("evil:name"))
        assertNull(StrictIpLiteral.parse("example.com"))
        assertNull(StrictIpLiteral.parse("localhost"))
    }

    @Test
    fun parsesLoopbackIpv6() {
        val a = StrictIpLiteral.parse("::1")
        assertNotNull(a)
        assertEquals(16, a!!.address.size)
        assertEquals(1, a.address[15].toInt() and 0xff)
    }

    @Test
    fun parsesCompressedIpv6() {
        val a = StrictIpLiteral.parse("2001:db8::1")
        assertNotNull(a)
        assertEquals(16, a!!.address.size)
    }

    @Test
    fun parsesIpv4CompatibleIpv6() {
        val a = StrictIpLiteral.parse("::192.0.2.1")
        assertNotNull(a)
        assertEquals(16, a!!.address.size)
        // Last 4 bytes are 192.0.2.1
        assertEquals(192, a.address[12].toInt() and 0xff)
        assertEquals(0, a.address[13].toInt() and 0xff)
        assertEquals(2, a.address[14].toInt() and 0xff)
        assertEquals(1, a.address[15].toInt() and 0xff)
    }

    @Test
    fun parsesCompressedIpv6WithDottedTail() {
        val a = StrictIpLiteral.parse("2001:db8::192.0.2.1")
        assertNotNull(a)
        assertEquals(16, a!!.address.size)
        assertEquals(192, a.address[12].toInt() and 0xff)
        assertEquals(1, a.address[15].toInt() and 0xff)
    }

    @Test
    fun rejectsZeroWidthDoubleColon() {
        assertNull(StrictIpLiteral.parse("1:2:3:4:5:6:7:8::"))
        assertNull(StrictIpLiteral.parse("::1:2:3:4:5:6:7:8"))
    }

    @Test
    fun rejectsMultipleDoubleColon() {
        assertNull(StrictIpLiteral.parse("1::2::3"))
    }
}
