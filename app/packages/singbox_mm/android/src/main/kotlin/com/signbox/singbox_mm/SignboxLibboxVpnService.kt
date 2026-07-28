package com.signbox.singbox_mm

import android.content.Intent
import android.net.VpnService

class SignboxLibboxVpnService : VpnService() {
    private val runtimeGraph by lazy {
        VpnServiceRuntimeGraph(
            service = this,
        )
    }

    override fun onCreate() {
        super.onCreate()
        // Marks the tunnel as genuinely alive in this process — see
        // VpnServiceLiveness for why the on-disk snapshot alone can't be trusted.
        VpnServiceLiveness.isRunning = true
        VpnServiceLiveness.active = this
        runtimeGraph.onCreate()
    }

    override fun onDestroy() {
        VpnServiceLiveness.isRunning = false
        VpnServiceLiveness.active = null
        runtimeGraph.onDestroyBeforeSuper()
        super.onDestroy()
    }

    override fun onRevoke() {
        runtimeGraph.onRevoke()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        return runtimeGraph.onStartCommand(
            intentAction = intent?.action,
            intentConfigPath = intent?.getStringExtra(SignboxLibboxServiceContract.EXTRA_CONFIG_PATH),
        )
    }
}
