import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fatvpn_app/services/connection_settings_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ConnectionSettingsController.isValidBypassHost', () {
    test('accepts plain domains', () {
      expect(ConnectionSettingsController.isValidBypassHost('example.com'), isTrue);
      expect(ConnectionSettingsController.isValidBypassHost('sub.example.co.uk'), isTrue);
    });

    test('accepts wildcard / leading-dot domains', () {
      expect(ConnectionSettingsController.isValidBypassHost('*.ru'), isTrue);
      expect(ConnectionSettingsController.isValidBypassHost('.example.com'), isTrue);
    });

    test('accepts bare IPs and CIDRs (v4 and v6)', () {
      expect(ConnectionSettingsController.isValidBypassHost('8.8.8.8'), isTrue);
      expect(ConnectionSettingsController.isValidBypassHost('10.0.0.0/8'), isTrue);
      expect(ConnectionSettingsController.isValidBypassHost('2001:4860:4860::8888'), isTrue);
      expect(ConnectionSettingsController.isValidBypassHost('fc00::/7'), isTrue);
    });

    test('rejects junk, empty, and out-of-range masks', () {
      expect(ConnectionSettingsController.isValidBypassHost(''), isFalse);
      expect(ConnectionSettingsController.isValidBypassHost('   '), isFalse);
      expect(ConnectionSettingsController.isValidBypassHost('not a domain'), isFalse);
      expect(ConnectionSettingsController.isValidBypassHost('http://example.com'), isFalse);
      expect(ConnectionSettingsController.isValidBypassHost('10.0.0.0/33'), isFalse);
      expect(ConnectionSettingsController.isValidBypassHost('192.168.0.0/'), isFalse);
    });
  });

  group('default bypass hosts', () {
    test('are valid entries', () {
      for (final host in ConnectionSettingsController.defaultBypassHosts) {
        expect(ConnectionSettingsController.isValidBypassHost(host), isTrue,
            reason: '$host must be a valid bypass entry');
      }
    });

    test('are seeded and enabled on a fresh install', () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      final c = ConnectionSettingsController();
      await c.load();

      expect(c.bypassHosts, ConnectionSettingsController.defaultBypassHosts);
      expect(c.splitTunnelEnabled, isTrue);
      final settings = c.buildFeatureSettings();
      expect(settings.route.regionDirectDomains,
          containsAll(ConnectionSettingsController.defaultBypassHosts));
    });

    test('are the entry domains of the three services, without CDNs', () {
      final hosts = ConnectionSettingsController.defaultBypassHosts;
      expect(hosts, containsAll(<String>[
        'yandex.ru', 'ya.ru', //
        'wildberries.ru', 'wb.ru', //
        'ozon.ru',
      ]));
      expect(hosts, isNot(anyElement(isIn(<String>[
        'yandex.com', 'yandex.net', 'yastatic.net', //
        'wbbasket.ru', 'wbstatic.net', 'ozone.ru',
      ]))));
      expect(hosts.toSet(), hasLength(hosts.length), reason: 'no duplicates');
    });

    test('a user on batch 1 gets only the new batch on upgrade', () async {
      // Seeded by the first build that shipped defaults (legacy 'true' flag),
      // and the user dropped one of those entries afterwards.
      FlutterSecureStorage.setMockInitialValues(<String, String>{
        'conn_split_hosts': 'yandex.ru,wildberries.ru',
        'conn_split_enabled': 'true',
        'conn_split_hosts_seeded': 'true',
      });
      final c = ConnectionSettingsController();
      await c.load();

      expect(c.bypassHosts, isNot(contains('ozon.ru')),
          reason: 'a deleted batch-1 entry must not come back');
      expect(c.bypassHosts, containsAll(<String>['ya.ru', 'wb.ru']));

      // And the freshly added batch is not re-added on the next launch.
      final next = ConnectionSettingsController();
      await next.load();
      expect(next.bypassHosts, c.bypassHosts);
    });

    test('are appended to an existing user\'s own hosts, once', () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{
        'conn_split_hosts': 'mybank.ru',
        'conn_split_enabled': 'true',
      });
      final first = ConnectionSettingsController();
      await first.load();
      expect(first.bypassHosts,
          <String>['mybank.ru', ...ConnectionSettingsController.defaultBypassHosts]);

      // The user drops one of the seeded domains; a later launch must not
      // bring it back.
      await first.removeBypassHost('ozon.ru');
      final second = ConnectionSettingsController();
      await second.load();
      expect(second.bypassHosts, isNot(contains('ozon.ru')));
    });

    test('do not re-enable a switch the user turned off', () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{
        'conn_split_enabled': 'false',
      });
      final c = ConnectionSettingsController();
      await c.load();

      expect(c.splitTunnelEnabled, isFalse);
      expect(c.bypassHosts, ConnectionSettingsController.defaultBypassHosts);
    });
  });
}
