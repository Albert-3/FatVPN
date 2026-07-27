package com.signbox.singbox_mm

import android.content.pm.PackageManager
import android.net.VpnService
import android.util.Log

internal object VpnPackageAccessController {
    /// Adds one package to the tun device's allow-list.
    ///
    /// This app's own package used to be silently dropped here, from back when
    /// it was excluded from the tunnel outright and allowing it would have
    /// contradicted that. It is now deliberately tunnelled like any other app
    /// (see [VpnTunBuilderConfigurator]), so the skip had become a way to quietly
    /// undo the one entry [VpnSplitTunnelPackages] exists to guarantee.
    fun addAllowedPackage(
        builder: VpnService.Builder,
        packageName: String,
        logTag: String,
    ) {
        runCatching {
            builder.addAllowedApplication(packageName)
        }.onFailure {
            if (it !is PackageManager.NameNotFoundException) {
                Log.w(logTag, "Unable to add allowed package '$packageName'", it)
            }
        }
    }

    fun addDisallowedPackage(
        builder: VpnService.Builder,
        packageName: String,
        logTag: String,
    ) {
        runCatching {
            builder.addDisallowedApplication(packageName)
        }.onFailure {
            if (it !is PackageManager.NameNotFoundException) {
                Log.w(logTag, "Unable to add disallowed package '$packageName'", it)
            }
        }
    }
}
