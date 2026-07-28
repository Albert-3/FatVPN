// Regression tests for docs/improvement-plan-ios.md §1.7 — IPv6 leaving around
// the tunnel.
//
// The audit's own prescription (`settings.ipv6Settings = nil` when there are no
// addresses) made iOS behave *predictably* and did not stop the leak: with no
// IPv6 on the tunnel interface the OS simply routes no v6 into it, and every v6
// connection goes out on the physical interface with the user's real address.
//
// The blocking rule `::/0 → block` had existed in the config all along
// (singbox_route_rules_builder.dart) — it just never saw a packet, because a
// rule can only act on traffic that reached the core. Giving the TUN an inet6
// address is what makes it reachable. So the two halves are one fix and have to
// be asserted together: an address without the rule is a leak, the rule without
// an address is decoration.
//
// The file `singbox_inbound_builder.dart` is SHARED WITH ANDROID, which stays
// IPv4-only on purpose (its released build was device-tested that way), so every
// assertion below names the platform it protects.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singbox_mm/singbox_mm.dart';

const _link =
    'vless://11111111-2222-3333-4444-555555555555@de1.example.com:443'
    '?security=tls&type=tcp#DE-1';

Map<String, Object?> _build([
  SingboxFeatureSettings settings = const SingboxFeatureSettings(),
]) {
  const parser = VpnConfigParser();
  const builder = SingboxConfigBuilder();
  return builder.build(
    profile: parser.parse(_link).profile,
    settings: settings,
  );
}

Map<String, Object?>? _tun(Map<String, Object?> config) {
  final inbounds = config['inbounds'];
  if (inbounds is! List) return null;
  for (final inbound in inbounds) {
    if (inbound is Map && inbound['type'] == 'tun') {
      return inbound.map((k, v) => MapEntry(k as String, v));
    }
  }
  return null;
}

List<String> _tunAddresses(Map<String, Object?> config) =>
    ((_tun(config)?['address'] as List?) ?? const <Object?>[])
        .cast<String>()
        .toList();

List<Map<String, Object?>> _rules(Map<String, Object?> config) {
  final route = config['route'];
  if (route is! Map) return const <Map<String, Object?>>[];
  final rules = route['rules'];
  if (rules is! List) return const <Map<String, Object?>>[];
  return rules
      .whereType<Map>()
      .map((r) => r.map((k, v) => MapEntry(k as String, v)))
      .toList();
}

/// Index of the first rule matching [test], or -1.
int _indexWhere(
  Map<String, Object?> config,
  bool Function(Map<String, Object?>) test,
) {
  final rules = _rules(config);
  for (int i = 0; i < rules.length; i++) {
    if (test(rules[i])) return i;
  }
  return -1;
}

bool _isV6Block(Map<String, Object?> rule) {
  final cidr = rule['ip_cidr'];
  return cidr is List && cidr.contains('::/0') && rule['outbound'] == 'block';
}

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  group('§1.7 the TUN carries an inet6 address on iOS', () {
    test('iOS: the tun inbound has a v6 address, so ::/0 can be enforced', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

      final addresses = _tunAddresses(_build());

      expect(
        addresses.any((a) => a.contains(':')),
        isTrue,
        reason:
            'without an inet6 address on the interface iOS routes no v6 '
            'into the tunnel at all, and the ::/0 block rule below never sees '
            'a packet — which is exactly how the leak survived the audit fix',
      );
      expect(addresses, contains(defaultTunInet6Address));
    });

    test('Android: the tun inbound stays IPv4-only', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      final addresses = _tunAddresses(_build());

      expect(
        addresses.where((a) => a.contains(':')),
        isEmpty,
        reason:
            'the released Android build was device-tested IPv4-only; '
            'porting this is a separate task with its own run, not a side '
            'effect of the iOS fix',
      );
      expect(addresses, hasLength(1));
    });

    test('the address is a documented ULA, not a routable prefix', () {
      // The getter is platform-keyed and answers null off iOS, so the override
      // is part of the assertion rather than scaffolding.
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

      // fdfe::/8 is unique-local: it cannot be reached from the internet, so
      // handing it to the interface leaks nothing by itself.
      expect(defaultTunInet6Address, startsWith('fd'));
      expect(defaultTunInet6Address, contains('/'));

      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(
        defaultTunInet6Address,
        isNull,
        reason: 'and Android must not pick it up by accident',
      );
    });
  });

  group('§1.7 the blocking rule is present and reachable', () {
    test('ipv6RouteMode disable emits ::/0 → block', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

      expect(
        _indexWhere(_build(), _isV6Block),
        greaterThanOrEqualTo(0),
        reason:
            'v6 is blocked, not proxied — test-ipv6.com must report no '
            'IPv6 rather than the exit node (T12)',
      );
    });

    test('::/0 → block comes before the private-network bypass', () {
      // Order matters now in a way it did not before: while the rule was
      // unreachable, nothing downstream of it could be shadowed. Pinned so the
      // trade-off is a decision rather than an accident.
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final config = _build(
        const SingboxFeatureSettings(route: RouteOptions(bypassLan: true)),
      );

      final block = _indexWhere(config, _isV6Block);
      final private = _indexWhere(config, (r) => r['ip_is_private'] == true);

      expect(block, greaterThanOrEqualTo(0));
      expect(
        private,
        greaterThan(block),
        reason:
            'accepted consequence: link-local v6 (Bonjour, AirPlay, '
            'printers) is blocked rather than sent direct. Safety over '
            'convenience — but stated, so a report of "AirPlay stopped '
            'working under VPN" has a documented cause',
      );
    });

    test('::/0 → block also precedes the direct-domain bypass list', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final config = _build(
        const SingboxFeatureSettings(
          route: RouteOptions(regionDirectDomains: <String>['yandex.ru']),
        ),
      );

      final block = _indexWhere(config, _isV6Block);
      final direct = _indexWhere(config, (r) => r['domain_suffix'] != null);

      expect(block, greaterThanOrEqualTo(0));
      expect(
        direct,
        greaterThan(block),
        reason:
            'a bypass host reached over AAAA is blocked, not sent '
            'direct; Happy Eyeballs falls back to v4 after a delay. If that '
            'delay ever shows up as "Yandex is slow under VPN", this is why',
      );
    });
  });

  group('§1.7 modes other than disable', () {
    test('prefer: an inet6 address without a blocking rule is not a leak', () {
      // Д6 from the review: the address is currently handed out on iOS
      // regardless of route mode. That is only safe while `disable` is the
      // default — under `prefer` the tunnel carries v6 for real, which is a
      // different (and legitimate) posture. Pinned so the combination is a
      // choice.
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final config = _build(
        const SingboxFeatureSettings(
          route: RouteOptions(ipv6RouteMode: SingboxIpv6RouteMode.prefer),
        ),
      );

      expect(
        _indexWhere(config, _isV6Block),
        -1,
        reason: 'prefer means v6 goes through the tunnel',
      );
      expect(
        _tunAddresses(config).any((a) => a.contains(':')),
        isTrue,
        reason:
            'and it can only do that if the interface has a v6 address — '
            'so under prefer the address is the feature, not the risk',
      );
    });

    test('disable is still the default route mode', () {
      // The whole §1.7 argument rests on this: if the default ever flips, the
      // two tests above start describing a configuration nobody ships.
      expect(const RouteOptions().ipv6RouteMode, SingboxIpv6RouteMode.disable);
    });
  });
}
