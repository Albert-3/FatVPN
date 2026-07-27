import 'package:flutter_test/flutter_test.dart';
import 'package:singbox_mm/singbox_mm.dart';

void main() {
  // Verbatim from the panel subscription (the "Белые списки #1" host). Kept
  // whole on purpose: the padding parameters are a contract with the server's
  // inbound, and a trimmed fixture would stop testing the thing that breaks.
  const String whitelistLink =
      'vless://9b92889b-3752-4471-85f1-2c7ff30e2e22@81.222.127.189:443'
      '?encryption=none&type=xhttp&path=%2Fapi%2Fv1%2Fassets'
      '&host=d48e1a7c-e87d-4b55-a693-b6b7382464fd.selcdn.net&mode=packet-up'
      '&extra=%7B%22xmux%22%3A%7B%22cMaxReuseTimes%22%3A%220%22%2C%22maxConnections%22%3A%221%22%7D%2C'
      '%22noSSEHeader%22%3Atrue%2C%22xPaddingKey%22%3A%22_token%22%2C'
      '%22xPaddingHeader%22%3A%22X-Signature%22%2C%22xPaddingMethod%22%3A%22tokenish%22%2C'
      '%22uplinkHTTPMethod%22%3A%22DELETE%22%2C%22xPaddingObfsMode%22%3Atrue%2C'
      '%22xPaddingPlacement%22%3A%22query%22%2C%22uplinkDataPlacement%22%3A%22body%22%7D'
      '&security=tls&sni=d48e1a7c-e87d-4b55-a693-b6b7382464fd.selcdn.net'
      '&fp=qq&alpn=h2#Whitelist';

  const String realityLink =
      'vless://9b92889b-3752-4471-85f1-2c7ff30e2e22@fat-sp.arpozan.cloud:18443'
      '?encryption=none&type=xhttp&path=%2F&host=max.ru&mode=packet-up'
      '&security=reality&sni=max.ru&fp=qq'
      '&pbk=GPdxLu9G0BmcVKGBZC8lNISlc5WF1hBWs81rwFx7ZHo&sid=d906090f39a6#Reality';

  const String grpcLink =
      'vless://uuid@web.max.ru:8443?encryption=none&type=grpc'
      '&serviceName=grpc&mode=gun&security=none#GRPC';

  Map<String, Object?> streamOf(Map<String, Object?> config) {
    final Object? outbound = (config['outbounds']! as List<Object?>).single;
    return (outbound! as Map<String, Object?>)['streamSettings']!
        as Map<String, Object?>;
  }

  group('linkNeedsXrayCore', () {
    test('claims xhttp links, which sing-box cannot speak', () {
      expect(linkNeedsXrayCore(whitelistLink), isTrue);
      expect(linkNeedsXrayCore(realityLink), isTrue);
      expect(
        linkNeedsXrayCore('vless://u@h:443?type=splithttp#Old'),
        isTrue,
        reason: 'splithttp is the transport\'s former name',
      );
    });

    test('leaves everything sing-box handles natively alone', () {
      expect(linkNeedsXrayCore(grpcLink), isFalse);
      expect(linkNeedsXrayCore('vless://u@h:443?type=ws#WS'), isFalse);
      expect(linkNeedsXrayCore('hysteria2://u@h:443#H2'), isFalse);
      expect(linkNeedsXrayCore('not a uri at all'), isFalse);
    });
  });

  group('buildXraySocksBridgeConfig', () {
    test('offers the node as a local SOCKS server', () {
      final Map<String, Object?> config = buildXraySocksBridgeConfig(
        configLink: whitelistLink,
        socksPort: 11080,
      );

      final Map<String, Object?> inbound =
          (config['inbounds']! as List<Object?>).single!
              as Map<String, Object?>;
      expect(inbound['protocol'], 'socks');
      expect(inbound['listen'], '127.0.0.1');
      expect(inbound['port'], 11080);
      expect(
        (inbound['settings']! as Map<String, Object?>)['udp'],
        isTrue,
        reason: 'sing-box forwards UDP over this hop rather than tunnelling it',
      );
    });

    test('carries the padding contract through untouched', () {
      final Map<String, Object?> stream = streamOf(
        buildXraySocksBridgeConfig(configLink: whitelistLink),
      );

      expect(stream['network'], 'xhttp');
      final Map<String, Object?> xhttp =
          stream['xhttpSettings']! as Map<String, Object?>;
      expect(xhttp['mode'], 'packet-up');
      expect(xhttp['path'], '/api/v1/assets');
      expect(xhttp['host'], 'd48e1a7c-e87d-4b55-a693-b6b7382464fd.selcdn.net');

      final Map<String, Object?> extra = xhttp['extra']! as Map<String, Object?>;
      expect(extra['uplinkHTTPMethod'], 'DELETE');
      expect(extra['uplinkDataPlacement'], 'body');
      expect(extra['xPaddingPlacement'], 'query');
      expect(extra['xPaddingHeader'], 'X-Signature');
      expect(extra['xPaddingKey'], '_token');
      expect(extra['xPaddingObfsMode'], isTrue);
      expect(extra['noSSEHeader'], isTrue);
      expect((extra['xmux']! as Map<String, Object?>)['maxConnections'], '1');
    });

    test('fills the padding size the panel trims off its links', () {
      // The live host answers 400 to every uplink when Xray pads with its
      // default 100-1000 bytes; the panel's own Happ template says 16-64.
      final Map<String, Object?> stream = streamOf(
        buildXraySocksBridgeConfig(configLink: whitelistLink),
      );
      final Map<String, Object?> xhttp =
          stream['xhttpSettings']! as Map<String, Object?>;
      final Map<String, Object?> extra = xhttp['extra']! as Map<String, Object?>;
      expect(extra['xPaddingBytes'], '16-64');
    });

    test('keeps a padding size the link states itself', () {
      final Map<String, Object?> stream = streamOf(
        buildXraySocksBridgeConfig(
          configLink:
              'vless://u@h:443?type=xhttp&mode=packet-up'
              '&extra=%7B%22xPaddingObfsMode%22%3Atrue%2C%22xPaddingBytes%22%3A%22200-300%22%7D#X',
        ),
      );
      final Map<String, Object?> xhttp =
          stream['xhttpSettings']! as Map<String, Object?>;
      final Map<String, Object?> extra = xhttp['extra']! as Map<String, Object?>;
      expect(extra['xPaddingBytes'], '200-300');
    });

    test('presents the fronted name to TLS, not the address dialled', () {
      final Map<String, Object?> stream = streamOf(
        buildXraySocksBridgeConfig(configLink: whitelistLink),
      );

      expect(stream['security'], 'tls');
      final Map<String, Object?> tls =
          stream['tlsSettings']! as Map<String, Object?>;
      expect(tls['serverName'], 'd48e1a7c-e87d-4b55-a693-b6b7382464fd.selcdn.net');
      expect(tls['fingerprint'], 'qq');
      expect(tls['alpn'], <String>['h2']);
    });

    test('reads the vless user off the link', () {
      final Map<String, Object?> config = buildXraySocksBridgeConfig(
        configLink: whitelistLink,
      );
      final Map<String, Object?> outbound =
          (config['outbounds']! as List<Object?>).single!
              as Map<String, Object?>;
      expect(outbound['protocol'], 'vless');
      final Map<String, Object?> vnext =
          ((outbound['settings']! as Map<String, Object?>)['vnext']!
                  as List<Object?>)
              .single!
          as Map<String, Object?>;
      expect(vnext['address'], '81.222.127.189');
      expect(vnext['port'], 443);
      final Map<String, Object?> user =
          (vnext['users']! as List<Object?>).single! as Map<String, Object?>;
      expect(user['id'], '9b92889b-3752-4471-85f1-2c7ff30e2e22');
      expect(user['encryption'], 'none');
    });

    test('builds reality settings for the reality-fronted xhttp host', () {
      final Map<String, Object?> stream = streamOf(
        buildXraySocksBridgeConfig(configLink: realityLink),
      );

      expect(stream['security'], 'reality');
      final Map<String, Object?> reality =
          stream['realitySettings']! as Map<String, Object?>;
      expect(reality['serverName'], 'max.ru');
      expect(
        reality['publicKey'],
        'GPdxLu9G0BmcVKGBZC8lNISlc5WF1hBWs81rwFx7ZHo',
      );
      expect(reality['shortId'], 'd906090f39a6');
      expect(reality['fingerprint'], 'qq');
      expect(stream.containsKey('tlsSettings'), isFalse);
    });

    test('carries no routing of its own', () {
      final Map<String, Object?> config = buildXraySocksBridgeConfig(
        configLink: whitelistLink,
      );
      // sing-box owns split tunnelling and DNS; a second rule set here could
      // only disagree with it.
      expect(config.containsKey('routing'), isFalse);
      expect(config.containsKey('dns'), isFalse);
    });

    test('survives an unparseable extra instead of losing the server', () {
      final Map<String, Object?> stream = streamOf(
        buildXraySocksBridgeConfig(
          configLink:
              'vless://u@h:443?type=xhttp&mode=packet-up&extra=%7Bbroken#X',
        ),
      );
      final Map<String, Object?> xhttp =
          stream['xhttpSettings']! as Map<String, Object?>;
      expect(xhttp.containsKey('extra'), isFalse);
      expect(xhttp['mode'], 'packet-up');
    });

    test('refuses a link it cannot express', () {
      expect(
        () => buildXraySocksBridgeConfig(
          configLink: 'hysteria2://u@h:443?#H2',
        ),
        throwsFormatException,
      );
      expect(
        () => buildXraySocksBridgeConfig(configLink: 'vless://@h:443?type=xhttp'),
        throwsFormatException,
      );
    });
  });
}
