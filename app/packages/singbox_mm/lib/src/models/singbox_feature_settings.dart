import 'package:flutter/foundation.dart';

import 'singbox_rule_set.dart';

/// SingboxServiceMode enum.
enum SingboxServiceMode { vpn, proxyOnly }

/// SingboxTunImplementation enum.
enum SingboxTunImplementation { system, gvisor }

/// TUN MTU used when [InboundOptions.mtu] names none.
///
/// 1100 everywhere used to be hardcoded in the config builder — very
/// conservative next to the 1280–1420 a VPN tunnel normally carries, and every
/// byte below the real path MTU is throughput given away: ~20% more packets
/// than 1400 needs, each of them another trip through the userspace stack,
/// which on iOS is also another slice of a battery and of a 50 MB memory
/// budget.
///
/// 1280 is the IPv6 minimum link MTU, so nothing on a v6 path may fragment
/// below it, and it still leaves room for the outbound's own encapsulation.
///
/// Android was raised to it on 2026-08-02, and **not** as a throughput tweak:
/// it is a precondition of [defaultTunInet6Address]. An interface below 1280
/// may not carry IPv6 at all — the kernel refuses the address rather than
/// negotiating — so a TUN asking for both 1100 and an inet6 address either
/// comes up without v6 or does not come up. The first outcome is the dangerous
/// one: the leak would stay open while every reading of the config said it was
/// closed. The two values move together or not at all.
///
/// 1100 stays for anything that is neither: it is well below every path MTU and
/// safe by construction, and no such platform ships a TUN here today.
int get defaultTunMtu => switch (defaultTargetPlatform) {
  TargetPlatform.iOS || TargetPlatform.android => 1280,
  _ => 1100,
};

/// IPv6 address given to the TUN interface, or null to leave it IPv4-only.
///
/// A leak fix rather than a feature. The config already blocks `::/0` inside
/// sing-box (see `SingboxRouteRulesBuilder`, under `ipv6RouteMode == disable`)
/// — but a rule can only act on packets that reach the core, and an OS routes
/// nothing of a family the tunnel interface holds no address for. With no inet6
/// address the whole v6 half of the device's traffic goes around the tunnel on
/// an IPv6-enabled carrier, in the clear, with the user's real address: a leak
/// a DNS-leak test cannot see, because DNS is not what leaks. Giving the
/// interface an address is what puts `::/0` in front of the block rule.
///
/// The prefix is sing-box's own documented TUN default, chosen from the unique
/// local range so it cannot collide with anything routable.
///
/// **Android joined iOS here on 2026-08-02** (`docs/open-bugs.md` 1.1). The gap
/// was identical on both — six snapshots of the live Android config taken on
/// 2026-08-02 all showed `"address":"172.19.0.1/30"` and nothing else — and
/// nothing about the reasoning was iOS-specific. Two things travel with it:
/// [defaultTunMtu] rises to the v6 minimum of 1280 (an interface below it
/// cannot hold an inet6 address at all), and Android's native side needs no
/// change, because `VpnTunBuilderConfigurator` already reads `inet6Address`
/// out of libbox's `TunOptions` and adds `::/0` when one is present.
///
/// ⚠️ Not measured on a device. The leak was inferred from the config, not
/// reproduced — the emulator most likely has no IPv6 at all — so this closes
/// what the config says is open. Confirming it takes a phone on a carrier with
/// real IPv6 and `test-ipv6.com`; until then the honest claim is "the interface
/// now has an address for the family", not "the leak is gone".
String? get defaultTunInet6Address => switch (defaultTargetPlatform) {
  TargetPlatform.iOS || TargetPlatform.android => 'fdfe:dcba:9876::1/126',
  _ => null,
};

/// TUN stack used when the caller expresses no preference.
///
/// gvisor is a complete userspace TCP/IP stack in Go: a buffer set and a
/// goroutine per connection, with its own GC pressure. Inside an iOS network
/// extension capped at ~50 MB that is the largest thing running, and the
/// likeliest reason the tunnel is jetsam-killed under load — a browser or a
/// video stream opens connections by the hundred. `system` hands packets to the
/// kernel path instead: less memory, more throughput. Android keeps gvisor,
/// which is what its released build was tested on and where no such ceiling
/// applies.
SingboxTunImplementation get defaultTunImplementation =>
    defaultTargetPlatform == TargetPlatform.iOS
    ? SingboxTunImplementation.system
    : SingboxTunImplementation.gvisor;

