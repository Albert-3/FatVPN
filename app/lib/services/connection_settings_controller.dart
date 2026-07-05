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
  static const _stackKey = 'conn_network_stack';
  final _storage = const FlutterSecureStorage();

  DnsProviderPreset _dnsPreset = DnsProviderPreset.cloudflare;
  SingboxTunImplementation _networkStack = SingboxTunImplementation.gvisor;

  DnsProviderPreset get dnsPreset => _dnsPreset;
  SingboxTunImplementation get networkStack => _networkStack;

  /// DNS presets surfaced in the UI. `custom` is intentionally left out — it
  /// needs a text field for the resolver URL, which is a later task.
  static const dnsPresets = <DnsProviderPreset>[
    DnsProviderPreset.cloudflare,
    DnsProviderPreset.google,
    DnsProviderPreset.quad9,
    DnsProviderPreset.adguard,
  ];

  /// "Mixed" (system stack) and gVisor are the only tun implementations the
  /// plugin exposes; "Mixed" in the mockup maps to the native `system` stack.
  static const networkStacks = <SingboxTunImplementation>[
    SingboxTunImplementation.system,
    SingboxTunImplementation.gvisor,
  ];

  Future<void> load() async {
    final dns = await _storage.read(key: _dnsKey);
    final stack = await _storage.read(key: _stackKey);
    var changed = false;
    if (dns != null) {
      final match = DnsProviderPreset.values.where((p) => p.name == dns);
      if (match.isNotEmpty) {
        _dnsPreset = match.first;
        changed = true;
      }
    }
    if (stack != null) {
      final match =
          SingboxTunImplementation.values.where((s) => s.name == stack);
      if (match.isNotEmpty) {
        _networkStack = match.first;
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  Future<void> setDnsPreset(DnsProviderPreset preset) async {
    if (_dnsPreset == preset) return;
    _dnsPreset = preset;
    notifyListeners();
    await _storage.write(key: _dnsKey, value: preset.name);
  }

  Future<void> setNetworkStack(SingboxTunImplementation stack) async {
    if (_networkStack == stack) return;
    _networkStack = stack;
    notifyListeners();
    await _storage.write(key: _stackKey, value: stack.name);
  }

  /// Built fresh at each connect so preference edits take effect on reconnect.
  SingboxFeatureSettings buildFeatureSettings() {
    return SingboxFeatureSettings(
      dns: DnsOptions.fromProvider(preset: _dnsPreset),
      inbound: InboundOptions(tunImplementation: _networkStack),
    );
  }
}
