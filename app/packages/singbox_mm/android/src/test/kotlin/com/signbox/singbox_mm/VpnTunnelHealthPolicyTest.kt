package com.signbox.singbox_mm

import kotlin.test.Test
import kotlin.test.assertEquals

internal class VpnTunnelHealthPolicyTest {
    private var clock = 1_000_000L
    private val policy = VpnTunnelHealthPolicy(nowMs = { clock })

    private fun advance(ms: Long) {
        clock += ms
    }

    private fun dead() = policy.onVerdict(VpnTunnelHealthVerdict.DEAD)

    private fun healthy() = policy.onVerdict(VpnTunnelHealthVerdict.HEALTHY)

    private fun unknown() = policy.onVerdict(VpnTunnelHealthVerdict.UNKNOWN)

    @Test
    fun `a single failed probe is a blip, not a broken tunnel`() {
        assertEquals(VpnTunnelRecovery.NONE, dead())
    }

    @Test
    fun `two failures in a row rebuild the tunnel`() {
        dead()
        assertEquals(VpnTunnelRecovery.RESTART, dead())
    }

    @Test
    fun `a healthy probe between failures clears the streak`() {
        dead()
        healthy()
        assertEquals(VpnTunnelRecovery.NONE, dead())
    }

    @Test
    fun `an inconclusive probe neither accuses the tunnel nor absolves it`() {
        dead()
        assertEquals(VpnTunnelRecovery.NONE, unknown())
        // The earlier failure still counts: the next one is the second in a row.
        assertEquals(VpnTunnelRecovery.RESTART, dead())
    }

    @Test
    fun `a rebuild that did not take is tried again after the quiet period`() {
        dead()
        assertEquals(VpnTunnelRecovery.RESTART, dead())
        advance(VpnTunnelHealthPolicy.MIN_RECOVERY_INTERVAL_MS)
        dead()
        assertEquals(VpnTunnelRecovery.RESTART, dead())
        assertEquals(2, policy.recoveryCount)
    }

    @Test
    fun `recoveries cannot run back to back`() {
        dead()
        assertEquals(VpnTunnelRecovery.RESTART, dead())
        advance(VpnTunnelHealthPolicy.MIN_RECOVERY_INTERVAL_MS - 1)
        dead()
        assertEquals(VpnTunnelRecovery.NONE, dead())
    }

    @Test
    fun `a tunnel proved healthy again forgets the recoveries it took`() {
        dead()
        assertEquals(VpnTunnelRecovery.RESTART, dead())
        healthy()
        assertEquals(0, policy.recoveryCount)
        assertEquals(false, policy.isUnhealthy)
    }

    @Test
    fun `restarting the tunnel does not forgive the recoveries already spent`() {
        // A recovery restarts the core, which restarts the watchdog. If that
        // reset the escalation, a server that is simply down would be rebuilt
        // every 90 seconds forever.
        dead()
        assertEquals(VpnTunnelRecovery.RESTART, dead())
        policy.onTunnelStarted()
        advance(VpnTunnelHealthPolicy.MIN_RECOVERY_INTERVAL_MS)
        dead()
        assertEquals(VpnTunnelRecovery.RESTART, dead())
    }

    @Test
    fun `checks slow down once repeated recoveries have not helped`() {
        assertEquals(VpnTunnelHealthPolicy.CHECK_INTERVAL_MS, policy.checkIntervalMs)
        repeat(VpnTunnelHealthPolicy.RECOVERIES_BEFORE_BACKOFF) {
            dead()
            dead()
            advance(VpnTunnelHealthPolicy.MIN_RECOVERY_INTERVAL_MS)
        }
        assertEquals(
            VpnTunnelHealthPolicy.RECOVERIES_BEFORE_BACKOFF,
            policy.recoveryCount,
        )
        assertEquals(VpnTunnelHealthPolicy.BACKOFF_INTERVAL_MS, policy.checkIntervalMs)
    }

    @Test
    fun `a tunnel proved healthy again returns to the normal cadence`() {
        repeat(VpnTunnelHealthPolicy.RECOVERIES_BEFORE_BACKOFF) {
            dead()
            dead()
            advance(VpnTunnelHealthPolicy.MIN_RECOVERY_INTERVAL_MS)
        }
        healthy()
        assertEquals(VpnTunnelHealthPolicy.CHECK_INTERVAL_MS, policy.checkIntervalMs)
    }

    @Test
    fun `a device with no upstream is not held against the tunnel`() {
        dead()
        policy.onProbeSkipped()
        assertEquals(VpnTunnelRecovery.NONE, dead())
    }
}
