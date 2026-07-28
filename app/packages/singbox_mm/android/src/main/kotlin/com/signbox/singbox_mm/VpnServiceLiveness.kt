package com.signbox.singbox_mm

/// Whether a tunnel service instance is alive in *this* process.
///
/// Kept out of [SignboxLibboxVpnService] on purpose: the state contract reads
/// this flag, the service reaches the contract through its runtime graph, and
/// hanging the flag off the service class would close that loop and leave the
/// compiler unable to resolve the graph's type.
///
/// Why a process-scoped flag is the right cross-check for the on-disk runtime
/// snapshot: the snapshot records the last state the service managed to write,
/// which is not the same as the tunnel still running. A process death —
/// force-stop, a low-memory kill, a crash — tears the service down without
/// giving it a chance to record "disconnected", so the file keeps claiming
/// "connected" forever. This flag deliberately does *not* survive that: a fresh
/// process starts false (the tunnel really is gone), and a service the OS
/// restarted via START_STICKY sets it true again (the tunnel really is back).
internal object VpnServiceLiveness {
    @Volatile
    var isRunning: Boolean = false

    /// The live service, or null when no tunnel is up.
    ///
    /// Held so a socket can be handed to `VpnService.protect()` before it
    /// connects. This app is tunnelled like any other (see
    /// [VpnTunBuilderConfigurator]), so an unprotected connect to a candidate
    /// node measures "device → current server → candidate" and fails outright
    /// once the current server stops passing traffic — which is exactly when a
    /// replacement has to be picked.
    @Volatile
    var active: android.net.VpnService? = null
}
