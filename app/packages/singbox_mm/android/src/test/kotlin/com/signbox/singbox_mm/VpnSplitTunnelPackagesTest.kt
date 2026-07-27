package com.signbox.singbox_mm

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

internal class VpnSplitTunnelPackagesTest {
    private val host = "com.fatvpn.fatvpn_app"

    private fun allowed(vararg included: String) =
        VpnSplitTunnelPackages.allowedPackages(
            includedPackages = included.toList(),
            hostPackageName = host,
        )

    @Test
    fun `nothing picked means no per-app filtering at all`() {
        assertEquals(emptyList(), allowed())
    }

    @Test
    fun `a list of blanks is not an allow-list either`() {
        assertEquals(emptyList(), allowed("", "   "))
    }

    @Test
    fun `the user's picks are kept, in order`() {
        val result = allowed("com.example.browser", "com.example.mail")
        assertEquals(
            listOf("com.example.browser", "com.example.mail"),
            result.filter { it != host },
        )
    }

    @Test
    fun `this app rides along so its own traffic stays in the tunnel`() {
        assertTrue(host in allowed("com.example.browser"))
    }

    @Test
    fun `this app is not duplicated when the user picked it too`() {
        assertEquals(1, allowed("com.example.browser", host).count { it == host })
    }

    @Test
    fun `surrounding whitespace does not create a second entry`() {
        assertEquals(
            listOf("com.example.browser", host),
            allowed(" com.example.browser ", "com.example.browser"),
        )
    }
}