/// SingboxIpv6RouteMode enum.
enum SingboxIpv6RouteMode { disable, prefer, only }

/// WarpDetourMode enum.
enum WarpDetourMode { detourProxiesThroughWarp, routeAllThroughWarp }

/// DnsProviderPreset enum.
enum DnsProviderPreset { custom, cloudflare, google, quad9, adguard }

/// DnsProviderProfile model.
class DnsProviderProfile {
  const DnsProviderProfile({required this.remoteDns, required this.directDns});

  /// Documented field.
  final String remoteDns;

  /// Documented field.
  final String directDns;
}

/// Returns default remote/direct DNS values for a provider preset.
DnsProviderProfile dnsProviderProfileForPreset(DnsProviderPreset preset) {
  switch (preset) {
    case DnsProviderPreset.custom:
      return const DnsProviderProfile(
        remoteDns: 'https://1.1.1.1/dns-query',
        directDns: 'local',
      );
    case DnsProviderPreset.cloudflare:
      return const DnsProviderProfile(
        remoteDns: 'https://1.1.1.1/dns-query',
        directDns: '1.1.1.1',
      );
    case DnsProviderPreset.google:
      return const DnsProviderProfile(
        remoteDns: 'https://dns.google/dns-query',
        directDns: '8.8.8.8',
      );
    case DnsProviderPreset.quad9:
      return const DnsProviderProfile(
        remoteDns: 'https://dns.quad9.net/dns-query',
        directDns: '9.9.9.9',
      );
    case DnsProviderPreset.adguard:
      return const DnsProviderProfile(
        remoteDns: 'https://dns.adguard-dns.com/dns-query',
        directDns: '94.140.14.14',
      );
  }
}

/// IntRange model.
class IntRange {
  const IntRange(this.min, this.max) : assert(min >= 0), assert(max >= min);

  /// Documented field.
  final int min;

  /// Documented field.
  final int max;

  /// Compact range string in `min-max` format.
  String get compact => '$min-$max';

  /// Serializes this object to a map.
  Map<String, Object?> toMap() {
    return <String, Object?>{'min': min, 'max': max};
  }

  /// Creates an instance from a dynamic map.
  factory IntRange.fromDynamic(dynamic raw, {required IntRange fallback}) {
    if (raw is Map<Object?, Object?>) {
      final int? min = _readInt(raw['min']);
      final int? max = _readInt(raw['max']);
      if (min != null && max != null && min >= 0 && max >= min) {
        return IntRange(min, max);
      }
      return fallback;
    }

    if (raw is String) {
      final List<String> parts = raw.split('-');
      if (parts.length == 2) {
        final int? min = int.tryParse(parts[0].trim());
        final int? max = int.tryParse(parts[1].trim());
        if (min != null && max != null && min >= 0 && max >= min) {
          return IntRange(min, max);
        }
      }
    }

    return fallback;
  }
}

/// AdvancedOptions model.
class AdvancedOptions {
  const AdvancedOptions({
    this.memoryLimit = false,
    this.debugMode = false,
    this.logLevel,
  });

  /// Documented field.
  final bool memoryLimit;

  /// Documented field.
  final bool debugMode;

  /// Documented field.
  final String? logLevel;

  /// Serializes this object to a map.
  Map<String, Object?> toMap() {
    return <String, Object?>{
      'memoryLimit': memoryLimit,
      'debugMode': debugMode,
      'logLevel': logLevel,
    };
  }

  /// Creates an instance from a dynamic map.
  factory AdvancedOptions.fromMap(dynamic raw) {
    if (raw is! Map<Object?, Object?>) {
      return const AdvancedOptions();
    }

    return AdvancedOptions(
      memoryLimit: _readBool(raw['memoryLimit'], false),
      debugMode: _readBool(raw['debugMode'], false),
      logLevel: _readNullableString(raw['logLevel']),
    );
  }
}

/// RouteOptions model.
class RouteOptions {
  const RouteOptions({
    this.region = 'other',
    this.blockAdvertisements = false,
    this.bypassLan = false,
    this.resolveDestination = false,
    this.blockQuicOnTcpProfiles = false,
    this.ipv6RouteMode = SingboxIpv6RouteMode.disable,
    this.regionDirectDomains = const <String>[],
    this.regionDirectCidrs = const <String>[],
    this.regionProxyDomains = const <String>[],
    this.regionProxyCidrs = const <String>[],
    this.extraBlockedKeywords = const <String>[],
    this.blockedDomainSuffixes = const <String>[],
    this.ruleSets = const <SingboxRuleSet>[],
  });

