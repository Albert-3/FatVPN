package com.signbox.singbox_mm

import android.os.Handler
import android.os.SystemClock
import android.util.Log
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/// Watches a live tunnel from inside the VPN service and puts it back together
/// when it stops carrying traffic.
///
/// The failure this exists for: after hours of uptime — a network switch, a NAT
/// timeout, the device coming out of a long doze — sing-box keeps its tunnel
/// *up* while nothing gets through it. Nothing about the OS state changes, so
/// the tun device is still there, the service is still in the foreground and the
/// app still says "connected"; the only cure the user has is toggling the VPN
/// off and on, which is exactly what this does for them.
///
/// It has to live here rather than in Dart because that is the one place that
/// survives the app being backgrounded or swiped away: the tunnel keeps running
/// in the service long after the Flutter engine (and every timer in it) is gone.
///
/// This class is the plumbing — scheduling, threading, lifecycle. What counts as
/// broken and what to do about it lives in [VpnTunnelHealthPolicy].
internal class VpnTunnelHealthWatchdog(
    private val handler: Handler,
    private val probe: VpnTunnelHealthProbe,
    private val policy: VpnTunnelHealthPolicy,
    private val isTunnelUp: () -> Boolean,
    private val hasUpstreamNetwork: () -> Boolean,
    private val restartCore: () -> Unit,
    private val logTag: String,
    /// Same clock [handler] schedules against, so a delay computed here means
    /// the same thing as one handed to `postDelayed`.
    private val uptimeMs: () -> Long = { SystemClock.uptimeMillis() },
) {
    private companion object {
        /// A freshly started tunnel needs a moment before its first verdict means
        /// anything — routes are still being installed and the first handshake
        /// may not have completed.
        const val FIRST_CHECK_DELAY_MS = 45_000L

        /// Delay before the out-of-band check that follows a default-network
        /// change: long enough for the new network to finish coming up, short
        /// enough that a Wi-Fi → mobile switch doesn't cost a full interval.
        const val NETWORK_SETTLE_DELAY_MS = 8_000L
    }

    @Volatile
    private var started = false

    /// Runs the blocking control-API probe off the main thread. Owned by the
    /// watchdog so its lifetime matches [start]/[stop] exactly and no executor
    /// outlives the tunnel it was watching.
    private var probeExecutor: ExecutorService? = null

    // Touched only from handler callbacks.
    private var probeInFlight = false

    /// When the tunnel now being watched came up.
    private var tunnelUpSinceMs = 0L

    /// The periodic check. Reschedules itself rather than using a fixed-rate
    /// timer so the interval can widen while the policy is backing off.
    ///
    /// Posted on a [Handler], so the interval counts awake time only — which is
    /// the right clock here: a dozing device isn't passing traffic to lose, and
    /// the tick resumes the moment the user picks the phone up.
    private val periodicTick = object : Runnable {
        override fun run() {
            if (!started) return
            runProbe()
            handler.postDelayed(this, policy.checkIntervalMs)
        }
    }

    /// One-shot check scheduled by [checkSoon]. Kept separate from
    /// [periodicTick] on purpose: network callbacks can fire in bursts, and
    /// rescheduling the periodic tick on each one would starve it indefinitely.
    private val expeditedTick = Runnable {
        if (!started) return@Runnable
        runProbe()
    }

    fun start() {
        if (started) return
        started = true
        tunnelUpSinceMs = uptimeMs()
        policy.onTunnelStarted()
        probeExecutor = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "singbox-health-probe").apply { isDaemon = true }
        }
        handler.removeCallbacks(periodicTick)
        handler.postDelayed(periodicTick, FIRST_CHECK_DELAY_MS)
    }

    fun stop() {
        if (!started) return
        started = false
        handler.removeCallbacks(periodicTick)
        handler.removeCallbacks(expeditedTick)
        probeExecutor?.shutdownNow()
        probeExecutor = null
    }

    /// Requests an out-of-band check shortly from now — used when the default
    /// network changes, the single most likely moment for a tunnel to survive as
    /// an interface while quietly losing its path to the server.
    fun checkSoon() {
        if (!started) return
        handler.removeCallbacks(expeditedTick)
        handler.postDelayed(expeditedTick, expeditedDelayMs())
    }

    /// How long an out-of-band check must wait: soon after a network change, but
    /// never sooner than a freshly built tunnel is owed.
    ///
    /// This is what stops the watchdog from feeding itself. A recovery tears the
    /// tun device down and puts a new one up, and that *is* a default-network
    /// change — so every restart schedules the very probe that judges it, eight
    /// seconds into a tunnel whose first handshake has not finished. That probe
    /// fails, two of them buy another recovery, and a tunnel that carries
    /// traffic perfectly well is rebuilt every ninety seconds forever (measured
    /// on an emulator: nine recoveries in sixteen minutes, with the browser
    /// loading pages through it the whole time).
    ///
    /// Nodes fronted by a CDN feel this worst — the first request has a TLS
    /// handshake and an HTTP session to build before anything can pass — which
    /// is why the panel's shutdown-bypass host looked broken while working.
    private fun expeditedDelayMs(): Long =
        maxOf(NETWORK_SETTLE_DELAY_MS, FIRST_CHECK_DELAY_MS - (uptimeMs() - tunnelUpSinceMs))

    private fun runProbe() {
        if (probeInFlight) return
        if (!isTunnelUp()) return
        if (!hasUpstreamNetwork()) {
            policy.onProbeSkipped()
            return
        }
        val executor = probeExecutor ?: return
        probeInFlight = true
        runCatching {
            executor.execute {
                val verdict = runCatching { probe.run() }
                    .getOrDefault(VpnTunnelHealthVerdict.UNKNOWN)
                handler.post { onVerdict(verdict) }
            }
        }.onFailure {
            // The executor was shut down between the null check and here (the
            // tunnel stopped mid-probe). Nothing to recover from.
            probeInFlight = false
        }
    }

    private fun onVerdict(verdict: VpnTunnelHealthVerdict) {
        probeInFlight = false
        if (!started) return
        val wasUnhealthy = policy.isUnhealthy
        val recovery = policy.onVerdict(verdict)
        if (verdict == VpnTunnelHealthVerdict.HEALTHY) {
            if (wasUnhealthy) {
                Log.i(logTag, "Tunnel health restored")
            }
            return
        }
        when (recovery) {
            VpnTunnelRecovery.NONE -> {
                if (verdict == VpnTunnelHealthVerdict.DEAD) {
                    Log.w(
                        logTag,
                        "Tunnel is up but passes no traffic (${policy.failureStreak} in a row)",
                    )
                }
            }

            VpnTunnelRecovery.RESTART -> {
                Log.w(
                    logTag,
                    "Tunnel passes no traffic; restarting it (recovery ${policy.recoveryCount})",
                )
                restartCore()
            }
        }
    }
}
