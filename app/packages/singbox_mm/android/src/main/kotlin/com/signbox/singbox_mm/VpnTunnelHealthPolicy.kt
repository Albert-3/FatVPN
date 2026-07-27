package com.signbox.singbox_mm

/// What the policy wants done about the tunnel after the latest verdict.
internal enum class VpnTunnelRecovery {
    NONE,

    /// The full stop/start the user would otherwise do by hand: a fresh command
    /// server, a re-prepared config and a new tun device.
    ///
    /// Deliberately the *only* repair on offer. libbox can also reload a core in
    /// place, which is cheaper — but the service's reload path re-reads the
    /// config file raw, skipping the preparation the start path applies to it
    /// (see VpnCoreLifecycleCoordinator.prepareConfig), and nothing in this app
    /// has ever exercised it. A recovery that runs unattended on a user's phone
    /// is the wrong place to be the first caller of an untried path.
    RESTART,
}

/// Decides when a tunnel that reports itself as connected has actually stopped
/// working, and how hard to hit it.
///
/// Split out of [VpnTunnelHealthWatchdog] so the judgement — which is all
/// thresholds, counters and a clock — can be exercised without a live tunnel,
/// an Android looper or a real minute of waiting.
internal class VpnTunnelHealthPolicy(
    private val nowMs: () -> Long = { System.currentTimeMillis() },
) {
    internal companion object {
        /// One failed probe is a blip; two in a row is a broken tunnel.
        const val FAILURES_BEFORE_RECOVERY = 2

        /// Floor on how often the tunnel may be rebuilt. Recovery is disruptive
        /// enough that doing it back-to-back would be worse than the symptom.
        const val MIN_RECOVERY_INTERVAL_MS = 90_000L

        /// How often a live tunnel is asked whether it still works.
        const val CHECK_INTERVAL_MS = 60_000L

        /// Slower cadence once repeated recoveries haven't helped, so a
        /// genuinely unreachable server can't turn into a battery drain.
        const val BACKOFF_INTERVAL_MS = 300_000L
        const val RECOVERIES_BEFORE_BACKOFF = 4
    }

    private var consecutiveFailures = 0
    private var recoveryAttempts = 0
    private var lastRecoveryAtMs: Long? = null

    /// True while there is unresolved evidence against the tunnel — either
    /// failed probes or recoveries that haven't yet been vindicated by a
    /// healthy one. Read for logging, so a recovered tunnel says so once
    /// instead of every minute.
    val isUnhealthy: Boolean
        get() = consecutiveFailures > 0 || recoveryAttempts > 0

    val failureStreak: Int
        get() = consecutiveFailures

    val recoveryCount: Int
        get() = recoveryAttempts

    /// How long until the next check should run.
    val checkIntervalMs: Long
        get() = if (recoveryAttempts >= RECOVERIES_BEFORE_BACKOFF) {
            BACKOFF_INTERVAL_MS
        } else {
            CHECK_INTERVAL_MS
        }

    /// A tunnel has just come up (or been rebuilt).
    ///
    /// Deliberately keeps [recoveryAttempts] and the last-recovery time: a
    /// recovery *is* a restart, and forgetting here would let a server that is
    /// simply down be rebuilt every 90 seconds forever. Only real evidence that
    /// the tunnel works again — a healthy probe — clears those.
    fun onTunnelStarted() {
        consecutiveFailures = 0
    }

    /// No probe was possible: the device has no upstream at all. A phone in a
    /// lift has nothing for the tunnel to carry, and counting that against it
    /// would fire a recovery the tunnel hadn't earned the moment signal returns.
    fun onProbeSkipped() {
        consecutiveFailures = 0
    }

    fun onVerdict(verdict: VpnTunnelHealthVerdict): VpnTunnelRecovery {
        when (verdict) {
            VpnTunnelHealthVerdict.HEALTHY -> {
                consecutiveFailures = 0
                recoveryAttempts = 0
                return VpnTunnelRecovery.NONE
            }

            // Nothing was established either way; leave the counters alone so an
            // inconclusive round neither accuses the tunnel nor absolves it.
            VpnTunnelHealthVerdict.UNKNOWN -> return VpnTunnelRecovery.NONE

            VpnTunnelHealthVerdict.DEAD -> {
                consecutiveFailures++
                if (consecutiveFailures < FAILURES_BEFORE_RECOVERY) {
                    return VpnTunnelRecovery.NONE
                }
                return startRecovery()
            }
        }
    }

    private fun startRecovery(): VpnTunnelRecovery {
        val now = nowMs()
        val last = lastRecoveryAtMs
        if (last != null && now - last < MIN_RECOVERY_INTERVAL_MS) {
            return VpnTunnelRecovery.NONE
        }
        lastRecoveryAtMs = now
        recoveryAttempts++
        consecutiveFailures = 0
        return VpnTunnelRecovery.RESTART
    }
}