  /// Documented field.
  final String region;

  /// Documented field.
  final bool blockAdvertisements;

  /// Documented field.
  final bool bypassLan;

  /// Documented field.
  final bool resolveDestination;

  /// When enabled, block QUIC/UDP:443 for non-UDP-native proxy transports.
  final bool blockQuicOnTcpProfiles;

  /// Documented field.
  final SingboxIpv6RouteMode ipv6RouteMode;

  /// Documented field.
  final List<String> regionDirectDomains;

  /// Documented field.
  final List<String> regionDirectCidrs;

  /// Domain suffixes that go *through* the proxy while everything else goes
  /// direct — the inverse of [regionDirectDomains].
  ///
  /// Naming either of these lists is what picks the routing model, so the two
  /// are meant to be used one at a time; see [tunnelsOnlyListedHosts].
  final List<String> regionProxyDomains;

  /// IP/CIDR ranges that go *through* the proxy while everything else goes
  /// direct — the inverse of [regionDirectCidrs]. See [regionProxyDomains].
  final List<String> regionProxyCidrs;

  /// True when the config should tunnel only what [regionProxyDomains] and
  /// [regionProxyCidrs] name, sending all other traffic straight out.
  ///
  /// Deliberately derived from the lists rather than carried as its own flag:
  /// a standalone switch would allow "whitelist on, nothing whitelisted",
  /// which routes every last packet around the tunnel while the UI still says
  /// the VPN is connected. With no separate flag that state cannot be
  /// expressed — an empty whitelist simply leaves the full tunnel in place.
  bool get tunnelsOnlyListedHosts =>
      regionProxyDomains.isNotEmpty || regionProxyCidrs.isNotEmpty;

  /// Documented field.
  final List<String> extraBlockedKeywords;

  /// Domain suffixes dropped outright while [blockAdvertisements] is on — the
  /// ad/tracker list.
  ///
  /// Suffixes rather than the `domain_keyword` matching next door, and that is
  /// not a style choice: `domain_keyword` is a plain substring test, so the
  /// obvious keyword `ads` also matches `downloads.example.com`. A suffix can
  /// only ever over-match a domain that genuinely ends in the listed one.
  final List<String> blockedDomainSuffixes;

  /// Custom rule-sets for modern routing (v1.8+).
  final List<SingboxRuleSet> ruleSets;

  /// Serializes this object to a map.
  Map<String, Object?> toMap() {
    return <String, Object?>{
      'region': region,
      'blockAdvertisements': blockAdvertisements,
      'bypassLan': bypassLan,
      'resolveDestination': resolveDestination,
      'blockQuicOnTcpProfiles': blockQuicOnTcpProfiles,
      'ipv6RouteMode': ipv6RouteMode.name,
      'regionDirectDomains': regionDirectDomains,
      'regionDirectCidrs': regionDirectCidrs,
      'regionProxyDomains': regionProxyDomains,
      'regionProxyCidrs': regionProxyCidrs,
      'extraBlockedKeywords': extraBlockedKeywords,
      'blockedDomainSuffixes': blockedDomainSuffixes,
      'ruleSets': ruleSets.map((SingboxRuleSet e) => e.toMap()).toList(),
    };
  }

  /// Creates an instance from a dynamic map.
  factory RouteOptions.fromMap(dynamic raw) {
    if (raw is! Map<Object?, Object?>) {
      return const RouteOptions();
    }

    return RouteOptions(
      region: _readString(raw['region'], 'other'),
      blockAdvertisements: _readBool(raw['blockAdvertisements'], false),
      bypassLan: _readBool(raw['bypassLan'], false),
      resolveDestination: _readBool(raw['resolveDestination'], false),
      blockQuicOnTcpProfiles: _readBool(raw['blockQuicOnTcpProfiles'], false),
      ipv6RouteMode: _readEnum(
        raw['ipv6RouteMode'],
        SingboxIpv6RouteMode.values,
        SingboxIpv6RouteMode.disable,
      ),
      regionDirectDomains: _readStringList(raw['regionDirectDomains']),
      regionDirectCidrs: _readStringList(raw['regionDirectCidrs']),
      regionProxyDomains: _readStringList(raw['regionProxyDomains']),
      regionProxyCidrs: _readStringList(raw['regionProxyCidrs']),
      extraBlockedKeywords: _readStringList(raw['extraBlockedKeywords']),
      blockedDomainSuffixes: _readStringList(raw['blockedDomainSuffixes']),
      ruleSets: (raw['ruleSets'] as List<dynamic>?)
              ?.map(
                (dynamic e) =>
                    SingboxRuleSet.fromMap(e as Map<String, Object?>),
              )
              .toList() ??
          const <SingboxRuleSet>[],
    );
  }
}

