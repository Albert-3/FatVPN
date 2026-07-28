import Foundation
import Libbox
import Network
import NetworkExtension

/// Implements the native side sing-box's Go runtime calls into: opening the
/// TUN device (backed by NEPacketTunnelFlow's underlying socket), converting
/// sing-box's TunOptions into NEPacketTunnelNetworkSettings, and default
/// network interface monitoring. Method signatures here match the actual
/// generated Libbox.objc.h for our pinned sing-box version (v1.13.11, see
/// fetch_singbox_libbox_ios.sh) — note Swift's ClangImporter silently
/// shortens some selectors it considers redundant (e.g. ObjC
/// `sendNotification:` becomes Swift `send(_:)`, `autoDetectInterfaceControl:`
/// becomes `autoDetectControl(_:)`), so the Swift name doesn't always match
/// the header text verbatim — when in doubt, let the compiler's "has been
/// renamed to" error tell you the real name rather than guessing from the
/// header.
class ExtensionPlatformInterface: NSObject, LibboxPlatformInterfaceProtocol, LibboxCommandServerHandlerProtocol {
    private weak var tunnel: PacketTunnelProvider?
    private var networkSettings: NEPacketTunnelNetworkSettings?
    private var nwMonitor: NWPathMonitor?

    init(_ tunnel: PacketTunnelProvider) {
        self.tunnel = tunnel
    }

    func reset() {
        networkSettings = nil
        nwMonitor?.cancel()
        nwMonitor = nil
    }

    private func log(_ message: String) {
        tunnel?.writeMessage(message)
    }

    // MARK: - LibboxPlatformInterfaceProtocol

