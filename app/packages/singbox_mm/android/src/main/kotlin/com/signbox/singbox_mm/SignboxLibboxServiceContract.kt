package com.signbox.singbox_mm

import android.content.Context

internal object SignboxLibboxServiceContract {
    const val LOG_TAG = "SignboxLibboxService"
    const val NOTIFICATION_CHANNEL_ID = "singbox_mm_channel"
    const val NOTIFICATION_CHANNEL_NAME = "Singbox VPN"
    const val NOTIFICATION_ID = 0x6B01
    const val REQUEST_OPEN_APP_ACTION = 0x6B02
    const val REQUEST_STOP_ACTION = 0x6B03
    const val REQUEST_RESTART_ACTION = 0x6B04
    const val DEFAULT_PROFILE_LABEL = "profile"
    const val PRIVATE_DNS_BOOTSTRAP_DNS_SERVER = "1.1.1.1"
    const val CORE_COMMAND_PORT = 3000
    const val NOTIFICATION_STATS_INTERVAL_MS = 1000L
    const val ACTION_START = "com.signbox.singbox_mm.action.START"
    const val ACTION_STOP = "com.signbox.singbox_mm.action.STOP"
    const val ACTION_RESTART = "com.signbox.singbox_mm.action.RESTART"
    const val ACTION_STATE_UPDATE = "com.signbox.singbox_mm.action.STATE"
    const val STATE_BROADCAST_PERMISSION_SUFFIX = ".permission.SIGNBOX_STATE"
    const val EXTRA_CONFIG_PATH = "configPath"
    const val EXTRA_STATE = "state"
    const val EXTRA_ERROR = "error"
    const val ERROR_STOPPED_BY_USER = "STOPPED_BY_USER"
    const val STATE_DISCONNECTED = "disconnected"
    const val STATE_PREPARING = "preparing"
    const val STATE_CONNECTING = "connecting"
    const val STATE_CONNECTED = "connected"
    const val STATE_ERROR = "error"

    fun stateBroadcastPermission(packageName: String): String {
        return packageName + STATE_BROADCAST_PERMISSION_SUFFIX
    }

    fun readPersistedRuntimeState(context: Context): PersistedRuntimeState? {
        return VpnRuntimeSnapshotStore.read(context)?.let(::reconcileWithRunningService)
    }

    /// Downgrades a snapshot that claims the tunnel is up when no service is
    /// actually running in this process.
    ///
    /// The snapshot is a record of the last state the service wrote, not proof
    /// the tunnel survived. Whenever the process dies without an orderly stop —
    /// force-stop, a low-memory kill, a crash — the file is left saying
    /// "connected", and every later read repeats that claim. The app trusted it
    /// and showed a connected tunnel with a running session timer while the tun
    /// device no longer existed, which is indistinguishable to the user from a
    /// VPN that simply stopped passing traffic.
    ///
    /// Stats are reset alongside the state so the session does not resume
    /// counting from a byte total that belongs to a tunnel that is gone.
    private fun reconcileWithRunningService(snapshot: PersistedRuntimeState): PersistedRuntimeState {
        val claimsTunnelUp = snapshot.state == STATE_CONNECTED ||
            snapshot.state == STATE_CONNECTING ||
            snapshot.state == STATE_PREPARING
        if (!claimsTunnelUp || VpnServiceLiveness.isRunning) {
            return snapshot
        }
        return snapshot.copy(
            state = STATE_DISCONNECTED,
            connectedAtMillis = null,
            uplinkBytesBase = 0L,
            downlinkBytesBase = 0L,
        )
    }

    fun start(context: Context, configPath: String) {
        VpnServiceLauncher.start(
            context = context,
            serviceClass = SignboxLibboxVpnService::class.java,
            startAction = ACTION_START,
            configPathExtraKey = EXTRA_CONFIG_PATH,
            configPath = configPath,
        )
    }

    fun stop(context: Context) {
        VpnServiceLauncher.stop(
            context = context,
            serviceClass = SignboxLibboxVpnService::class.java,
            stopAction = ACTION_STOP,
        )
    }
}
