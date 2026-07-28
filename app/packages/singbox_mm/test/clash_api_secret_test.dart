// Regression test for docs/improvement-plan-app-android.md §1.6 (= iOS plan
// §2.2) — "Локальный clash-API открыт без секрета".
//
// `experimental.clash_api.external_controller` binds 127.0.0.1:16756. Android's
// loopback is NOT isolated between apps, so any installed app holding INTERNET
// can reach it: GET /connections is a live log of every domain the user visits,
// and PATCH /configs can switch routing off entirely. The control API must
// therefore never be published without a bearer secret.

import 'package:flutter_test/flutter_test.dart';
import 'package:singbox_mm/singbox_mm.dart';

const _link =
    'vless://11111111-2222-3333-4444-555555555555@de1.example.com:443'
    '?security=tls&type=tcp#DE-1';

Map<String, Object?> _buildWith(SingboxFeatureSettings settings) {
  const parser = VpnConfigParser();
  const builder = SingboxConfigBuilder();
  return builder.build(profile: parser.parse(_link).profile, settings: settings);
}

Map<String, Object?>? _clashApi(Map<String, Object?> config) {
  final experimental = config['experimental'];
  if (experimental is! Map) return null;
  final clash = experimental['clash_api'];
  if (clash is! Map) return null;
  return clash.map((k, v) => MapEntry(k as String, v));
}