    func openTun(_ options: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        guard let options else {
            throw TunnelStartupError(message: "openTun: nil options")
        }
        guard let ret0_ else {
            throw TunnelStartupError(message: "openTun: nil return pointer")
        }
        guard let tunnel else {
            throw TunnelStartupError(message: "openTun: tunnel provider deallocated")
        }

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")

        if options.getAutoRoute() {
            settings.mtu = NSNumber(value: options.getMTU())

            // Not `try?`. A swallowed failure here left `dnsSettings` nil, which
            // is not "no DNS" but "the system's own resolvers" — every lookup
            // then leaves the device over the physical interface, in the clear,
            // with no error and no log line to say so. A tunnel that cannot
            // carry DNS is a tunnel that must not come up.
            let dnsServer: LibboxStringBox
            do {
                dnsServer = try options.getDNSServerAddress()
            } catch {
                throw TunnelStartupError(
                    message: "openTun: sing-box provided no DNS server address "
                        + "(\(error.localizedDescription))")
            }
            let dnsSettings = NEDNSSettings(servers: [dnsServer.value])
            // The canonical pattern (WireGuard-iOS, sing-box-for-apple): an
            // empty match domain is the "" suffix every name ends with, which
            // forces iOS to send *all* queries to the tunnel's resolver instead
            // of letting some system paths keep their own.
            dnsSettings.matchDomains = [""]
            settings.dnsSettings = dnsSettings

            var ipv4Addresses: [String] = []
            var ipv4Masks: [String] = []
            if let it = options.getInet4Address() {
                while it.hasNext() {
                    guard let prefix = it.next() else { break }
                    ipv4Addresses.append(prefix.address())
                    ipv4Masks.append(prefix.mask())
                }
            }
            let ipv4Settings = NEIPv4Settings(addresses: ipv4Addresses, subnetMasks: ipv4Masks)
            let ipv4RouteAddresses = routePrefixes(options.getInet4RouteAddress())
            ipv4Settings.includedRoutes = ipv4RouteAddresses.isEmpty
                ? [NEIPv4Route.default()]
                : ipv4RouteAddresses.map { NEIPv4Route(destinationAddress: $0.address(), subnetMask: $0.mask()) }
            ipv4Settings.excludedRoutes = routePrefixes(options.getInet4RouteExcludeAddress()).map {
                NEIPv4Route(destinationAddress: $0.address(), subnetMask: $0.mask())
            }
            // Claiming a default route on a family the interface holds no
            // address for is undefined: iOS either rejects the whole settings
            // object (openTun fails) or ignores that half of it — and the
            // second outcome sends every packet of that family around the
            // tunnel, over the physical interface, with the user's real
            // address. That is exactly what happened to IPv6 under the default
            // config (`ipv6RouteMode = disable` + `domain_strategy =
            // ipv4_only`), and a DNS-leak test cannot see it.
            settings.ipv4Settings = ipv4Addresses.isEmpty ? nil : ipv4Settings

            var ipv6Addresses: [String] = []
            var ipv6Prefixes: [NSNumber] = []
            if let it = options.getInet6Address() {
                while it.hasNext() {
                    guard let prefix = it.next() else { break }
                    ipv6Addresses.append(prefix.address())
                    ipv6Prefixes.append(NSNumber(value: prefix.prefix()))
                }
            }
            let ipv6Settings = NEIPv6Settings(addresses: ipv6Addresses, networkPrefixLengths: ipv6Prefixes)
            let ipv6RouteAddresses = routePrefixes(options.getInet6RouteAddress())
            ipv6Settings.includedRoutes = ipv6RouteAddresses.isEmpty
                ? [NEIPv6Route.default()]
                : ipv6RouteAddresses.map { NEIPv6Route(destinationAddress: $0.address(), networkPrefixLength: NSNumber(value: $0.prefix())) }
            ipv6Settings.excludedRoutes = routePrefixes(options.getInet6RouteExcludeAddress()).map {
                NEIPv6Route(destinationAddress: $0.address(), networkPrefixLength: NSNumber(value: $0.prefix()))
            }
            settings.ipv6Settings = ipv6Addresses.isEmpty ? nil : ipv6Settings

            if ipv4Addresses.isEmpty && ipv6Addresses.isEmpty {
                throw TunnelStartupError(
                    message: "openTun: sing-box assigned the tunnel no address at all")
            }
        }

        if options.isHTTPProxyEnabled() {
            let proxySettings = NEProxySettings()
            let proxyServer = NEProxyServer(address: options.getHTTPProxyServer(), port: Int(options.getHTTPProxyServerPort()))
            proxySettings.httpServer = proxyServer
            proxySettings.httpsServer = proxyServer
            proxySettings.httpEnabled = true
            proxySettings.httpsEnabled = true
            settings.proxySettings = proxySettings
        }

        networkSettings = settings

        let _: Void = try runBlocking { completion in
            tunnel.setTunnelNetworkSettings(settings) { error in
                if let error {
                    completion(.failure(error))
                } else {
                    completion(.success(()))
                }
            }
        }

        guard let tunFd = Self.tunnelFileDescriptor(
            packetFlow: tunnel.packetFlow,
            log: { [weak self] message in self?.log(message) })
        else {
            throw TunnelStartupError(message: "openTun: unable to obtain tunnel file descriptor")
        }
        ret0_.pointee = tunFd
    }

