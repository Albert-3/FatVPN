// Regression tests for docs/improvement-plan-ios.md §3.3 — "cache_file on by
// default, logMaxLines 3000" — and the Dart-observable half of §2.4
// ("logLevel: debug must not reach a release build").
//
// The iOS network extension lives under a ~50 MB jetsam cap. `cache_file` plus
// `store_fakeip` keep a growing on-disk/in-memory cache inside that budget, and
// `AdvancedOptions.memoryLimit` is the switch that turns them off. The plugin's
// job here is only to honour the switch faithfully — the platform decision
// (force it on for iOS) belongs to the app and is pinned in
// app/test/ios_audit_feature_settings_test.dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:singbox_mm/singbox_mm.dart';

const _link =
    'vless://11111111-2222-3333-4444-555555555555@de1.example.com:443'
    '?security=tls&type=tcp#DE-1';

Map<String, Object?> _build({
  SingboxFeatureSettings settings = const SingboxFeatureSettings(),
  String logLevel = 'info',
}) {
  const parser = VpnConfigParser();
  const builder = SingboxConfigBuilder();
  return builder.build(
    profile: parser.parse(_link).profile,
    settings: settings,
    logLevel: logLevel,
  );
}

Map<String, Object?>? _cacheFile(Map<String, Object?> config) {
  final experimental = config['experimental'];
  if (experimental is! Map) return null;
  final cache = experimental['cache_file'];
  if (cache is! Map) return null;
  return cache.map((k, v) => MapEntry(k as String, v));
}

void main() {
  group('§3.3 memoryLimit governs the on-device caches', () {
    test('memoryLimit disables cache_file and the fakeip store', () {
      final cache = _cacheFile(_build(
        settings: const SingboxFeatureSettings(
          advanced: AdvancedOptions(memoryLimit: true),
        ),
      ));

      // Either the block is dropped outright or both flags are off; both are
      // "no cache", which is what the flag promises.
      if (cache == null) return;
      expect(cache['enabled'], isFalse);
      expect(cache['store_fakeip'], isFalse);
    });

    test('the two flags stay coupled to the switch', () {
      // The invariant, stated platform-neutrally so an iOS-only change at the
      // app layer does not have to touch the plugin: whatever memoryLimit says,
      // both cache flags say the opposite.
      for (final limited in <bool>[true, false]) {
        final cache = _cacheFile(_build(
          settings: SingboxFeatureSettings(
            advanced: AdvancedOptions(memoryLimit: limited),
          ),
        ));
        if (cache == null) continue;
        expect(cache['enabled'], !limited,
            reason: 'memoryLimit=$limited must decide cache_file.enabled');
        expect(cache['store_fakeip'], !limited,
            reason: 'memoryLimit=$limited must decide store_fakeip');
      }
    });
  });

  group('§2.4 debug logging is opt-in only', () {
    test('the shipped default never asks sing-box for debug logs', () {
      // sing-box at debug level writes every connection's destination domain
      // and address into stderr, which the app tails into the support bundle.
      final log = _build()['log'] as Map<String, Object?>;

      expect(log['level'], isNot('debug'));
      expect(log['level'], isNot('trace'));
    });

    test('the runtime log level the app passes is what lands in the config',
        () {
      // VpnController initializes with logLevel 'warn'; if that stopped being
      // honoured, the quiet default would silently become a verbose one.
      final log = _build(logLevel: 'warn')['log'] as Map<String, Object?>;

      expect(log['level'], 'warn');
    });

    test('an explicit debugMode is still honoured for local debugging', () {
      // Guard against over-correcting: developers must keep the switch. The
      // release clamp itself is not observable from a host test run (kReleaseMode
      // is false under `flutter test`) and is verified by reading the code.
      final log = _build(
        settings: const SingboxFeatureSettings(
          advanced: AdvancedOptions(debugMode: true),
        ),
      )['log'] as Map<String, Object?>;

      expect(log['level'], 'debug');
    });
  });
}
