import 'package:flutter_test/flutter_test.dart';
import 'package:singbox_mm/singbox_mm.dart';

void main() {
  group('redirectProxyOutboundToSocks', () {
    Map<String, Object?> config() => <String, Object?>{
          'outbounds': <Object?>[
            <String, Object?>{
              'type': 'vless',
              'tag': 'proxy',
              'server': '81.222.127.189',
              'server_port': 443,
              'uuid': 'u',
              'transport': <String, Object?>{'type': 'http'},
            },
            <String, Object?>{'type': 'direct', 'tag': 'direct'},
            <String, Object?>{'type': 'block', 'tag': 'block'},
          ],
          'route': <String, Object?>{
            'final': 'proxy',
            'rules': <Object?>[
              <String, Object?>{'ip_cidr': <String>['81.222.127.189/32'], 'outbound': 'direct'},
            ],
          },
        };

    test('swaps the proxy outbound for a local socks endpoint', () {
      final patched = redirectProxyOutboundToSocks(
        config: config(),
        tag: 'proxy',
        host: '127.0.0.1',
        port: 10808,
      );

      final proxy = (patched['outbounds'] as List).first as Map;
      expect(proxy['type'], 'socks');
      expect(proxy['server'], '127.0.0.1');
      expect(proxy['server_port'], 10808);
      // The tag has to survive: every route rule addresses the outbound by it.
      expect(proxy['tag'], 'proxy');
      expect((patched['route'] as Map)['final'], 'proxy');
    });

    test('leaves direct/block outbounds and the rest of the config alone', () {
      final patched = redirectProxyOutboundToSocks(
        config: config(),
        tag: 'proxy',
        host: '127.0.0.1',
        port: 10808,
      );

      final tags = (patched['outbounds'] as List)
          .map((o) => (o as Map)['tag'])
          .toList();
      expect(tags, <String>['proxy', 'direct', 'block']);
      // The rule that keeps traffic to the node itself out of the tunnel is
      // what stops the loop once another engine dials that address.
      final rules = ((patched['route'] as Map)['rules'] as List).first as Map;
      expect(rules['ip_cidr'], <String>['81.222.127.189/32']);
    });

    test('does not mutate the config it was handed', () {
      final original = config();
      redirectProxyOutboundToSocks(
        config: original,
        tag: 'proxy',
        host: '127.0.0.1',
        port: 10808,
      );

      expect(((original['outbounds'] as List).first as Map)['type'], 'vless');
    });

    test('refuses a config whose proxy tag is absent', () {
      expect(
        () => redirectProxyOutboundToSocks(
          config: config(),
          tag: 'nope',
          host: '127.0.0.1',
          port: 10808,
        ),
        throwsFormatException,
      );
    });
  });
}
