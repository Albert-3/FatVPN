import 'package:flutter_test/flutter_test.dart';
import 'package:singbox_mm/singbox_mm.dart';

/// Where `RouteOptions.blockedDomainSuffixes` lands among the other route
/// rules.
///
/// sing-box takes the first rule that matches, so this ordering *is* the
/// feature: a block rule placed after the direct rules would be shadowed by
/// them for every blocked host that happens to sit under a bypassed domain —
/// `mc.yandex.ru` under a bypassed `yandex.ru`, say — and the emitted config
/// would look entirely correct while blocking nothing there.
///
/// Tested here, at the plugin, rather than through the app's settings: the app
/// currently keeps its blocklist and its bypass list from ever being on at the
/// same time (a product decision, and one that could be revisited), so it
/// cannot produce the combination this guarantee is about. The generator is
/// general-purpose and has to be right regardless of who calls it.
void main() {
  const link = 'vless://b0000000-0000-4000-8000-000000000000@de1.example.com'
      ':443?security=tls&type=tcp#DE-1';

  const blocked = <String>['doubleclick.net', 'mc.yandex.ru'];

  List<Map<String, Object?>> rulesFor(RouteOptions route) {
    const parser = VpnConfigParser();
    final parsed = parser.parse(link);
    const builder = SingboxConfigBuilder();
    final config = builder.build(
      profile: parsed.profile,
      settings: SingboxFeatureSettings(route: route),
    );
    return ((config['route'] as Map)['rules'] as List)
        .cast<Map>()
        .map((r) => r.cast<String, Object?>())
        .toList();
  }

  int indexOfDomain(List<Map<String, Object?>> rules, String domain) {
    for (var i = 0; i < rules.length; i++) {
      final suffixes = rules[i]['domain_suffix'];
      if (suffixes is List && suffixes.contains(domain)) return i;
    }
    return -1;
  }

  test('nothing is emitted while blockAdvertisements is off', () {
    final rules = rulesFor(
      const RouteOptions(blockedDomainSuffixes: blocked),
    );
    expect(indexOfDomain(rules, 'doubleclick.net'), -1);
  });

  test('nothing is emitted for an empty list', () {
    final rules = rulesFor(const RouteOptions(blockAdvertisements: true));
    expect(rules.any((r) => r['outbound'] == 'block' && r.containsKey('domain_suffix')),
        isFalse);
  });

  test('the block rule comes before the direct rules', () {
    final rules = rulesFor(
      const RouteOptions(
        blockAdvertisements: true,
        blockedDomainSuffixes: blocked,
        regionDirectDomains: <String>['yandex.ru'],
      ),
    );

    final blockedAt = indexOfDomain(rules, 'mc.yandex.ru');
    final directAt = indexOfDomain(rules, 'yandex.ru');
    expect(blockedAt, isNonNegative);
    expect(directAt, isNonNegative);
    expect(blockedAt, lessThan(directAt));
    expect(rules[blockedAt]['outbound'], 'block');
  });

  test('the block rule comes before the whitelist proxy rules', () {
    final rules = rulesFor(
      const RouteOptions(
        blockAdvertisements: true,
        blockedDomainSuffixes: blocked,
        regionProxyDomains: <String>['work.example.com'],
      ),
    );

    final blockedAt = indexOfDomain(rules, 'doubleclick.net');
    final proxyAt = indexOfDomain(rules, 'work.example.com');
    expect(blockedAt, isNonNegative);
    expect(proxyAt, isNonNegative);
    expect(blockedAt, lessThan(proxyAt));
  });

  test('the block rule comes after DNS hijacking', () {
    // Resolving must not depend on a blocklist: a rule that swallowed port 53
    // would take the tunnel's own DNS down with it.
    final rules = rulesFor(
      const RouteOptions(
        blockAdvertisements: true,
        blockedDomainSuffixes: blocked,
      ),
    );

    final blockedAt = indexOfDomain(rules, 'doubleclick.net');
    final hijackAt = rules.indexWhere((r) => r['action'] == 'hijack-dns');
    expect(hijackAt, isNonNegative);
    expect(hijackAt, lessThan(blockedAt));
  });

  test('the block rule comes after the private-network rule', () {
    final rules = rulesFor(
      const RouteOptions(
        blockAdvertisements: true,
        blockedDomainSuffixes: blocked,
        bypassLan: true,
      ),
    );

    final blockedAt = indexOfDomain(rules, 'doubleclick.net');
    final lanAt = rules.indexWhere((r) => r['ip_is_private'] == true);
    expect(lanAt, isNonNegative);
    expect(lanAt, lessThan(blockedAt));
  });

  test('survives a toMap/fromMap round trip', () {
    const route = RouteOptions(
      blockAdvertisements: true,
      blockedDomainSuffixes: blocked,
    );
    final restored = RouteOptions.fromMap(route.toMap());
    expect(restored.blockedDomainSuffixes, blocked);
    expect(restored.blockAdvertisements, isTrue);
  });
}