void main() {
  test('the generated config never exposes clash_api without a secret', () {
    // Default settings: port 16756, no secret handed in. Publishing the
    // controller in that state is the hole — either omit clash_api or carry a
    // secret, but never an open controller.
    final clash = _clashApi(_buildWith(const SingboxFeatureSettings()));

    if (clash == null) return; // controller disabled entirely — also acceptable
    final secret = clash['secret'];
    expect(secret, isA<String>());
    expect((secret as String).length, greaterThanOrEqualTo(16),
        reason: 'an open or trivially guessable control API lets any installed '
            'app read the browsing log and disable proxying');
  });

  test('a caller-supplied secret is emitted verbatim', () {
    final clash = _clashApi(_buildWith(const SingboxFeatureSettings(
      misc: MiscOptions(
        clashApiPort: 16756,
        clashApiSecret: 'a-secret-of-sufficient-length',
      ),
    )));

    expect(clash, isNotNull,
        reason: 'a configured port must still publish the controller');
    expect(clash!['external_controller'], '127.0.0.1:16756');
    expect(clash['secret'], 'a-secret-of-sufficient-length');
  });

  test('no port means no controller at all — and so no secret to leak', () {
    expect(
      _clashApi(_buildWith(const SingboxFeatureSettings(
        misc: MiscOptions(clashApiPort: null),
      ))),
      isNull,
    );
  });

  test('the secret survives a settings round-trip through the platform map',
      () {
    const settings = SingboxFeatureSettings(
      misc: MiscOptions(clashApiSecret: 'round-trip-secret-value'),
    );

    final restored = SingboxFeatureSettings.fromMap(settings.toMap());

    expect(restored.misc.clashApiSecret, 'round-trip-secret-value');
  });

  // --- iOS plan §2.2: the generated secret must be unguessable ---------------
  //
  // On iOS 127.0.0.1 is device-wide, exactly as on Android, so a secret that
  // repeats across starts (or is short enough to enumerate) is no secret: it
  // only has to leak once — support bundle, shared log, a previous owner of the
  // device — to stay valid forever.

  group('§2.2 the generated secret is fresh and unguessable', () {
    test('a secret is generated per build, never reused', () {
      final first = _clashApi(_buildWith(const SingboxFeatureSettings()));
      final second = _clashApi(_buildWith(const SingboxFeatureSettings()));

      if (first == null && second == null) return; // controller disabled
      expect(first!['secret'], isNot(second!['secret']),
          reason: 'a fixed secret compiled into the app is public knowledge '
              'the moment one copy is unpacked');
    });

    test('the generated secret carries at least 128 bits', () {
      final clash = _clashApi(_buildWith(const SingboxFeatureSettings()));
      if (clash == null) return;

      final secret = clash['secret'] as String;
      // 32 hex chars, or 22 base64 chars, both encode 128 bits.
      expect(secret.length, greaterThanOrEqualTo(22));
      expect(RegExp(r'^[A-Za-z0-9+/=_-]+$').hasMatch(secret), isTrue,
          reason: 'the value travels in an Authorization header and in JSON');
    });

    test('twenty consecutive builds produce twenty distinct secrets', () {
      final secrets = <Object?>{
        for (var i = 0; i < 20; i++)
          _clashApi(_buildWith(const SingboxFeatureSettings()))?['secret'],
      };

      // Either the controller is off everywhere (one null) or all are unique.
      expect(secrets.length, anyOf(1, 20));
      if (secrets.length == 20) {
        expect(secrets.contains(null), isFalse);
      }
    });
  });

  // --- iOS plan §2.3: external_controller must be loopback ------------------
  //
  // The value is attacker-influenced: it comes from the config built out of the
  // BFF subscription link and can be overridden wholesale via
  // `settings.rawConfigPatch`, which is deep-merged *after* clash_api is built
  // (singbox_config_builder.dart:172-174). A hostile value makes the network
  // extension beacon out over plain HTTP every health tick and publishes
  // control of the core to the local network. The extension is asked to refuse
  // non-loopback controllers; Dart must refuse to emit one in the first place.

  group('§2.3 external_controller is pinned to loopback', () {
    Map<String, Object?>? clashWithPatch(String controller) => _clashApi(
          _buildWith(SingboxFeatureSettings(
            rawConfigPatch: <String, Object?>{
              'experimental': <String, Object?>{
                'clash_api': <String, Object?>{
                  'external_controller': controller,
                },
              },
            },
          )),
        );

    bool isLoopback(Object? controller) {
      if (controller is! String) return false;
      final host = controller.contains(']')
          ? controller.substring(0, controller.indexOf(']') + 1)
          : controller.split(':').first;
      return const <String>{
        '127.0.0.1',
        '::1',
        '[::1]',
        'localhost',
      }.contains(host) ||
          host.startsWith('127.');
    }

    test('a remote host in rawConfigPatch is never published', () {
      final clash = clashWithPatch('attacker.example:80');

      if (clash == null) return; // controller dropped entirely — also correct
      expect(isLoopback(clash['external_controller']), isTrue,
          reason: 'a network extension that dials an attacker-chosen host every '
              '60 s is a ready-made beacon, and it leaks the active outbound '
              'tag and the fact that the VPN is up');
    });

    test('a wildcard bind in rawConfigPatch is never published', () {
      final clash = clashWithPatch('0.0.0.0:16756');

      if (clash == null) return;
      expect(isLoopback(clash['external_controller']), isTrue,
          reason: '0.0.0.0 hands control of the core to everyone on the Wi-Fi');
    });

    test('an IPv6 wildcard bind is never published', () {
      final clash = clashWithPatch('[::]:16756');

      if (clash == null) return;
      expect(isLoopback(clash['external_controller']), isTrue);
    });

    test('a genuine loopback override is left alone', () {
      // Rejecting bad values must not mean rejecting good ones: the patch is a
      // supported escape hatch.
      final clash = clashWithPatch('127.0.0.1:19999');

      expect(clash, isNotNull);
      expect(clash!['external_controller'], '127.0.0.1:19999');
    });

    test('a patch cannot strip the secret off the controller', () {
      final clash = _clashApi(_buildWith(const SingboxFeatureSettings(
        rawConfigPatch: <String, Object?>{
          'experimental': <String, Object?>{
            'clash_api': <String, Object?>{'secret': ''},
          },
        },
      )));

      if (clash == null) return; // controller dropped — acceptable
      final secret = clash['secret'];
      expect(secret, isA<String>());
      expect((secret as String).length, greaterThanOrEqualTo(16),
          reason: 'an empty secret is an open controller wearing the shape of '
              'a closed one');
    });
  });
}
