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

            if let dnsServer = try? options.getDNSServerAddress() {
                settings.dnsSettings = NEDNSSettings(servers: [dnsServer.value])
            }

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
            settings.ipv4Settings = ipv4Settings

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
            settings.ipv6Settings = ipv6Settings
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

        guard let tunFd = Self.tunnelFileDescriptor(packetFlow: tunnel.packetFlow) else {
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
    /// Must be called only *after* setTunnelNetworkSettings has been applied:
    /// the utun interface (and thus its fd) doesn't exist until then.
    ///
    /// Constants are hardcoded to stay header-free — SYSPROTO_CONTROL /
    /// UTUN_OPT_IFNAME / IFNAMSIZ live in <sys/kern_control.h> and
    /// <net/if_utun.h>, absent from the Swift module without a bridging header,
    /// and are ABI-fixed.
    static func tunnelFileDescriptor(packetFlow: NEPacketTunnelFlow) -> Int32? {
        let sysprotoControl: Int32 = 2  // SYSPROTO_CONTROL (getsockopt level)
        let utunOptIfName: Int32 = 2    // UTUN_OPT_IFNAME (option name)
        let ifNameSize = 16             // IFNAMSIZ

        for fd in Int32(0)...1024 {
            var buffer = [CChar](repeating: 0, count: ifNameSize)
            var length = socklen_t(buffer.count)
            let resolved = getsockopt(fd, sysprotoControl, utunOptIfName, &buffer, &length) == 0
            guard resolved else { continue }
            if String(cString: buffer).hasPrefix("utun") {
                return fd
            }
        }
        return nil
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

    func clearDNSCache() {
        guard let networkSettings, let tunnel else { return }
        tunnel.reasserting = true
        tunnel.setTunnelNetworkSettings(nil) { _ in
            tunnel.setTunnelNetworkSettings(networkSettings) { _ in
                tunnel.reasserting = false
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
        semaphore.wait()
    }

    private func reportDefaultInterface(_ listener: LibboxInterfaceUpdateListenerProtocol, _ path: Network.NWPath) {
        guard path.status != .unsatisfied, let defaultInterface = path.availableInterfaces.first else {
            listener.updateDefaultInterface("", interfaceIndex: -1, isExpensive: false, isConstrained: false)
            return
        }
        listener.updateDefaultInterface(defaultInterface.name, interfaceIndex: Int32(defaultInterface.index), isExpensive: path.isExpensive, isConstrained: path.isConstrained)
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

    func includeAllNetworks() -> Bool {
        false
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
        let _: Void = try runBlocking { [weak self] completion in
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

    func serviceStop() throws {
        tunnel?.stopService()
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
