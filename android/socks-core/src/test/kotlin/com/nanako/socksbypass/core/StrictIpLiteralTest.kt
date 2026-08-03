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
}