/// DnsOptions model.
class DnsOptions {
  const DnsOptions({
    this.providerPreset = DnsProviderPreset.custom,
    this.remoteDns = 'https://1.1.1.1/dns-query',
    this.remoteDomainStrategy = 'auto',
    this.directDns = 'local',
    this.directDomainStrategy = 'auto',
    this.enableDnsRouting = true,
    this.enableFakeIp = false,
    this.fakeIpInet4Range = '198.18.0.0/15',
    this.fakeIpInet6Range = 'fc00::/18',
    this.enableDohFallback = true,
    this.dohFallbackDns = 'https://dns.google/dns-query',
    this.dohFallbackDomainSuffixes = const <String>[
      'cp.cloudflare.com',
      'connectivitycheck.gstatic.com',
      'gstatic.com',
      'googleapis.com',
    ],
    this.timeout,
  });

  /// Documented field.
  final DnsProviderPreset providerPreset;

  /// Documented field.
  final String remoteDns;

  /// Documented field.
  final String remoteDomainStrategy;

  /// Documented field.
  final String directDns;

  /// Documented field.
  final String directDomainStrategy;

  /// Documented field.
  final bool enableDnsRouting;

  /// Documented field.
  final bool enableFakeIp;

  /// Documented field.
  final String fakeIpInet4Range;

  /// Documented field.
  final String fakeIpInet6Range;

  /// Documented field.
  final bool enableDohFallback;

  /// Documented field.
  final String dohFallbackDns;

  /// Documented field.
  final List<String> dohFallbackDomainSuffixes;

  /// DNS query timeout (v1.14+).
  final Duration? timeout;

  /// Creates an instance from a dynamic map.
  factory DnsOptions.fromProvider({
    required DnsProviderPreset preset,
    String remoteDomainStrategy = 'auto',
    String directDomainStrategy = 'auto',
    bool enableDnsRouting = true,
    bool enableFakeIp = false,
    String fakeIpInet4Range = '198.18.0.0/15',
    String fakeIpInet6Range = 'fc00::/18',
    bool enableDohFallback = true,
    String dohFallbackDns = 'https://dns.google/dns-query',
    List<String> dohFallbackDomainSuffixes = const <String>[
      'cp.cloudflare.com',
      'connectivitycheck.gstatic.com',
      'gstatic.com',
      'googleapis.com',
    ],
    String? remoteDnsOverride,
    String? directDnsOverride,
  }) {
    final DnsProviderProfile profile = dnsProviderProfileForPreset(preset);
    return DnsOptions(
      providerPreset: preset,
      remoteDns: remoteDnsOverride ?? profile.remoteDns,
      remoteDomainStrategy: remoteDomainStrategy,
      directDns: directDnsOverride ?? profile.directDns,
      directDomainStrategy: directDomainStrategy,
      enableDnsRouting: enableDnsRouting,
      enableFakeIp: enableFakeIp,
      fakeIpInet4Range: fakeIpInet4Range,
      fakeIpInet6Range: fakeIpInet6Range,
      enableDohFallback: enableDohFallback,
      dohFallbackDns: dohFallbackDns,
      dohFallbackDomainSuffixes: dohFallbackDomainSuffixes,
      timeout: null,
    );
  }

  /// Serializes this object to a map.
  Map<String, Object?> toMap() {
    return <String, Object?>{
      'providerPreset': providerPreset.name,
      'remoteDns': remoteDns,
      'remoteDomainStrategy': remoteDomainStrategy,
      'directDns': directDns,
      'directDomainStrategy': directDomainStrategy,
      'enableDnsRouting': enableDnsRouting,
      'enableFakeIp': enableFakeIp,
      'fakeIpInet4Range': fakeIpInet4Range,
      'fakeIpInet6Range': fakeIpInet6Range,
      'enableDohFallback': enableDohFallback,
      'dohFallbackDns': dohFallbackDns,
      'dohFallbackDomainSuffixes': dohFallbackDomainSuffixes,
      'timeoutSeconds': timeout?.inSeconds,
    };
  }

