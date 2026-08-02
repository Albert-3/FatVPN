// V29 (docs/improvement-plan-ios.md) — the missing end-to-end pin.
//
// The per-finding tests each drive SingboxConfigBuilder with hand-made
// options, so they prove the builder *can* emit the right config — not that
// the app's own `ConnectionSettingsController.buildFeatureSettings()` asks it
// to. That gap is exactly where ~45 placebo tests lived: they pinned code
// that predates the remediation and would stay green if it were reverted.
//
// This file walks the real path — controller → feature settings → builder —
// under each platform override, and asserts the §3.2 (TUN stack), §3.3
// (memory profile) and §3.4 (MTU) outcomes together, plus the §2.2 secret,
// on the emitted JSON. Reverting any of those remediations turns this red.
//
// The release-log clamp (§2.4's Dart half) is covered here too, via the
// extracted `SingboxConfigBuilder.clampLogLevel`: the branch that matters is
// the release one, and a host test always runs in debug — as a private
// method reading `kReleaseMode` it was untestable by construction.

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singbox_mm/singbox_mm.dart';

import 'package:fatvpn_app/services/connection_settings_controller.dart';

const _link = 'vless://11111111-2222-3333-4444-555555555555'
    '@de1.example.com:443?security=tls&type=tcp#DE-1';

/// The whole app path: a freshly-loaded controller's settings, built into a
/// config for a plain vless node — what a first connect on a clean install
/// actually emits on [platform].
Future<Map<String, Object?>> _buildOn(TargetPlatform platform) async {
  debugDefaultTargetPlatformOverride = platform;
  try {
    // Constructed under the override: the controller seeds its network-stack
    // default at creation time.
    final settings = ConnectionSettingsController();
    await settings.load();
    final featureSettings =
        settings.buildFeatureSettings(clashApiSecret: 's3cr3t-e2e');
    const parser = VpnConfigParser();
    return const SingboxConfigBuilder().build(
      profile: parser.parse(_link).profile,
      settings: featureSettings,
      throttlePolicy: const TrafficThrottlePolicy(),
    );
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

Map<String, Object?>? _tun(Map<String, Object?> config) {
  final inbounds = config['inbounds'];
  if (inbounds is! List) return null;
  for (final inbound in inbounds) {
    if (inbound is Map && inbound['type'] == 'tun') {
      return inbound.map((k, v) => MapEntry(k as String, v));
    }
  }
  return null;
}

Map<String, Object?>? _section(Map<String, Object?> config, String key) {
  final value = config['experimental'];
  if (value is! Map) return null;
  final section = value[key];
  if (section is! Map) return null;
  return section.map((k, v) => MapEntry(k as String, v));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues(<String, String>{}));

  test('iOS defaults: system stack, MTU 1280, no on-disk cache, secret set',
      () async {
    final config = await _buildOn(TargetPlatform.iOS);
    final tun = _tun(config);

    expect(tun?['stack'], 'system',
        reason: '§3.2: gvisor is a userspace Go TCP/IP stack inside a ~50 MB '
            'jetsam ceiling; the controller must ask for system on iOS');
    expect(tun?['mtu'], 1280,
        reason: '§3.4: the iOS default; 1100 threw away ~20% of every packet');

    final cache = _section(config, 'cache_file');
    expect(cache?['enabled'], isNot(true),
        reason: '§3.3: buildFeatureSettings must pass memoryLimit on iOS — '
            'when it silently stopped doing so, the builder re-enabled the '
            'on-disk cache and nothing noticed');

    final clash = _section(config, 'clash_api');
    expect(clash?['secret'], 's3cr3t-e2e',
        reason: '§2.2: the secret the controller was handed must reach the '
            'emitted config, or every probe runs unauthenticated');
  });

  test('Android keeps gvisor and the cache; MTU is now 1280', () async {
    final config = await _buildOn(TargetPlatform.android);
    final tun = _tun(config);

    expect(tun?['stack'], 'gvisor',
        reason: 'the shipped, device-tested Android default');
    expect(tun?['mtu'], 1280,
        reason: 'raised from 1100 on 2026-08-02 as the precondition for the '
            'TUN carrying an inet6 address (docs/open-bugs.md 1.1): an '
            'interface below the IPv6 minimum link MTU cannot hold one, so '
            '1100 + inet6 would read as fixed and leak exactly as before');
    expect(_section(config, 'cache_file')?['enabled'], true,
        reason: 'Android has no jetsam ceiling and keeps the cache');
  });

  group('the release log clamp is finally reachable', () {
    test('release clamps debug and trace to warn', () {
      expect(SingboxConfigBuilder.clampLogLevel('debug', isRelease: true),
          'warn',
          reason: 'at debug the core logs the destination of every '
              'connection, and that text reaches a shareable support bundle');
      expect(SingboxConfigBuilder.clampLogLevel('trace', isRelease: true),
          'warn');
      expect(SingboxConfigBuilder.clampLogLevel('DEBUG', isRelease: true),
          'warn', reason: 'case must not be a way around the clamp');
    });

    test('release leaves ordinary levels alone', () {
      expect(
          SingboxConfigBuilder.clampLogLevel('info', isRelease: true), 'info');
      expect(
          SingboxConfigBuilder.clampLogLevel('warn', isRelease: true), 'warn');
    });

    test('debug builds may log at debug', () {
      expect(SingboxConfigBuilder.clampLogLevel('debug', isRelease: false),
          'debug',
          reason: 'the clamp is about shipped builds, not development');
    });
  });
}
