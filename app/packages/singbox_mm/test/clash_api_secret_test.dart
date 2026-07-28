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
}
