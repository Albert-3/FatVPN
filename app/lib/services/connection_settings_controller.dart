import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:singbox_mm/singbox_mm.dart';

/// Persists the user's connection preferences (DNS provider, network stack)
/// and turns them into a [SingboxFeatureSettings] that [VpnController] applies
/// on the next connect. Mirrors [LocaleController]'s secure-storage pattern.
///
/// Defaults are chosen to match the tunnel behaviour already verified on
/// device: the app used to call `connectManualConfigLink` without any
/// `featureSettings`, so the plugin's own defaults applied — a Cloudflare-like
/// DNS and the gVisor tun stack. We keep those as the starting point so
/// wiring these settings in doesn't silently change how the tunnel behaves.
class ConnectionSettingsController extends ChangeNotifier {
  static const _dnsKey = 'conn_dns_preset';
  static const _customDnsKey = 'conn_dns_custom';
  static const _stackKey = 'conn_network_stack';
  static const _splitEnabledKey = 'conn_split_enabled';
  static const _splitPackagesKey = 'conn_split_packages';
  static const _splitHostsKey = 'conn_split_hosts';
  final _storage = const FlutterSecureStorage();

  DnsProviderPreset _dnsPreset = DnsProviderPreset.cloudflare;
  String _customDns = '';
  SingboxTunImplementation _networkStack = SingboxTunImplementation.gvisor;

  // Split tunneling: when enabled, apps in [_bypassPackages] skip the VPN
  // (mapped to sing-box `exclude_package`). Empty set = nothing bypasses.
  // Per-app bypass only works on Android — iOS has no per-app VPN for non-MDM
  // apps, so there we bypass by host instead (see [_bypassHosts]).
  bool _splitTunnelEnabled = false;
  Set<String> _bypassPackages = <String>{};

  // Host-based split tunneling (used on iOS, where per-app is impossible):
  // raw domain/IP entries the user typed. Each is classified at connect time
  // into a sing-box `domain_suffix` or `ip_cidr` `direct` route rule. Kept as
  // an ordered list so the picker list stays stable.
  List<String> _bypassHosts = <String>[];

  DnsProviderPreset get dnsPreset => _dnsPreset;

  /// User-entered resolver used when [dnsPreset] is [DnsProviderPreset.custom]
  /// (e.g. `https://1.1.1.1/dns-query`, `tls://8.8.8.8`, or a plain IP).
  String get customDns => _customDns;
  SingboxTunImplementation get networkStack => _networkStack;
  bool get splitTunnelEnabled => _splitTunnelEnabled;
  Set<String> get bypassPackages => _bypassPackages;

  /// Raw domain/IP entries that bypass the VPN (host-based split tunneling,
  /// surfaced on iOS). Order preserved for a stable list UI.
  List<String> get bypassHosts => List<String>.unmodifiable(_bypassHosts);

  /// DNS presets surfaced in the UI. `custom` lets the user type their own
  /// resolver (see [customDns]).
  static const dnsPresets = <DnsProviderPreset>[
    DnsProviderPreset.cloudflare,
    DnsProviderPreset.google,
    DnsProviderPreset.quad9,
    DnsProviderPreset.adguard,
    DnsProviderPreset.custom,
  ];

  /// "Mixed" (system stack) and gVisor are the only tun implementations the
  /// plugin exposes; "Mixed" in the mockup maps to the native `system` stack.
  static const networkStacks = <SingboxTunImplementation>[
    SingboxTunImplementation.system,
    SingboxTunImplementation.gvisor,
  ];

  Future<void> load() async {
    final dns = await _storage.read(key: _dnsKey);
    final customDns = await _storage.read(key: _customDnsKey);
    final stack = await _storage.read(key: _stackKey);
    final splitEnabled = await _storage.read(key: _splitEnabledKey);
    final splitPackages = await _storage.read(key: _splitPackagesKey);
    final splitHosts = await _storage.read(key: _splitHostsKey);
    var changed = false;
    if (dns != null) {
      final match = DnsProviderPreset.values.where((p) => p.name == dns);
      if (match.isNotEmpty) {
        _dnsPreset = match.first;
        changed = true;
      }
    }
    if (customDns != null && customDns.isNotEmpty) {
      _customDns = customDns;
      changed = true;
    }
    if (stack != null) {
      final match =
          SingboxTunImplementation.values.where((s) => s.name == stack);
      if (match.isNotEmpty) {
        _networkStack = match.first;
        changed = true;
      }
    }
    if (splitEnabled == 'true') {
      _splitTunnelEnabled = true;
      changed = true;
    }
    if (splitPackages != null && splitPackages.isNotEmpty) {
      _bypassPackages = splitPackages.split(',').where((p) => p.isNotEmpty).toSet();
      changed = true;
    }
    if (splitHosts != null && splitHosts.isNotEmpty) {
      _bypassHosts =
          splitHosts.split(',').where((h) => h.isNotEmpty).toList();
      changed = true;
    }
    if (changed) notifyListeners();
  }

  Future<void> setDnsPreset(DnsProviderPreset preset) async {
    if (_dnsPreset == preset) return;
    _dnsPreset = preset;
    notifyListeners();
    await _storage.write(key: _dnsKey, value: preset.name);
  }

  Future<void> setCustomDns(String value) async {
    final v = value.trim();
    if (_customDns == v) return;
    _customDns = v;
    notifyListeners();
    await _storage.write(key: _customDnsKey, value: v);
  }