    /// Resolves the TUN interface's file descriptor.
    ///
    /// iOS exposes no public API for this, and the old private KVC path
    /// (`packetFlow.value(forKeyPath: "socket.fileDescriptor")`) returns nil on
    /// iOS 17.x — Apple closed access to NEPacketTunnelFlow's internals — which
    /// is what "unable to obtain tunnel file descriptor" meant. So we identify
    /// the descriptor the way WireGuard-iOS and sing-box-for-apple do: scan the
    /// process's open descriptors and ask each socket for its utun *interface
    /// name* via getsockopt(SYSPROTO_CONTROL, UTUN_OPT_IFNAME); the one whose
    /// name starts with "utun" is the tunnel this extension created. This is
    /// robust because it keys off the utun identity itself (not an indirect
    /// family+type guess, which can match unrelated AF_SYSTEM sockets), uses
    /// only public POSIX calls (no private KVC that App Store review may flag),
    /// and a NEPacketTunnelProvider process holds an fd for essentially just its
    /// own utun — the system's other utun* interfaces belong to other processes
    /// and aren't in this fd table.
    ///
    /// The scan runs to `getdtablesize()` rather than a hardcoded 1024, so it
    /// cannot miss a descriptor on a process that was given a larger table.
    ///
    /// When more than one utun descriptor is open, **there is no way to tell
    /// which one is ours** — iOS exposes no mapping from NEPacketTunnelFlow to a
    /// descriptor, which is the whole reason this scan exists, and descriptor
    /// numbers say nothing about age either (the kernel hands out the lowest
    /// free one, so a reused low number can be the newest interface). So this
    /// keeps the shipped choice — the first match, which is what the device
    /// testing behind the current build ran on — and logs when the situation is
    /// ambiguous, so a case that has never actually been observed becomes
    /// visible instead of silently picking wrong. In practice a packet-tunnel
    /// provider holds exactly one: libbox closes the previous utun before
    /// `openTun` runs again on a reload, and a closed descriptor fails the
    /// getsockopt below.
    ///
    /// Must be called only *after* setTunnelNetworkSettings has been applied:
    /// the utun interface (and thus its fd) doesn't exist until then.
    ///
    /// Constants are hardcoded to stay header-free — SYSPROTO_CONTROL /
    /// UTUN_OPT_IFNAME / IFNAMSIZ live in <sys/kern_control.h> and
    /// <net/if_utun.h>, absent from the Swift module without a bridging header,
    /// and are ABI-fixed.
    static func tunnelFileDescriptor(
        packetFlow: NEPacketTunnelFlow,
        log: ((String) -> Void)? = nil
    ) -> Int32? {
        let sysprotoControl: Int32 = 2  // SYSPROTO_CONTROL (getsockopt level)
        let utunOptIfName: Int32 = 2    // UTUN_OPT_IFNAME (option name)
        let ifNameSize = 16             // IFNAMSIZ

        var matches: [(fd: Int32, name: String)] = []
        let limit = max(getdtablesize(), 1024)
        for fd in Int32(0)..<Int32(limit) {
            var buffer = [CChar](repeating: 0, count: ifNameSize)
            var length = socklen_t(buffer.count)
            let resolved = getsockopt(fd, sysprotoControl, utunOptIfName, &buffer, &length) == 0
            guard resolved else { continue }
            let name = String(cString: buffer)
            if name.hasPrefix("utun") {
                matches.append((fd, name))
            }
        }
        guard let chosen = matches.first else { return nil }
        if matches.count > 1 {
            log?(
                "(packet-tunnel) ambiguous TUN descriptor: \(matches.count) utun "
                    + "interfaces open (\(matches.map { $0.name }.joined(separator: ", "))) "
                    + "— using \(chosen.name), which may be the wrong one")
        }
        return chosen.fd
    }

    private func routePrefixes(_ iterator: (any LibboxRoutePrefixIteratorProtocol)?) -> [LibboxRoutePrefix] {
        guard let iterator else { return [] }
        var result: [LibboxRoutePrefix] = []
        while iterator.hasNext() {
            guard let prefix = iterator.next() else { break }
            result.append(prefix)
        }
        return result
    }

    func autoDetectControl(_ fd: Int32) throws {
        // Not required for a plain client tunnel (no VPN-over-VPN loopback
        // avoidance needed here) — sing-box only calls this when it manages
        // its own outbound sockets that must bypass the tunnel interface,
        // which the OS already does correctly for NEPacketTunnelProvider.
    }

    /// sing-box asks for the system resolver cache to be dropped — which it
    /// does on every network event: Wi-Fi↔LTE, an AP re-association, a DHCP
    /// renewal.
    ///
    /// Re-applying the settings we already have is enough to make iOS
    /// reinstall the resolvers. This used to clear them to `nil` first, and
    /// that window — hundreds of milliseconds, longer on a slow device — is a
    /// live tunnel with *no routes at all*: everything sent during it leaves
    /// over the physical interface with the user's real address and their
    /// carrier's DNS. Worse, both callbacks were ignored, so a failed re-apply
    /// left the tunnel permanently route-less while iOS still reported
    /// `.connected`.
    func clearDNSCache() {
        guard let networkSettings, let tunnel else { return }
        tunnel.reasserting = true
        tunnel.setTunnelNetworkSettings(networkSettings) { [weak self] error in
            // Always cleared: `reasserting` stuck at true is reported to the app
            // as `.reasserting`, which it shows as "Connecting…" — forever.
            tunnel.reasserting = false
            if let error {
                self?.log("(packet-tunnel) clearDNSCache re-apply failed: \(error.localizedDescription)")
            }
        }
    }

