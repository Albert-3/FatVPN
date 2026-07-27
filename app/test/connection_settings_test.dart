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

  group('split-tunnel mode', () {
    /// A controller with split tunneling on and the seeding already done, so a
    /// test only sees what it put there itself.
    Future<ConnectionSettingsController> seeded([
      Map<String, String> extra = const <String, String>{},
    ]) async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{
        'conn_split_enabled': 'true',
        'conn_split_hosts_seed_version': '2',
        ...extra,
      });
      final c = ConnectionSettingsController();
      await c.load();
      return c;
    }

    test('is exclusion by default, so an upgrade changes nothing', () async {
      final c = await seeded();
      expect(c.splitTunnelMode, SplitTunnelMode.exclude);
    });

    test('survives a restart', () async {
      final c = await seeded();
      await c.setSplitTunnelMode(SplitTunnelMode.include);

      final next = ConnectionSettingsController();
      await next.load();
      expect(next.splitTunnelMode, SplitTunnelMode.include);
    });

    test('keeps a list per mode instead of inverting the saved one', () async {
      // The point of separate lists: the seeded defaults are domains that must
      // *skip* the VPN, and reading them as a whitelist would leave the user
      // with three sites and no internet.
      final c = await seeded(<String, String>{
        'conn_split_hosts': 'bank.example.com',
      });
      await c.setSplitTunnelMode(SplitTunnelMode.include);
      await c.addActiveHost('work.example.com');

      expect(c.tunnelHosts, <String>['work.example.com']);
      expect(c.bypassHosts, contains('bank.example.com'));
      expect(c.bypassHosts, isNot(contains('work.example.com')));

      await c.setSplitTunnelMode(SplitTunnelMode.exclude);
      expect(c.activeHosts, c.bypassHosts,
          reason: 'coming back finds the exclusion list untouched');
    });

    test('removing an entry only touches the active mode', () async {
      final c = await seeded(<String, String>{
        'conn_split_hosts': 'shared.example.com',
        'conn_split_tunnel_hosts': 'shared.example.com',
      });
      await c.setSplitTunnelMode(SplitTunnelMode.include);
      await c.removeActiveHost('shared.example.com');

      expect(c.tunnelHosts, isEmpty);
      expect(c.bypassHosts, contains('shared.example.com'));
    });

    test('picks the matching per-app list for sing-box', () async {
      final c = await seeded(<String, String>{
        'conn_split_packages': 'com.example.bank',
        'conn_split_tunnel_packages': 'com.example.browser',
      });

      final excluding = c.buildFeatureSettings().inbound;
      expect(excluding.excludePackages, <String>['com.example.bank']);
      expect(excluding.includePackages, isEmpty);

      await c.setSplitTunnelMode(SplitTunnelMode.include);
      final including = c.buildFeatureSettings().inbound;
      expect(including.includePackages, <String>['com.example.browser']);
      expect(including.excludePackages, isEmpty);
    });

    test('an empty pick means no per-app filtering, not a shut tunnel',
        () async {
      final c = await seeded();
      await c.setSplitTunnelMode(SplitTunnelMode.include);

      final inbound = c.buildFeatureSettings().inbound;
      expect(inbound.splitTunnelingEnabled, isFalse);
      expect(inbound.includePackages, isEmpty);
    });

    test('the master switch still turns every rule off', () async {
      final c = await seeded(<String, String>{
        'conn_split_tunnel_hosts': 'work.example.com',
        'conn_split_tunnel_packages': 'com.example.browser',
      });
      await c.setSplitTunnelMode(SplitTunnelMode.include);
      await c.setSplitTunnelEnabled(false);

      final settings = c.buildFeatureSettings();
      expect(settings.route.tunnelsOnlyListedHosts, isFalse);
      expect(settings.inbound.includePackages, isEmpty);
    });
  });
}
