import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:singbox_mm/singbox_mm.dart';

/// Checks what the tunnel actually builds from the `hysteria2://` link the BFF's
/// SubscriptionAugmenter synthesizes, so a mismatch with the panel's own render
/// of the same host shows up here instead of only as "connected, but no
/// internet" on a device.
///
/// Reference — what Remnawave renders for these hosts (xray-json):
///   network=hysteria, security=tls, version 2,
///   tls: {serverName: h2-fr.arpozan.cloud, alpn: ["h3"], fingerprint: firefox}
///   auth: the user's vless UUID (verified equal against the live panel)
void main() {
  const link =
      'hysteria2://b0000000-0000-4000-8000-000000000000@h2-fr.arpozan.cloud:443'
      '?sni=h2-fr.arpozan.cloud&alpn=h3#%F0%9F%87%AB%F0%9F%87%B7%20H2';

  test('augmenter link builds a well-formed hysteria2 outbound', () {
    const parser = VpnConfigParser();
    final parsed = parser.parse(link);
    // ignore: avoid_print
    print('parser warnings: ${parsed.warnings}');

    const builder = SingboxConfigBuilder();
    final config = builder.build(profile: parsed.profile);

    final outbounds = (config['outbounds'] as List).cast<Map<String, Object?>>();
    final proxy = outbounds.firstWhere(
      (o) => o['type'] != 'direct' && o['type'] != 'block' && o['type'] != 'dns',
      orElse: () => <String, Object?>{},
    );

    // ignore: avoid_print
    print('--- built outbound ---\n${const JsonEncoder.withIndent('  ').convert(proxy)}');

    expect(proxy['type'], 'hysteria2',
        reason: 'the link must produce a hysteria2 outbound, not a fallback');
    expect(proxy['server'], 'h2-fr.arpozan.cloud');
    expect(proxy['server_port'], 443);
    expect(proxy['password'], isNotNull,
        reason: 'auth is what the panel puts in hysteriaSettings.auth');

    final tls = proxy['tls'] as Map<String, Object?>?;
    expect(tls, isNotNull, reason: 'server requires TLS');
    expect(tls!['enabled'], isTrue);
    expect(tls['server_name'], 'h2-fr.arpozan.cloud');
    expect(tls['alpn'], contains('h3'),
        reason: 'server advertises alpn h3/h3-29; offering neither fails the handshake');
  });
}