  /// Creates an instance from a dynamic map.
  factory DnsOptions.fromMap(dynamic raw) {
    if (raw is! Map<Object?, Object?>) {
      return const DnsOptions();
    }

    return DnsOptions(
      providerPreset: _readEnum(
        raw['providerPreset'],
        DnsProviderPreset.values,
        DnsProviderPreset.custom,
      ),
      remoteDns: _readString(raw['remoteDns'], 'https://1.1.1.1/dns-query'),
      remoteDomainStrategy: _readString(raw['remoteDomainStrategy'], 'auto'),
      directDns: _readString(raw['directDns'], 'local'),
      directDomainStrategy: _readString(raw['directDomainStrategy'], 'auto'),
      enableDnsRouting: _readBool(raw['enableDnsRouting'], true),
      enableFakeIp: _readBool(raw['enableFakeIp'], false),
      fakeIpInet4Range: _readString(raw['fakeIpInet4Range'], '198.18.0.0/15'),
      fakeIpInet6Range: _readString(raw['fakeIpInet6Range'], 'fc00::/18'),
      enableDohFallback: _readBool(raw['enableDohFallback'], true),
      dohFallbackDns: _readString(
        raw['dohFallbackDns'],
        'https://dns.google/dns-query',
      ),
      dohFallbackDomainSuffixes:
          _readStringList(raw['dohFallbackDomainSuffixes']).isEmpty
          ? const <String>[
              'cp.cloudflare.com',
              'connectivitycheck.gstatic.com',
              'gstatic.com',
              'googleapis.com',
            ]
          : _readStringList(raw['dohFallbackDomainSuffixes']),
      timeout: raw.containsKey('timeoutSeconds')
          ? Duration(seconds: _readInt(raw['timeoutSeconds']) ?? 10)
          : null,
    );
  }
}

/// InboundOptions model.
class InboundOptions {
  const InboundOptions({
    this.serviceMode = SingboxServiceMode.vpn,
    this.strictRoute = true,
    this.tunImplementation = SingboxTunImplementation.gvisor,
    this.mtu,
    this.mixedPort,
    this.transparentProxyPort,
    this.localDnsPort,
    this.shareVpnInLocalNetwork = false,
    this.splitTunnelingEnabled,
    this.includePackages = const <String>[],
    this.excludePackages = const <String>[],
  }) : assert(mtu == null || (mtu >= 576 && mtu <= 9000)),
       assert(mixedPort == null || (mixedPort > 0 && mixedPort <= 65535)),
       assert(
         transparentProxyPort == null ||
             (transparentProxyPort > 0 && transparentProxyPort <= 65535),
       ),
       assert(
         localDnsPort == null || (localDnsPort > 0 && localDnsPort <= 65535),
       );

  /// Documented field.
  final SingboxServiceMode serviceMode;

  /// Documented field.
  final bool strictRoute;

  /// Documented field.
  final SingboxTunImplementation tunImplementation;

  /// TUN MTU, or null to take the platform default.
  ///
  /// Deliberately overridable rather than fixed: the safe value differs by
  /// platform (see `SingboxInboundBuilder.defaultMtu`) and by transport — a
  /// WireGuard outbound pays its own header overhead on top of whatever is set
  /// here, so a value that is right for VLESS-over-TCP is not right for it.
  final int? mtu;

  /// Documented field.
  final int? mixedPort;

  /// Documented field.
  final int? transparentProxyPort;

  /// Documented field.
  final int? localDnsPort;

  /// Documented field.
  final bool shareVpnInLocalNetwork;

  /// Documented field.
  final bool? splitTunnelingEnabled;

  /// Documented field.
  final List<String> includePackages;

  /// Documented field.
  final List<String> excludePackages;

