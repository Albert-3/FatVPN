import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singbox_mm/singbox_mm.dart';

import 'package:fatvpn_app/services/connection_settings_controller.dart';
import 'package:fatvpn_app/services/tracker_block_list.dart';

/// What the "Tracker protection" switch builds, and how it shares the app with
/// split tunneling.
///
/// The two are mutually exclusive by product decision, and the interesting part
/// is not the exclusion itself but the *return*: switching tracker protection
/// off has to put split tunneling back exactly as the user left it, including
/// across a restart. Getting that wrong loses somebody's per-app bypass rules
/// silently, and on Android those rules are usually a banking app that refuses
/// to run over a VPN.
///
/// The rule-order guarantee that used to live here — a block rule ahead of the
/// bypass rules — moved to the plugin (`tracker_block_rule_order_test.dart`),
/// because with the exclusion in force the app can no longer produce a config
/// where both lists are present.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const link = 'vless://b0000000-0000-4000-8000-000000000000@de1.example.com'
      ':443?security=tls&type=tcp#DE-1';

  Future<ConnectionSettingsController> loaded([
    Map<String, String> storage = const <String, String>{},
  ]) async {
    // Copied: the mock keeps the map it is handed and writes into it, so a
    // const literal would throw the moment anything is saved.
    FlutterSecureStorage.setMockInitialValues(Map<String, String>.of(storage));
    final settings = ConnectionSettingsController();
    await settings.load();
    return settings;
  }

  /// The config the tunnel would be started with, for [settings] as they stand.
  Map<String, Object?> configOf(ConnectionSettingsController settings) {
    const parser = VpnConfigParser();
    final parsed = parser.parse(link);
    const builder = SingboxConfigBuilder();
    return builder.build(
      profile: parsed.profile,
      settings: settings.buildFeatureSettings(),
    );
  }

  List<Map<String, Object?>> routeRulesOf(Map<String, Object?> config) =>
      ((config['route'] as Map)['rules'] as List)
          .cast<Map>()
          .map((r) => r.cast<String, Object?>())
          .toList();

  int indexOfDomain(List<Map<String, Object?>> rules, String domain) {
    for (var i = 0; i < rules.length; i++) {
      final suffixes = rules[i]['domain_suffix'];
      if (suffixes is List && suffixes.contains(domain)) return i;
    }
    return -1;
  }

  group('the switch', () {
    test('is off on a fresh install, and blocks nothing', () async {
      final settings = await loaded();

      expect(settings.blockTrackers, isFalse);
      final route = settings.buildFeatureSettings().route;
      expect(route.blockAdvertisements, isFalse);
      expect(route.blockedDomainSuffixes, isEmpty);
      expect(indexOfDomain(routeRulesOf(configOf(settings)), 'doubleclick.net'),
          -1);
    });

    test('survives a restart', () async {
      final first = await loaded();
      await first.setBlockTrackers(true);

      final second = ConnectionSettingsController();
      await second.load();
      expect(second.blockTrackers, isTrue);
    });

    test('emits one domain_suffix rule to the block outbound', () async {
      final settings = await loaded();
      await settings.setBlockTrackers(true);

      final rules = routeRulesOf(configOf(settings));
      final index = indexOfDomain(rules, 'doubleclick.net');
      expect(index, isNonNegative);
      expect(rules[index]['outbound'], 'block');
      expect(
        rules[index]['domain_suffix'],
        hasLength(TrackerBlockList.domainSuffixes.length),
      );
    });

    test('turns sniffing on, so the rules can match at all', () async {
      // Split tunneling is off while this runs, so there are no host rules to
      // switch sniffing on for — and a domain rule that never sees a domain is
      // a switch that does nothing.
      final settings = await loaded();
      await settings.setBlockTrackers(true);

      expect(settings.splitTunnelEnabled, isFalse);
      expect(routeRulesOf(configOf(settings)).first['action'], 'sniff');
    });
  });

  group('exclusion with split tunneling', () {
    test('turning protection on turns split tunneling off', () async {
      // Seeded on a fresh install, so split tunneling starts on.
      final settings = await loaded();
      expect(settings.splitTunnelEnabled, isTrue);

      await settings.setBlockTrackers(true);
      expect(settings.splitTunnelEnabled, isFalse);
      expect(settings.buildFeatureSettings().route.regionDirectDomains, isEmpty);
    });

    test('turning protection off brings split tunneling back', () async {
      final settings = await loaded();
      await settings.setBlockTrackers(true);
      await settings.setBlockTrackers(false);

      expect(settings.splitTunnelEnabled, isTrue);
      expect(settings.buildFeatureSettings().route.regionDirectDomains,
          containsAll(ConnectionSettingsController.defaultBypassHosts));
    });

    test('the return survives a restart', () async {
      // The whole point of persisting the marker: switch protection on, close
      // the app, switch it off a day later — the rules still come back.
      final first = await loaded();
      await first.setBlockTrackers(true);

      final second = ConnectionSettingsController();
      await second.load();
      expect(second.splitTunnelEnabled, isFalse);
      await second.setBlockTrackers(false);
      expect(second.splitTunnelEnabled, isTrue);
    });

    test('does not resurrect a split tunnel the user had turned off', () async {
      final settings = await loaded(<String, String>{
        'conn_split_enabled': 'false',
        'conn_split_hosts_seed_version': '2',
      });
      expect(settings.splitTunnelEnabled, isFalse);

      await settings.setBlockTrackers(true);
      await settings.setBlockTrackers(false);
      expect(settings.splitTunnelEnabled, isFalse,
          reason: 'nothing was suspended, so nothing may come back');
    });

    test('works the other way round too', () async {
      final settings = await loaded(<String, String>{
        'conn_split_enabled': 'false',
        'conn_split_hosts_seed_version': '2',
        'conn_block_trackers': 'true',
      });
      expect(settings.blockTrackers, isTrue);

      await settings.setSplitTunnelEnabled(true);
      expect(settings.blockTrackers, isFalse);

      await settings.setSplitTunnelEnabled(false);
      expect(settings.blockTrackers, isTrue);
    });

    test('the second switch takes ownership from the first', () async {
      // Protection suspends split tunneling; the user then turns split
      // tunneling back on by hand. That is now *their* choice, so releasing it
      // later must restore protection rather than leave both off.
      final settings = await loaded();
      await settings.setBlockTrackers(true);
      await settings.setSplitTunnelEnabled(true);

      expect(settings.blockTrackers, isFalse);
      await settings.setSplitTunnelEnabled(false);
      expect(settings.blockTrackers, isTrue);
    });

    test('a stored state with both on keeps split tunneling', () async {
      // Not reachable through the setters — it takes a hand-edited store or a
      // downgrade and back. Split tunneling wins, because losing it silently
      // puts an app the user deliberately kept out of the VPN back inside it.
      final settings = await loaded(<String, String>{
        'conn_split_enabled': 'true',
        'conn_split_hosts_seed_version': '2',
        'conn_block_trackers': 'true',
      });

      expect(settings.splitTunnelEnabled, isTrue);
      expect(settings.blockTrackers, isFalse);

      // And the correction is written through, not just held in memory.
      final next = ConnectionSettingsController();
      await next.load();
      expect(next.blockTrackers, isFalse);
    });

    test('never builds a config carrying both', () async {
      final settings = await loaded();
      for (final on in <bool>[true, false, true]) {
        await settings.setBlockTrackers(on);
        final route = settings.buildFeatureSettings().route;
        final hasBypass = route.regionDirectDomains.isNotEmpty ||
            route.regionProxyDomains.isNotEmpty;
        expect(route.blockAdvertisements && hasBypass, isFalse);
      }
    });
  });

  group('the list itself', () {
    test('holds only well-formed domain suffixes', () {
      for (final domain in TrackerBlockList.domainSuffixes) {
        expect(ConnectionSettingsController.isValidBypassHost(domain), isTrue,
            reason: '$domain is not a usable domain_suffix');
        expect(domain, domain.toLowerCase(),
            reason: '$domain must be lowercase — matching is literal');
      }
    });

    test('has no duplicates', () {
      final seen = <String>{};
      final duplicates = <String>[];
      for (final domain in TrackerBlockList.domainSuffixes) {
        if (!seen.add(domain)) duplicates.add(domain);
      }
      expect(duplicates, isEmpty);
    });

    test('contains no entry that another entry already covers', () {
      // A suffix list where one entry ends in another is not wrong, only
      // dead weight — and it usually means someone added a subdomain of
      // something already blocked wholesale.
      final all = TrackerBlockList.domainSuffixes.toSet();
      final redundant = <String>[];
      for (final domain in all) {
        for (final other in all) {
          if (other != domain && domain.endsWith('.$other')) {
            redundant.add('$domain (covered by $other)');
          }
        }
      }
      expect(redundant, isEmpty);
    });

    test('leaves the domains the user still has to reach alone', () {
      // Not a style rule: each of these either serves content, carries a
      // sign-in, or is the apex of a service the app itself routes around the
      // tunnel. Blocking any of them breaks the phone, not the tracking.
      const mustResolve = <String>[
        'googleapis.com',
        'gstatic.com',
        'google.com',
        'youtube.com',
        'facebook.com',
        'fbcdn.net',
        'connect.facebook.net',
        'graph.facebook.com',
        'branch.io',
        'mail.ru',
        'vk.com',
        'yandex.ru',
        'ya.ru',
        'ozon.ru',
        'wildberries.ru',
        'wb.ru',
        'rambler.ru',
        'apple.com',
        'icloud.com',
        'cloudflare.com',
      ];

      for (final host in mustResolve) {
        for (final blocked in TrackerBlockList.domainSuffixes) {
          expect(host == blocked || host.endsWith('.$blocked'), isFalse,
              reason: '$host must stay reachable, but "$blocked" blocks it');
        }
      }
    });
  });
}