    func closeDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        nwMonitor?.cancel()
        nwMonitor = nil
    }

    func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        guard let listener else { return }
        let monitor = NWPathMonitor()
        nwMonitor = monitor
        let semaphore = DispatchSemaphore(value: 0)
        var first = true
        monitor.pathUpdateHandler = { [weak self] path in
            self?.reportDefaultInterface(listener, path)
            if first {
                first = false
                semaphore.signal()
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        // Bounded: this blocks a Go thread inside service start, and a first
        // path update that never arrives (no network at all at launch) would
        // otherwise hang the whole tunnel start rather than starting it with an
        // interface it learns about a moment later.
        if semaphore.wait(timeout: .now() + 10) == .timedOut {
            log("(packet-tunnel) no network path reported within 10s; starting anyway")
        }
    }

    private func reportDefaultInterface(_ listener: LibboxInterfaceUpdateListenerProtocol, _ path: Network.NWPath) {
        // This tells sing-box which interface is the *underlay* — the one it
        // opens its outbound sockets to the VPN server on. It must never be our
        // own tunnel: once setTunnelNetworkSettings has applied, the utun we
        // created shows up in availableInterfaces and can sort first, and
        // reporting it here makes sing-box dial the server through the tunnel
        // itself. Traffic then loops back into the TUN and dies — while
        // NEVPNStatus stays .connected, so iOS and the app keep showing
        // "connected" with the session timer running.
        //
        // The first path update arrives before openTun (sing-box starts the
        // monitor during service start), so a fresh connection looks fine; the
        // breakage lands on the *next* path update — a Wi-Fi/cellular switch,
        // an AP re-association, a DHCP renewal — which is why the tunnel dies
        // abruptly mid-session rather than at connect time.
        let underlay = path.availableInterfaces.first { !$0.name.hasPrefix("utun") }
        guard path.status != .unsatisfied, let defaultInterface = underlay else {
            listener.updateDefaultInterface("", interfaceIndex: -1, isExpensive: false, isConstrained: false)
            tunnel?.underlayDidChange()
            return
        }
        listener.updateDefaultInterface(defaultInterface.name, interfaceIndex: Int32(defaultInterface.index), isExpensive: path.isExpensive, isConstrained: path.isConstrained)
        // Per the note above, this is the exact moment a live tunnel breaks. Tell
        // the health watchdog so it re-checks in seconds instead of waiting out
        // its own interval.
        tunnel?.underlayDidChange()
    }

    /// Whether the device has any non-tunnel network at all.
    ///
    /// Read by the health watchdog before it blames the tunnel for carrying no
    /// traffic: a phone in a lift has nothing for the tunnel to carry, and
    /// rebuilding it over that would be wrong. `true` when we cannot tell — an
    /// absent signal must not silently disable the watchdog, and the probe
    /// itself is better evidence than a missing monitor.
    var hasUsableUpstream: Bool {
        guard let path = nwMonitor?.currentPath else { return true }
        if path.status == .unsatisfied { return false }
        return path.availableInterfaces.contains { !$0.name.hasPrefix("utun") }
    }

    /// Whether the underlay is metered (cellular, or a personal hotspot). The
    /// watchdog widens its interval over one: every round costs a TLS handshake
    /// out of the user's data allowance, and this process runs 24/7.
    var isUpstreamExpensive: Bool {
        nwMonitor?.currentPath.isExpensive ?? false
    }

    func findConnectionOwner(_ ipProtocol: Int32, sourceAddress: String?, sourcePort: Int32, destinationAddress: String?, destinationPort: Int32) throws -> LibboxConnectionOwner {
        throw TunnelStartupError(message: "findConnectionOwner: not implemented on iOS")
    }

    func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol {
        guard let path = nwMonitor?.currentPath, path.status != .unsatisfied else {
            return NetworkInterfaceArray([])
        }
        var interfaces: [LibboxNetworkInterface] = []
        for it in path.availableInterfaces {
            let interface = LibboxNetworkInterface()
            interface.name = it.name
            interface.index = Int32(it.index)
            switch it.type {
            case .wifi:
                interface.type = LibboxInterfaceTypeWIFI
            case .cellular:
                interface.type = LibboxInterfaceTypeCellular
            case .wiredEthernet:
                interface.type = LibboxInterfaceTypeEthernet
            default:
                interface.type = LibboxInterfaceTypeOther
            }
            interfaces.append(interface)
        }
        return NetworkInterfaceArray(interfaces)
    }

    private class NetworkInterfaceArray: NSObject, LibboxNetworkInterfaceIteratorProtocol {
        private var iterator: IndexingIterator<[LibboxNetworkInterface]>
        private var nextValue: LibboxNetworkInterface?

        init(_ array: [LibboxNetworkInterface]) {
            iterator = array.makeIterator()
        }

        func hasNext() -> Bool {
            nextValue = iterator.next()
            return nextValue != nil
        }

        func next() -> LibboxNetworkInterface? {
            nextValue
        }
    }

    /// Whether this session is a kill switch — the app sets
    /// `NEVPNProtocol.includeAllNetworks` to the same value, and sing-box needs
    /// to know so it does not route around a tunnel nothing may escape.
    /// Off unless the user asked for it (see SingboxMmPlugin.configure).
    func includeAllNetworks() -> Bool {
        tunnel?.includeAllNetworksRequested ?? false
    }

    func localDNSTransport() -> (any LibboxLocalDNSTransportProtocol)? {
        nil
    }

    func readWIFIState() -> LibboxWIFIState? {
        nil
    }

    func send(_ notification: LibboxNotification?) throws {
        // No local notification support yet — the app surfaces connection
        // state via the singbox_mm/state EventChannel instead.
    }

    func systemCertificates() -> (any LibboxStringIteratorProtocol)? {
        nil
    }

    func underNetworkExtension() -> Bool {
        true
    }

    func usePlatformAutoDetectControl() -> Bool {
        false
    }

    func useProcFS() -> Bool {
        false
    }

    // MARK: - LibboxCommandServerHandlerProtocol

    func getSystemProxyStatus() throws -> LibboxSystemProxyStatus {
        let status = LibboxSystemProxyStatus()
        guard let proxySettings = networkSettings?.proxySettings, proxySettings.httpServer != nil else {
            return status
        }
        status.available = true
        status.enabled = proxySettings.httpEnabled
        return status
    }

    func serviceReload() throws {
        // 30s rather than the default: a reload restarts the core and can wait
        // on a handshake. Still bounded, because this blocks a Go thread while
        // the detached Task below may need one.
        let _: Void = try runBlocking(timeout: 30) { [weak self] completion in
            guard let self, let tunnel = self.tunnel else {
                completion(.success(()))
                return
            }
            Task.detached {
                do {
                    try await tunnel.reloadService()
                    completion(.success(()))
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    /// sing-box asked for the service to stop — which, coming from the core, is
    /// a request to end the *session*, not merely to close the core.
    ///
    /// Closing the core alone left `NEPacketTunnelNetworkSettings` applied: the
    /// default route still pointed into a utun with nothing reading it, so the
    /// user lost the internet entirely (not "the VPN dropped" — "there is no
    /// network") while iOS and the app both went on reporting `connected`, with
    /// the session timer running. Only a manual toggle cleared it.
    func serviceStop() throws {
        tunnel?.shutdownTunnel()
    }

    func setSystemProxyEnabled(_ enabled: Bool) throws {
        guard let networkSettings, let proxySettings = networkSettings.proxySettings, proxySettings.httpServer != nil else {
            return
        }
        guard proxySettings.httpEnabled != enabled else { return }
        proxySettings.httpEnabled = enabled
        proxySettings.httpsEnabled = enabled
        networkSettings.proxySettings = proxySettings
        let _: Void = try runBlocking { [weak self] completion in
            guard let self, let tunnel = self.tunnel else {
                completion(.success(()))
                return
            }
            tunnel.setTunnelNetworkSettings(networkSettings) { error in
                if let error {
                    completion(.failure(error))
                } else {
                    completion(.success(()))
                }
            }
        }
    }

    func writeDebugMessage(_ message: String?) {
        guard let message else { return }
        tunnel?.writeMessage(message)
    }
}