  /// Serializes this object to a map.
  Map<String, Object?> toMap() {
    return <String, Object?>{
      'serviceMode': serviceMode.name,
      'strictRoute': strictRoute,
      'tunImplementation': tunImplementation.name,
      'mtu': mtu,
      'mixedPort': mixedPort,
      'transparentProxyPort': transparentProxyPort,
      'localDnsPort': localDnsPort,
      'shareVpnInLocalNetwork': shareVpnInLocalNetwork,
      'splitTunnelingEnabled': splitTunnelingEnabled,
      'includePackages': includePackages,
      'excludePackages': excludePackages,
    };
  }

  /// Creates an instance from a dynamic map.
  factory InboundOptions.fromMap(dynamic raw) {
    if (raw is! Map<Object?, Object?>) {
      return const InboundOptions();
    }

    final List<String> includePackages = _readStringList(
      raw['includePackages'],
    );
    final List<String> excludePackages = _readStringList(
      raw['excludePackages'],
    );
    final bool? splitTunnelingEnabled = raw.containsKey('splitTunnelingEnabled')
        ? _readNullableBool(raw['splitTunnelingEnabled'])
        : null;

    return InboundOptions(
      serviceMode: _readEnum(
        raw['serviceMode'],
        SingboxServiceMode.values,
        SingboxServiceMode.vpn,
      ),
      strictRoute: _readBool(raw['strictRoute'], true),
      tunImplementation: _readEnum(
        raw['tunImplementation'],
        SingboxTunImplementation.values,
        SingboxTunImplementation.gvisor,
      ),
      mtu: _readInt(raw['mtu']),
      mixedPort: _readInt(raw['mixedPort']),
      transparentProxyPort: _readInt(raw['transparentProxyPort']),
      localDnsPort: _readInt(raw['localDnsPort']),
      shareVpnInLocalNetwork: _readBool(raw['shareVpnInLocalNetwork'], false),
      splitTunnelingEnabled: splitTunnelingEnabled,
      includePackages: includePackages,
      excludePackages: excludePackages,
    );
  }
}

/// TlsTricksOptions model.
class TlsTricksOptions {
  const TlsTricksOptions({
    this.enableTlsFragment = false,
    this.tlsFragmentSize = const IntRange(10, 30),
    this.tlsFragmentSleep = const IntRange(2, 8),
    this.enableTlsMixedSniCase = false,
    this.enableTlsPadding = false,
    this.tlsPadding = const IntRange(1, 1500),
    this.rawOutboundPatch = const <String, Object?>{},
  });

  /// Documented field.
  final bool enableTlsFragment;

  /// Documented field.
  final IntRange tlsFragmentSize;

  /// Documented field.
  final IntRange tlsFragmentSleep;

  /// Documented field.
  final bool enableTlsMixedSniCase;

  /// Documented field.
  final bool enableTlsPadding;

  /// Documented field.
  final IntRange tlsPadding;

  /// Documented field.
  final Map<String, Object?> rawOutboundPatch;

  /// Serializes this object to a map.
  Map<String, Object?> toMap() {
    return <String, Object?>{
      'enableTlsFragment': enableTlsFragment,
      'tlsFragmentSize': tlsFragmentSize.toMap(),
      'tlsFragmentSleep': tlsFragmentSleep.toMap(),
      'enableTlsMixedSniCase': enableTlsMixedSniCase,
      'enableTlsPadding': enableTlsPadding,
      'tlsPadding': tlsPadding.toMap(),
      'rawOutboundPatch': rawOutboundPatch,
    };
  }

  /// Creates an instance from a dynamic map.
  factory TlsTricksOptions.fromMap(dynamic raw) {
    if (raw is! Map<Object?, Object?>) {
      return const TlsTricksOptions();
    }

    return TlsTricksOptions(
      enableTlsFragment: _readBool(raw['enableTlsFragment'], false),
      tlsFragmentSize: IntRange.fromDynamic(
        raw['tlsFragmentSize'],
        fallback: const IntRange(10, 30),
      ),
      tlsFragmentSleep: IntRange.fromDynamic(
        raw['tlsFragmentSleep'],
        fallback: const IntRange(2, 8),
      ),
      enableTlsMixedSniCase: _readBool(raw['enableTlsMixedSniCase'], false),
      enableTlsPadding: _readBool(raw['enableTlsPadding'], false),
      tlsPadding: IntRange.fromDynamic(
        raw['tlsPadding'],
        fallback: const IntRange(1, 1500),
      ),
      rawOutboundPatch: _readObjectMap(raw['rawOutboundPatch']),
    );
  }
}