  Future<void> setNetworkStack(SingboxTunImplementation stack) async {
    if (_networkStack == stack) return;
    _networkStack = stack;
    notifyListeners();
    await _storage.write(key: _stackKey, value: stack.name);
  }

  Future<void> setSplitTunnelEnabled(bool enabled) async {
    if (_splitTunnelEnabled == enabled) return;
    _splitTunnelEnabled = enabled;
    notifyListeners();
    await _storage.write(key: _splitEnabledKey, value: enabled.toString());
  }

  Future<void> setBypassPackages(Set<String> packages) async {
    _bypassPackages = packages;
    notifyListeners();
    await _storage.write(key: _splitPackagesKey, value: packages.join(','));
  }

  /// Adds a raw domain/IP entry to the host-based bypass list. Returns `false`
  /// if the entry is invalid or already present (no state change in that case).
  Future<bool> addBypassHost(String raw) async {
    final host = raw.trim();
    if (!isValidBypassHost(host)) return false;
    if (_bypassHosts.any((h) => h.toLowerCase() == host.toLowerCase())) {
      return false;
    }
    _bypassHosts = <String>[..._bypassHosts, host];
    notifyListeners();
    await _storage.write(key: _splitHostsKey, value: _bypassHosts.join(','));
    return true;
  }

  Future<void> removeBypassHost(String host) async {
    final next =
        _bypassHosts.where((h) => h != host).toList(growable: false);
    if (next.length == _bypassHosts.length) return;
    _bypassHosts = next;
    notifyListeners();
    await _storage.write(key: _splitHostsKey, value: _bypassHosts.join(','));
  }

  /// A bypass host is valid when it is a domain (`example.com`, `*.ru`) or an
  /// IP / CIDR (`8.8.8.8`, `10.0.0.0/8`). Used by the UI to gate the add field.
  static bool isValidBypassHost(String raw) {
    final host = raw.trim();
    if (host.isEmpty) return false;
    return _asCidr(host) != null || _asDomainSuffix(host) != null;
  }

  /// Built fresh at each connect so preference edits take effect on reconnect.
  SingboxFeatureSettings buildFeatureSettings() {
    // Per-app bypass (Android): on only when at least one app is picked;
    // an empty include/exclude list would otherwise be a no-op anyway.
    final splitApps = _splitTunnelEnabled && _bypassPackages.isNotEmpty;

    // Host bypass (iOS + also honoured on Android): classify each raw entry
    // into a `direct` domain-suffix or ip-cidr route rule. These are platform
    // independent (pure packet routing inside the TUN), so they take effect on
    // iOS where per-app split tunneling is impossible.
    final directDomains = <String>[];
    final directCidrs = <String>[];
    if (_splitTunnelEnabled) {
      for (final raw in _bypassHosts) {
        final cidr = _asCidr(raw);
        if (cidr != null) {
          directCidrs.add(cidr);
          continue;
        }
        final domain = _asDomainSuffix(raw);
        if (domain != null) directDomains.add(domain);
      }
    }

    final useCustomDns =
        _dnsPreset == DnsProviderPreset.custom && _customDns.trim().isNotEmpty;
    return SingboxFeatureSettings(
      route: RouteOptions(
        regionDirectDomains: directDomains,
        regionDirectCidrs: directCidrs,
        // Domain-suffix route rules only match once sing-box knows the
        // connection's domain, which requires sniffing (SNI/host). Enable it
        // only when there are domain bypass rules — IP/CIDR rules match on the
        // destination address alone and need no sniffing.
        resolveDestination: directDomains.isNotEmpty,
      ),
      dns: DnsOptions.fromProvider(
        preset: _dnsPreset,
        remoteDnsOverride: useCustomDns ? _customDns.trim() : null,
      ),
      inbound: InboundOptions(
        tunImplementation: _networkStack,
        splitTunnelingEnabled: splitApps,
        excludePackages: splitApps ? _bypassPackages.toList() : const <String>[],
      ),
    );
  }

  /// Normalizes an IP or CIDR entry to sing-box `ip_cidr` form (bare IPs get a
  /// `/32` or `/128` mask). Returns `null` if [host] isn't an IP/CIDR.
  static String? _asCidr(String host) {
    final trimmed = host.trim();
    final slash = trimmed.indexOf('/');
    if (slash >= 0) {
      final ip = InternetAddress.tryParse(trimmed.substring(0, slash));
      final mask = int.tryParse(trimmed.substring(slash + 1));
      if (ip == null || mask == null) return null;
      final max = ip.type == InternetAddressType.IPv6 ? 128 : 32;
      if (mask < 0 || mask > max) return null;
      return '${ip.address}/$mask';
    }
    final ip = InternetAddress.tryParse(trimmed);
    if (ip == null) return null;
    return ip.type == InternetAddressType.IPv6
        ? '${ip.address}/128'
        : '${ip.address}/32';
  }

  static final _domainRe = RegExp(
    r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)*$',
  );

  /// Normalizes a domain entry to a sing-box `domain_suffix` value: lowercases
  /// and strips a leading `*.` / `.` wildcard. Returns `null` if not a domain.
  static String? _asDomainSuffix(String host) {
    var h = host.trim().toLowerCase();
    if (h.startsWith('*.')) {
      h = h.substring(2);
    } else if (h.startsWith('.')) {
      h = h.substring(1);
    }
    if (h.isEmpty || !_domainRe.hasMatch(h)) return null;
    return h;
  }
}
