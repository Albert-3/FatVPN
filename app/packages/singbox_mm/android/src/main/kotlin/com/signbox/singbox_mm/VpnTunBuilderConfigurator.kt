package com.signbox.singbox_mm

import android.net.IpPrefix
import android.net.ProxyInfo
import android.net.VpnService
import android.os.Build
import io.nekohasekai.libbox.RoutePrefix
import io.nekohasekai.libbox.TunOptions
import java.net.InetAddress

internal object VpnTunBuilderConfigurator {
    fun configure(
        builder: VpnService.Builder,
        options: TunOptions,
        privateDnsHost: String?,
        privateDnsBootstrapDnsServer: String,
        hostPackageName: String,
        addAllowedPackage: (String) -> Unit,
        addDisallowedPackage: (String) -> Unit,
    ) {
        // Keep strict_route as a full-tunnel mode. Only enable bypass when
        // strict routing is disabled, so normal apps cannot silently escape VPN.
        val strictRouteEnabled = runCatching {
            options.strictRoute
        }.getOrDefault(true)
        if (!strictRouteEnabled) {
            builder.allowBypass()
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setMetered(false)
        }

        var hasInet4Address = false
        val inet4Address = options.inet4Address
        while (inet4Address.hasNext()) {
            val address = inet4Address.next()
            builder.addAddress(address.address(), address.prefix())
            hasInet4Address = true
        }

        var hasInet6Address = false
        val inet6Address = options.inet6Address
        while (inet6Address.hasNext()) {
            val address = inet6Address.next()
            builder.addAddress(address.address(), address.prefix())
            hasInet6Address = true
        }

        if (!options.autoRoute) {
            return
        }

        var dnsServer = runCatching {
            options.dnsServerAddress.value
        }.getOrNull()
        if (dnsServer.isNullOrBlank() && privateDnsHost != null) {
            dnsServer = privateDnsBootstrapDnsServer
        }
        if (!dnsServer.isNullOrBlank()) {
            builder.addDnsServer(dnsServer)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val inet4RouteAddress = options.inet4RouteAddress
            var hasInet4Route = false
            if (inet4RouteAddress.hasNext()) {
                while (inet4RouteAddress.hasNext()) {
                    builder.addRoute(routePrefixToIpPrefix(inet4RouteAddress.next()))
                    hasInet4Route = true
                }
            } else if (hasInet4Address) {
                builder.addRoute("0.0.0.0", 0)
            }

            val inet6RouteAddress = options.inet6RouteAddress
            var hasInet6Route = false
            if (inet6RouteAddress.hasNext()) {
                while (inet6RouteAddress.hasNext()) {
                    builder.addRoute(routePrefixToIpPrefix(inet6RouteAddress.next()))
                    hasInet6Route = true
                }
            } else if (hasInet6Address) {
                builder.addRoute("::", 0)
            }

            val inet4RouteExcludeAddress = options.inet4RouteExcludeAddress
            while (inet4RouteExcludeAddress.hasNext()) {
                builder.excludeRoute(routePrefixToIpPrefix(inet4RouteExcludeAddress.next()))
            }

            val inet6RouteExcludeAddress = options.inet6RouteExcludeAddress
            if (hasInet6Address || hasInet6Route) {
                while (inet6RouteExcludeAddress.hasNext()) {
                    builder.excludeRoute(routePrefixToIpPrefix(inet6RouteExcludeAddress.next()))
                }
            }
        } else {
            val inet4RouteRange = options.inet4RouteRange
            var hasInet4Route = false
            while (inet4RouteRange.hasNext()) {
                val route = inet4RouteRange.next()
                builder.addRoute(route.address(), route.prefix())
                hasInet4Route = true
            }
            if (!hasInet4Route && hasInet4Address) {
                builder.addRoute("0.0.0.0", 0)
            }

            val inet6RouteRange = options.inet6RouteRange
            var hasInet6Route = false
            while (inet6RouteRange.hasNext()) {
                val route = inet6RouteRange.next()
                builder.addRoute(route.address(), route.prefix())
                hasInet6Route = true
            }
            if (!hasInet6Route && hasInet6Address) {
                builder.addRoute("::", 0)
            }
        }

        val includedPackages = mutableListOf<String>()
        val includePackage = options.includePackage
        while (includePackage.hasNext()) {
            includedPackages.add(includePackage.next())
        }

        // This app is deliberately *not* excluded from the tunnel.
        //
        // Excluding it used to be the guard against self-capture loops, but the
        // loop it protects against is only ever created by sing-box's own
        // outbound sockets, and those are already handled the proper way:
        // usePlatformAutoDetectInterfaceControl() is true, so the core hands
        // every outbound fd to autoDetectInterfaceControl, which calls
        // VpnService.protect() on it. Excluding the whole package on top of
        // that bought nothing and cost a great deal — every request the app
        // itself makes, including all of its API traffic, left the device
        // outside the tunnel while the UI said "connected". It also made any
        // reachability check from here meaningless, since such a probe measured
        // the direct path and reported success over a completely dead tunnel.
        //
        // Keep this in mind when adding a package to includePackage: an
        // allow-list that omits this app puts us back in the old behaviour.

        for (included in includedPackages) {
            addAllowedPackage(included)
        }

        val excludePackage = options.excludePackage
        while (excludePackage.hasNext()) {
            addDisallowedPackage(excludePackage.next())
        }

        if (options.isHTTPProxyEnabled && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val proxyServer = options.httpProxyServer
            val proxyPort = options.httpProxyServerPort
            if (proxyServer.isNotBlank() && proxyPort > 0) {
                val bypassDomains = mutableListOf<String>()
                val bypassIterator = options.httpProxyBypassDomain
                while (bypassIterator.hasNext()) {
                    bypassDomains.add(bypassIterator.next())
                }
                builder.setHttpProxy(ProxyInfo.buildDirectProxy(proxyServer, proxyPort, bypassDomains))
            }
        }
    }

    private fun routePrefixToIpPrefix(routePrefix: RoutePrefix): IpPrefix {
        return IpPrefix(InetAddress.getByName(routePrefix.address()), routePrefix.prefix())
    }
}