/// WarpOptions model.
class WarpOptions {
  const WarpOptions({
    this.enableWarp = false,
    this.detourMode = WarpDetourMode.detourProxiesThroughWarp,
    this.licenseKey,
    this.cleanIp = 'auto',
    this.port = 0,
    this.noiseCount = const IntRange(1, 3),
    this.noiseMode = 'm4',
    this.noiseSize = const IntRange(10, 30),
    this.noiseDelay = const IntRange(10, 30),
    this.outboundTemplate = const <String, Object?>{},
  }) : assert(port >= 0 && port <= 65535);

  /// Documented field.
  final bool enableWarp;

  /// Documented field.
  final WarpDetourMode detourMode;

  /// Documented field.
  final String? licenseKey;

  /// Documented field.
  final String cleanIp;

  /// Documented field.
  final int port;

  /// Documented field.
  final IntRange noiseCount;

  /// Documented field.
  final String noiseMode;

  /// Documented field.
  final IntRange noiseSize;

  /// Documented field.
  final IntRange noiseDelay;

  /// Documented field.
  final Map<String, Object?> outboundTemplate;

  /// Serializes this object to a map.
  Map<String, Object?> toMap() {
    return <String, Object?>{
      'enableWarp': enableWarp,
      'detourMode': detourMode.name,
      'licenseKey': licenseKey,
      'cleanIp': cleanIp,
      'port': port,
      'noiseCount': noiseCount.toMap(),
      'noiseMode': noiseMode,
      'noiseSize': noiseSize.toMap(),
      'noiseDelay': noiseDelay.toMap(),
      'outboundTemplate': outboundTemplate,
    };
  }

  /// Creates an instance from a dynamic map.
  factory WarpOptions.fromMap(dynamic raw) {
    if (raw is! Map<Object?, Object?>) {
      return const WarpOptions();
    }

    return WarpOptions(
      enableWarp: _readBool(raw['enableWarp'], false),
      detourMode: _readEnum(
        raw['detourMode'],
        WarpDetourMode.values,
        WarpDetourMode.detourProxiesThroughWarp,
      ),
      licenseKey: _readNullableString(raw['licenseKey']),
      cleanIp: _readString(raw['cleanIp'], 'auto'),
      port: _readInt(raw['port']) ?? 0,
      noiseCount: IntRange.fromDynamic(
        raw['noiseCount'],
        fallback: const IntRange(1, 3),
      ),
      noiseMode: _readString(raw['noiseMode'], 'm4'),
      noiseSize: IntRange.fromDynamic(
        raw['noiseSize'],
        fallback: const IntRange(10, 30),
      ),
      noiseDelay: IntRange.fromDynamic(
        raw['noiseDelay'],
        fallback: const IntRange(10, 30),
      ),
      outboundTemplate: _readObjectMap(raw['outboundTemplate']),
    );
  }
}

/// MiscOptions model.
class MiscOptions {
  const MiscOptions({
    this.connectionTestUrl = 'http://cp.cloudflare.com',
    this.urlTestInterval = const Duration(minutes: 10),
    this.clashApiPort = 16756,
    this.clashApiSecret,
    this.useXrayCoreWhenPossible = false,
  }) : assert(
         clashApiPort == null || (clashApiPort > 0 && clashApiPort <= 65535),
       );

  /// Documented field.
  final String connectionTestUrl;

  /// Documented field.
  final Duration urlTestInterval;

  /// Documented field.
  final int? clashApiPort;

  /// Bearer token the control API requires. Android's loopback is shared by
  /// every installed app, so without one any app holding `INTERNET` can read
  /// the user's live connection list off `127.0.0.1:$clashApiPort` and switch
  /// routing off. Callers should hand in a fresh random value per tunnel start.
  final String? clashApiSecret;

  /// Documented field.
  final bool useXrayCoreWhenPossible;

  /// Serializes this object to a map.
  Map<String, Object?> toMap() {
    return <String, Object?>{
      'connectionTestUrl': connectionTestUrl,
      'urlTestIntervalSeconds': urlTestInterval.inSeconds,
      'clashApiPort': clashApiPort,
      'clashApiSecret': clashApiSecret,
      'useXrayCoreWhenPossible': useXrayCoreWhenPossible,
    };
  }

