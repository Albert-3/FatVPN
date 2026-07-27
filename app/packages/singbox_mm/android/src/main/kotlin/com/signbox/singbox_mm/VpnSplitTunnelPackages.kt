package com.signbox.singbox_mm

/// Turns the core's `include_package` list into the set of packages the tun
/// device is actually opened for.
///
/// Split out of [VpnTunBuilderConfigurator] so the one rule that matters here
/// can be checked without a VpnService, a builder or a device.
internal object VpnSplitTunnelPackages {
    /// The allow-list to hand to `VpnService.Builder.addAllowedApplication`.
    ///
    /// Empty in, empty out: an allow-list is all-or-nothing on Android, so
    /// "allow nothing" would mean a tunnel no app can use. Nothing named means
    /// no per-app filtering at all, which is the full tunnel.
    ///
    /// Otherwise this app is always added to whatever the user picked. An
    /// allow-list that omits it is the regression [VpnTunBuilderConfigurator]
    /// warns about: every request the app itself makes — its API traffic, its
    /// own reachability checks — would leave the device outside the tunnel
    /// while the UI said "connected", and any probe from there would measure
    /// the direct path and report success over a completely dead tunnel.
    /// Whether the user wants *their* apps tunnelled says nothing about where
    /// our own bookkeeping traffic belongs.
    fun allowedPackages(
        includedPackages: List<String>,
        hostPackageName: String,
    ): List<String> {
        if (includedPackages.isEmpty()) {
            return emptyList()
        }
        val allowed = LinkedHashSet<String>()
        for (packageName in includedPackages) {
            val trimmed = packageName.trim()
            if (trimmed.isNotEmpty()) {
                allowed.add(trimmed)
            }
        }
        if (allowed.isEmpty()) {
            return emptyList()
        }
        allowed.add(hostPackageName)
        return allowed.toList()
    }
}
