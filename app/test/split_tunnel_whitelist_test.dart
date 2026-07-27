import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singbox_mm/singbox_mm.dart';

import 'package:fatvpn_app/services/connection_settings_controller.dart';

/// End-to-end check of what the two split-tunnel modes actually build, from the
/// user's saved settings all the way down to the sing-box config.
///
/// The routing is the whole feature, and it is invisible in the UI: an
/// exclusion list and a whitelist look identical on screen and differ only in
/// which rules and which `final` outbound come out the other end. Getting that
/// backwards would silently send either everything or nothing through the
/// tunnel, which is exactly the failure a device test is worst at spotting —
/// "the internet works" is true in both directions.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const link = 'vless://b0000000-0000-4000-8000-000000000000@de1.example.com'
      ':443?security=tls&type=tcp#DE-1';

  /// The config the tunnel would be started with, for a controller loaded from
  /// [storage].
  Future<Map<String, Object?>> buildConfigFor(
    Map<String, String> storage,
  ) async {
    FlutterSecureStorage.setMockInitialValues(storage);
    final settings = ConnectionSettingsController();
    await settings.load();

    const parser = VpnConfigParser();
    final parsed = parser.parse(link);
    const builder = SingboxConfigBuilder();
    return builder.build(
      profile: parsed.profile,
      settings: settings.buildFeatureSettings(),
    );
  }

  Map<String, Object?> routeOf(Map<String, Object?> config) =>
      (config['route'] as Map).cast<String, Object?>();

  Map<String, Object?> dnsOf(Map<String, Object?> config) =>
      (config['dns'] as Map).cast<String, Object?>();

  List<Map<String, Object?>> rulesOf(Map<String, Object?> section) =>
      (section['rules'] as List)
          .cast<Map>()
          .map((r) => r.cast<String, Object?>())
          .toList();

  /// The rule that names [domain] as a `domain_suffix`, or null.
  Map<String, Object?>? ruleForDomain(
    List<Map<String, Object?>> rules,
    String domain,
  ) {
    for (final rule in rules) {
      final suffixes = rule['domain_suffix'];
      if (suffixes is List && suffixes.contains(domain)) return rule;
    }
    return null;
  }

  group('exclusion mode', () {
    test('tunnels everything and routes the listed host around it', () async {
      final config = await buildConfigFor(<String, String>{
        'conn_split_enabled': 'true',
        'conn_split_mode': 'exclude',
        'conn_split_hosts': 'bank.example.com,10.0.0.0/8',
        'conn_split_hosts_seed_version': '2',
      });

      final route = routeOf(config);
      expect(route['final'], isNot('direct'),
          reason: 'unlisted traffic must still go through the server');

      final rule = ruleForDomain(rulesOf(route), 'bank.example.com');
      expect(rule, isNotNull);
      expect(rule!['outbound'], 'direct');

      // Every A query gets a fake IP, which is what lets the domain rules match.
      final dnsRules = rulesOf(dnsOf(config));
      expect(
        dnsRules.any((r) =>
            r['server'] == 'dns-fakeip' && r['domain_suffix'] == null),
        isTrue,
      );
    });
  });

  group('whitelist mode', () {
    Future<Map<String, Object?>> whitelistConfig() => buildConfigFor(
          <String, String>{
            'conn_split_enabled': 'true',
            'conn_split_mode': 'include',
            'conn_split_tunnel_hosts': 'work.example.com,203.0.113.0/24',
            'conn_split_hosts_seed_version': '2',
          },
        );

    test('sends everything direct by default', () async {
      expect(routeOf(await whitelistConfig())['final'], 'direct');
    });

    test('routes the listed domain and CIDR into the tunnel', () async {
      final config = await whitelistConfig();
      final proxyTag = (config['outbounds'] as List)
          .cast<Map>()
          .map((o) => o.cast<String, Object?>())
          .firstWhere((o) => o['type'] != 'direct' && o['type'] != 'block')['tag'];

      final rules = rulesOf(routeOf(config));
      expect(ruleForDomain(rules, 'work.example.com')?['outbound'], proxyTag);

      final cidrRule = rules.firstWhere(
        (r) => (r['ip_cidr'] as List?)?.contains('203.0.113.0/24') ?? false,
        orElse: () => <String, Object?>{},
      );
      expect(cidrRule['outbound'], proxyTag);
    });

    test('resolves only the whitelisted names through the tunnel', () async {
      final dns = dnsOf(await whitelistConfig());
      final rules = rulesOf(dns);

      // Anything no rule claimed is not being tunnelled, so it must not be
      // resolved through the server either.
      expect(dns['final'], 'dns-direct');

      // A blanket fake-IP rule here would hand 198.18.x.x to names that leave
      // through `direct`, where that address means nothing — the whole internet
      // would break the moment a whitelist was saved.
      expect(
        rules.any(
            (r) => r['server'] == 'dns-fakeip' && r['domain_suffix'] == null),
        isFalse,
      );
      expect(ruleForDomain(rules, 'work.example.com')?['server'], 'dns-fakeip');
    });
  });

  group('an empty whitelist', () {
    test('leaves the full tunnel up instead of routing it all away', () async {
      // The safe reading of "tunnel only these: none". Routing everything
      // direct here would turn an unfinished setting into a silent VPN bypass.
      final config = await buildConfigFor(<String, String>{
        'conn_split_enabled': 'true',
        'conn_split_mode': 'include',
        'conn_split_hosts_seed_version': '2',
      });

      expect(routeOf(config)['final'], isNot('direct'));
      expect(dnsOf(config)['final'], isNot('dns-direct'));
    });
  });
}
