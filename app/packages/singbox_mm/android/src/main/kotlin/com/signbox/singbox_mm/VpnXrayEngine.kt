package com.signbox.singbox_mm

import android.util.Log
import io.nekohasekai.fatxray.Fatxray
import io.nekohasekai.fatxray.Protector
import java.io.File

/// The second core, for nodes sing-box cannot speak to.
///
/// It runs in this process rather than the app's because of the socket it opens
/// to the node: only the VPN service can hand a file descriptor to
/// `VpnService.protect`, and without that the core's own connection is captured
/// by the tun device it is feeding — sing-box would route it straight back to
/// the core's SOCKS port and the session would deadlock on itself.
internal object VpnXrayEngine {
    /// Brings the core up for [configFile], or makes sure it is down when that
    /// file is absent.
    ///
    /// Absence is the normal case: the app writes the file only for a node that
    /// needs Xray and deletes it otherwise, so "no file" means "sing-box alone"
    /// rather than a missing prerequisite.
    ///
    /// Throws when a core that is wanted fails to come up. The caller treats
    /// that as a failed connect, which is the honest outcome: sing-box would
    /// otherwise start and dial a SOCKS port with nothing behind it.
    fun applyConfig(
        configFile: File,
        protectSocket: (Int) -> Boolean,
        logTag: String,
    ) {
        if (!configFile.isFile) {
            stop(logTag)
            return
        }

        val config = configFile.readText()
        if (config.isBlank()) {
            stop(logTag)
            return
        }

        // A start on top of a live core is refused by the core itself, and this
        // path is re-entered on every restart the health watchdog schedules.
        stop(logTag)

        Fatxray.setProtector(
            object : Protector {
                override fun protect(fd: Long): Boolean = protectSocket(fd.toInt())
            },
        )
        Fatxray.start(config)
        Log.i(logTag, "Xray core started (${Fatxray.version()})")
    }

    fun stop(logTag: String) {
        runCatching { Fatxray.stop() }
            .onFailure { Log.w(logTag, "Xray core stop failed", it) }
    }
}
