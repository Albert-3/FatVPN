import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:singbox_mm/singbox_mm.dart';

import 'secure_store.dart';

/// Which way round the split-tunnel lists are read.
enum SplitTunnelMode {
  /// Blacklist: the listed apps and hosts go *around* the VPN, everything else
  /// is tunnelled. The original behaviour, and still the default.
  exclude,

  /// Whitelist: *only* the listed apps and hosts are tunnelled, everything
  /// else leaves the device directly.
  include,
}

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
  static const _splitModeKey = 'conn_split_mode';
  static const _splitPackagesKey = 'conn_split_packages';
  static const _splitHostsKey = 'conn_split_hosts';
  // Whitelist entries live under their own keys. Sharing the lists across both
  // modes would mean a single tap on the mode switch silently inverted every
  // rule the user had saved — and the seeded defaults below make that concrete:
  // three entry domains meant to *skip* the VPN would become the only three
  // domains allowed *through* it.
  static const _splitTunnelPackagesKey = 'conn_split_tunnel_packages';
  static const _splitTunnelHostsKey = 'conn_split_tunnel_hosts';
  static const _splitSeededKey = 'conn_split_hosts_seeded'; // legacy: 'true' = batch 1
  static const _splitSeedVersionKey = 'conn_split_hosts_seed_version';
  final _storage = SecureStore();

  /// Domains every user gets in the host bypass list: the big Russian services
  /// (Yandex, Wildberries, Ozon) refuse to work — or bury the user in captchas
  /// — when the request arrives from a foreign VPN exit. Kept to the entry
  /// domains of each service; their static/image CDNs (`yastatic.net`,
  /// `wbbasket.ru`, `ozone.ru`, …) stay in the tunnel by product decision, so
  /// pictures may still load over the VPN.
  ///
  /// Grouped into versioned batches: on launch only batches newer than the
  /// stored seed version are added, so extending the defaults in a later
  /// release never resurrects entries the user deleted from an earlier batch.
  /// Append new batches — never edit a shipped one.
  ///
  /// Matched as sing-box `domain_suffix`, so `yandex.ru` also covers
  /// `mail.yandex.ru`.
  static const _seedBatches = <List<String>>[
    <String>['yandex.ru', 'wildberries.ru', 'ozon.ru'],
    <String>[
      // Yandex: short domain the search/mail entry points redirect to.
      'ya.ru',
      // Wildberries: catalogue/cart API (`card.wb.ru`, `search.wb.ru`).
      'wb.ru',
    ],
  ];

  /// Flattened view of [_seedBatches] — the full default bypass list.
  static List<String> get defaultBypassHosts =>
      <String>[for (final batch in _seedBatches) ...batch];

  DnsProviderPreset _dnsPreset = DnsProviderPreset.cloudflare;
  String _customDns = '';
  SingboxTunImplementation _networkStack = SingboxTunImplementation.gvisor;

  // Split tunneling: when enabled, apps in [_bypassPackages] skip the VPN
  // (mapped to sing-box `exclude_package`). Empty set = nothing bypasses.
  // Per-app bypass only works on Android — iOS has no per-app VPN for non-MDM
  // apps, so there we bypass by host instead (see [_bypassHosts]).
  bool _splitTunnelEnabled = false;
  SplitTunnelMode _splitTunnelMode = SplitTunnelMode.exclude;
  Set<String> _bypassPackages = <String>{};

  // Host-based split tunneling (used on iOS, where per-app is impossible):
  // raw domain/IP entries the user typed. Each is classified at connect time
  // into a sing-box `domain_suffix` or `ip_cidr` `direct` route rule. Kept as
  // an ordered list so the picker list stays stable.
  List<String> _bypassHosts = <String>[];

  // The whitelist counterparts of the two lists above, held separately so each
  // mode keeps its own rules (see [_splitTunnelPackagesKey]). Apps here map to
  // sing-box `include_package`; hosts become `regionProxyDomains`/`Cidrs`,
  // which flip the config's default route to `direct`.
  Set<String> _tunnelPackages = <String>{};
  List<String> _tunnelHosts = <String>[];

  DnsProviderPreset get dnsPreset => _dnsPreset;

  /// User-entered resolver used when [dnsPreset] is [DnsProviderPreset.custom]
  /// (e.g. `https://1.1.1.1/dns-query`, `tls://8.8.8.8`, or a plain IP).
  String get customDns => _customDns;
  SingboxTunImplementation get networkStack => _networkStack;
  bool get splitTunnelEnabled => _splitTunnelEnabled;

  /// Whether the lists name what skips the VPN or what is the only thing to
  /// use it. Each mode reads its own lists — see [activePackages].
  SplitTunnelMode get splitTunnelMode => _splitTunnelMode;
  Set<String> get bypassPackages => _bypassPackages;

  /// Raw domain/IP entries that bypass the VPN (host-based split tunneling,
  /// surfaced on iOS). Order preserved for a stable list UI.
  List<String> get bypassHosts => List<String>.unmodifiable(_bypassHosts);

  /// Apps that are the only ones allowed through the VPN, in
  /// [SplitTunnelMode.include].
  Set<String> get tunnelPackages => _tunnelPackages;

  /// Domain/IP entries that are the only ones routed through the VPN, in
  /// [SplitTunnelMode.include].
  List<String> get tunnelHosts => List<String>.unmodifiable(_tunnelHosts);

  /// The app list belonging to the current mode — what the picker shows and
  /// edits, so the UI never has to branch on the mode itself.
  Set<String> get activePackages => _splitTunnelMode == SplitTunnelMode.include
      ? _tunnelPackages
      : _bypassPackages;

  /// The host list belonging to the current mode. See [activePackages].
  List<String> get activeHosts => _splitTunnelMode == SplitTunnelMode.include
      ? tunnelHosts
      : bypassHosts;

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

  /// Restores the saved preferences. Read as one batch rather than a chain of
  /// awaits: eleven round trips through the platform channel, each decrypting
  /// with a Keystore key, is a quarter of a second of the launch spent waiting
  /// on nothing in particular.
  Future<void> load() async {
    final values = await Future.wait([
      _storage.read(key: _dnsKey),
      _storage.read(key: _customDnsKey),
      _storage.read(key: _stackKey),
      _storage.read(key: _splitEnabledKey),
      _storage.read(key: _splitModeKey),
      _storage.read(key: _splitPackagesKey),
      _storage.read(key: _splitHostsKey),
      _storage.read(key: _splitTunnelPackagesKey),
      _storage.read(key: _splitTunnelHostsKey),
      _storage.read(key: _splitSeededKey),
      _storage.read(key: _splitSeedVersionKey),
    ]);
    final dns = values[0];
    final customDns = values[1];
    final stack = values[2];
    final splitEnabled = values[3];
    final splitMode = values[4];
    final splitPackages = values[5];
    final splitHosts = values[6];
    final tunnelPackages = values[7];
    final tunnelHosts = values[8];
    final splitSeeded = values[9];
    final splitSeedVersion = values[10];
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
    if (splitMode != null) {
      final match = SplitTunnelMode.values.where((m) => m.name == splitMode);
      if (match.isNotEmpty) {
        _splitTunnelMode = match.first;
        changed = true;
      }
    }
    if (tunnelPackages != null && tunnelPackages.isNotEmpty) {
      _tunnelPackages =
          tunnelPackages.split(',').where((p) => p.isNotEmpty).toSet();
      changed = true;
    }
    if (tunnelHosts != null && tunnelHosts.isNotEmpty) {
      _tunnelHosts =
          tunnelHosts.split(',').where((h) => h.isNotEmpty).toList();
      changed = true;
    }
    // A build that predates the versioned key seeded batch 1 and wrote 'true'.
    final seededBatches =
        int.tryParse(splitSeedVersion ?? '') ?? (splitSeeded == 'true' ? 1 : 0);
    if (seededBatches < _seedBatches.length) {
      changed = await _seedDefaultBypassHosts(splitEnabled, seededBatches) ||
          changed;
    }
    if (changed) notifyListeners();
  }

  /// Adds the [_seedBatches] the user hasn't seen yet to the bypass list — on a
  /// fresh install that's all of them, on an upgrade only the new ones.
  /// Returns whether anything changed. [storedSplitEnabled] is the raw stored
  /// master-switch value (`null` = the user never touched the switch).
  Future<bool> _seedDefaultBypassHosts(
    String? storedSplitEnabled,
    int seededBatches,
  ) async {
    var changed = false;
    final seen = _bypassHosts.map((h) => h.trim().toLowerCase()).toSet();
    final missing = <String>[];
    for (var i = seededBatches; i < _seedBatches.length; i++) {
      for (final host in _seedBatches[i]) {
        if (seen.add(host)) missing.add(host);
      }
    }
    if (missing.isNotEmpty) {
      _bypassHosts = <String>[..._bypassHosts, ...missing];
      await _storage.write(key: _splitHostsKey, value: _bypassHosts.join(','));
      changed = true;
    }
    // The rules do nothing while the master switch is off, so turn it on — but
    // never override a user who deliberately switched split tunneling off.
    if (storedSplitEnabled == null && !_splitTunnelEnabled) {
      _splitTunnelEnabled = true;
      await _storage.write(key: _splitEnabledKey, value: 'true');
      changed = true;
    }
    await _storage.write(
      key: _splitSeedVersionKey,
      value: _seedBatches.length.toString(),
    );
    return changed;
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

  /// Switches which way the lists are read. The lists themselves are left
  /// alone: each mode has its own, so coming back to a mode finds the rules
  /// that were set up under it.
  Future<void> setSplitTunnelMode(SplitTunnelMode mode) async {
    if (_splitTunnelMode == mode) return;
    _splitTunnelMode = mode;
    notifyListeners();
    await _storage.write(key: _splitModeKey, value: mode.name);
  }

  Future<void> setBypassPackages(Set<String> packages) async {
    _bypassPackages = packages;
    notifyListeners();
    await _storage.write(key: _splitPackagesKey, value: packages.join(','));
  }

  Future<void> setTunnelPackages(Set<String> packages) async {
    _tunnelPackages = packages;
    notifyListeners();
    await _storage.write(
      key: _splitTunnelPackagesKey,
      value: packages.join(','),
    );
  }

  /// Replaces the app list of the current mode — what the picker writes back.
  Future<void> setActivePackages(Set<String> packages) =>
      _splitTunnelMode == SplitTunnelMode.include
          ? setTunnelPackages(packages)
          : setBypassPackages(packages);

  /// Adds a raw domain/IP entry to the host-based bypass list. Returns `false`
  /// if the entry is invalid or already present (no state change in that case).
  Future<bool> addBypassHost(String raw) => _addHost(raw, SplitTunnelMode.exclude);

  Future<void> removeBypassHost(String host) =>
      _removeHost(host, SplitTunnelMode.exclude);

  /// Adds a raw domain/IP entry to the host list of the current mode. See
  /// [addBypassHost] for the return value.
  Future<bool> addActiveHost(String raw) => _addHost(raw, _splitTunnelMode);

  Future<void> removeActiveHost(String host) =>
      _removeHost(host, _splitTunnelMode);

  Future<bool> _addHost(String raw, SplitTunnelMode mode) async {
    final host = raw.trim();
    if (!isValidBypassHost(host)) return false;
    final current = _hostsFor(mode);
    if (current.any((h) => h.toLowerCase() == host.toLowerCase())) {
      return false;
    }
    await _writeHosts(mode, <String>[...current, host]);
    return true;
  }

  Future<void> _removeHost(String host, SplitTunnelMode mode) async {
    final current = _hostsFor(mode);
    final next = current.where((h) => h != host).toList(growable: false);
    if (next.length == current.length) return;
    await _writeHosts(mode, next);
  }

  List<String> _hostsFor(SplitTunnelMode mode) =>
      mode == SplitTunnelMode.include ? _tunnelHosts : _bypassHosts;

  Future<void> _writeHosts(SplitTunnelMode mode, List<String> hosts) async {
    if (mode == SplitTunnelMode.include) {
      _tunnelHosts = hosts;
    } else {
      _bypassHosts = hosts;
    }
    notifyListeners();
    await _storage.write(
      key: mode == SplitTunnelMode.include
          ? _splitTunnelHostsKey
          : _splitHostsKey,
      value: hosts.join(','),
    );
  }

  /// A bypass host is valid when it is a domain (`example.com`, `*.ru`) or an
  /// IP / CIDR (`8.8.8.8`, `10.0.0.0/8`). Used by the UI to gate the add field.
  static bool isValidBypassHost(String raw) {
    final host = raw.trim();
    if (host.isEmpty) return false;
    return _asCidr(host) != null || _asDomainSuffix(host) != null;
  }

  /// Built fresh at each connect so preference edits take effect on reconnect.
  ///
  /// [clashApiSecret] gates the tunnel's local control API — see
  /// [MiscOptions.clashApiSecret]. The caller owns it because it also has to
  /// present it when probing.
  SingboxFeatureSettings buildFeatureSettings({String? clashApiSecret}) {
    final whitelist = _splitTunnelMode == SplitTunnelMode.include;

    // Per-app split tunneling (Android): on only when at least one app is
    // picked. An empty list is a no-op in exclusion mode, and in whitelist mode
    // it is worse than that — "tunnel only these apps: none" would be a VPN
    // that carries nothing — so an empty pick deliberately means "don't filter
    // by app at all" rather than "filter everything out".
    final packages = activePackages;
    final splitApps = _splitTunnelEnabled && packages.isNotEmpty;

    // Host-based split tunneling (iOS + also honoured on Android): classify
    // each raw entry into a domain-suffix or ip-cidr route rule. These are
    // platform independent (pure packet routing inside the TUN), so they take
    // effect on iOS where per-app split tunneling is impossible.
    //
    // In whitelist mode the same entries become `regionProxy*` instead, which
    // is what flips the config's default route to `direct` — see
    // RouteOptions.tunnelsOnlyListedHosts, where an empty list likewise leaves
    // the full tunnel alone rather than routing everything around it.
    final domains = <String>[];
    final cidrs = <String>[];
    if (_splitTunnelEnabled) {
      for (final raw in activeHosts) {
        final cidr = _asCidr(raw);
        if (cidr != null) {
          cidrs.add(cidr);
          continue;
        }
        final domain = _asDomainSuffix(raw);
        if (domain != null) domains.add(domain);
      }
    }

    final useCustomDns =
        _dnsPreset == DnsProviderPreset.custom && _customDns.trim().isNotEmpty;
    return SingboxFeatureSettings(
      route: RouteOptions(
        regionDirectDomains: whitelist ? const <String>[] : domains,
        regionDirectCidrs: whitelist ? const <String>[] : cidrs,
        regionProxyDomains: whitelist ? domains : const <String>[],
        regionProxyCidrs: whitelist ? cidrs : const <String>[],
        // Domain-suffix route rules only match once sing-box knows the
        // connection's domain, which requires sniffing (SNI/host). Enable it
        // only when there are domain rules — IP/CIDR rules match on the
        // destination address alone and need no sniffing.
        resolveDestination: domains.isNotEmpty,
      ),
      dns: DnsOptions.fromProvider(
        preset: _dnsPreset,
        remoteDnsOverride: useCustomDns ? _customDns.trim() : null,
      ),
      inbound: InboundOptions(
        tunImplementation: _networkStack,
        splitTunnelingEnabled: splitApps,
        includePackages:
            splitApps && whitelist ? packages.toList() : const <String>[],
        excludePackages:
            splitApps && !whitelist ? packages.toList() : const <String>[],
      ),
      misc: MiscOptions(clashApiSecret: clashApiSecret),
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
