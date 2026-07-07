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
  final _storage = const FlutterSecureStorage();

  DnsProviderPreset _dnsPreset = DnsProviderPreset.cloudflare;
  String _customDns = '';
  SingboxTunImplementation _networkStack = SingboxTunImplementation.gvisor;

  // Split tunneling: when enabled, apps in [_bypassPackages] skip the VPN
  // (mapped to sing-box `exclude_package`). Empty set = nothing bypasses.
  bool _splitTunnelEnabled = false;
  Set<String> _bypassPackages = <String>{};

  DnsProviderPreset get dnsPreset => _dnsPreset;

  /// User-entered resolver used when [dnsPreset] is [DnsProviderPreset.custom]
  /// (e.g. `https://1.1.1.1/dns-query`, `tls://8.8.8.8`, or a plain IP).
  String get customDns => _customDns;
  SingboxTunImplementation get networkStack => _networkStack;
  bool get splitTunnelEnabled => _splitTunnelEnabled;
  Set<String> get bypassPackages => _bypassPackages;

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

  /// Built fresh at each connect so preference edits take effect on reconnect.
  SingboxFeatureSettings buildFeatureSettings() {
    // Only bypass apps when the feature is on AND at least one app is picked;
    // an empty include/exclude list would otherwise be a no-op anyway.
    final split = _splitTunnelEnabled && _bypassPackages.isNotEmpty;
    final useCustomDns =
        _dnsPreset == DnsProviderPreset.custom && _customDns.trim().isNotEmpty;
    return SingboxFeatureSettings(
      dns: DnsOptions.fromProvider(
        preset: _dnsPreset,
        remoteDnsOverride: useCustomDns ? _customDns.trim() : null,
      ),
      inbound: InboundOptions(
        tunImplementation: _networkStack,
        splitTunnelingEnabled: split,
        excludePackages: split ? _bypassPackages.toList() : const <String>[],
      ),
    );
  }
}