  /// Creates an instance from a dynamic map.
  factory MiscOptions.fromMap(dynamic raw) {
    if (raw is! Map<Object?, Object?>) {
      return const MiscOptions();
    }

    return MiscOptions(
      connectionTestUrl: _readString(
        raw['connectionTestUrl'],
        'http://cp.cloudflare.com',
      ),
      urlTestInterval: Duration(
        seconds: _readInt(raw['urlTestIntervalSeconds']) ?? 600,
      ),
      clashApiPort: _readInt(raw['clashApiPort']) ?? 16756,
      clashApiSecret: _readNullableString(raw['clashApiSecret']),
      useXrayCoreWhenPossible: _readBool(raw['useXrayCoreWhenPossible'], false),
    );
  }
}

/// SingboxFeatureSettings model.
class SingboxFeatureSettings {
  const SingboxFeatureSettings({
    this.advanced = const AdvancedOptions(),
    this.route = const RouteOptions(),
    this.dns = const DnsOptions(),
    this.inbound = const InboundOptions(),
    this.tlsTricks = const TlsTricksOptions(),
    this.warp = const WarpOptions(),
    this.misc = const MiscOptions(),
    this.rawConfigPatch = const <String, Object?>{},
  });

  /// Documented field.
  final AdvancedOptions advanced;

  /// Documented field.
  final RouteOptions route;

  /// Documented field.
  final DnsOptions dns;

  /// Documented field.
  final InboundOptions inbound;

  /// Documented field.
  final TlsTricksOptions tlsTricks;

  /// Documented field.
  final WarpOptions warp;

  /// Documented field.
  final MiscOptions misc;

  /// Documented field.
  final Map<String, Object?> rawConfigPatch;

  /// Serializes this object to a map.
  Map<String, Object?> toMap() {
    return <String, Object?>{
      'advanced': advanced.toMap(),
      'route': route.toMap(),
      'dns': dns.toMap(),
      'inbound': inbound.toMap(),
      'tlsTricks': tlsTricks.toMap(),
      'warp': warp.toMap(),
      'misc': misc.toMap(),
      'rawConfigPatch': rawConfigPatch,
    };
  }

  /// Creates an instance from a dynamic map.
  factory SingboxFeatureSettings.fromMap(dynamic raw) {
    if (raw is! Map<Object?, Object?>) {
      return const SingboxFeatureSettings();
    }

    return SingboxFeatureSettings(
      advanced: AdvancedOptions.fromMap(raw['advanced']),
      route: RouteOptions.fromMap(raw['route']),
      dns: DnsOptions.fromMap(raw['dns']),
      inbound: InboundOptions.fromMap(raw['inbound']),
      tlsTricks: TlsTricksOptions.fromMap(raw['tlsTricks']),
      warp: WarpOptions.fromMap(raw['warp']),
      misc: MiscOptions.fromMap(raw['misc']),
      rawConfigPatch: _readObjectMap(raw['rawConfigPatch']),
    );
  }
}

bool _readBool(dynamic raw, bool fallback) {
  if (raw is bool) {
    return raw;
  }
  return fallback;
}

bool? _readNullableBool(dynamic raw) {
  if (raw is bool) {
    return raw;
  }
  return null;
}

int? _readInt(dynamic raw) {
  if (raw is int) {
    return raw;
  }
  if (raw is num) {
    return raw.toInt();
  }
  if (raw is String) {
    return int.tryParse(raw);
  }
  return null;
}

String _readString(dynamic raw, String fallback) {
  if (raw is String && raw.isNotEmpty) {
    return raw;
  }
  return fallback;
}

String? _readNullableString(dynamic raw) {
  if (raw is String && raw.isNotEmpty) {
    return raw;
  }
  return null;
}

List<String> _readStringList(dynamic raw) {
  if (raw is! List) {
    return const <String>[];
  }
  return raw
      .whereType<String>()
      .where((String item) => item.isNotEmpty)
      .toList();
}

Map<String, Object?> _readObjectMap(dynamic raw) {
  if (raw is! Map<Object?, Object?>) {
    return const <String, Object?>{};
  }

  final Map<String, Object?> output = <String, Object?>{};
  raw.forEach((Object? key, Object? value) {
    if (key is String) {
      output[key] = value;
    }
  });
  return output;
}

T _readEnum<T extends Enum>(dynamic raw, List<T> values, T fallback) {
  if (raw is String) {
    for (final T value in values) {
      if (value.name == raw) {
        return value;
      }
    }
  }
  return fallback;
}
