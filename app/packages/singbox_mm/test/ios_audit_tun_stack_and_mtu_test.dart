// Regression tests for docs/improvement-plan-ios.md §3.2 (TUN stack always
// gvisor) and §3.4 (MTU hardcoded to 1100).
//
// Both findings live in `singbox_inbound_builder.dart`, which is SHARED WITH
// ANDROID — every assertion below therefore states which platform's behaviour
// it is protecting, so a later edit can tell an intended iOS change from an
// accidental Android one.
//
// §3.2: `_toTunStack` returns 'gvisor' for both enum values, so the user-facing
// "network stack" setting is inert. gvisor is a full userspace TCP/IP stack in
// Go — the most memory-hungry option available — running inside a network
// extension capped at ~50 MB by jetsam. The setting must actually select a
// stack.
//
// §3.4: 1100 is far below the safe VPN range (1280-1420) and, worse, the whole
// adaptive-MTU machinery (TrafficThrottlePolicy.tunMtu, mtuProbeCandidates,
// singbox_mm_client_endpoint_health) computes an MTU that the config generator
// then throws away.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singbox_mm/singbox_mm.dart';

const _link =
    'vless://11111111-2222-3333-4444-555555555555@de1.example.com:443'
    '?security=tls&type=tcp#DE-1';

Map<String, Object?> _build({
  SingboxFeatureSettings settings = const SingboxFeatureSettings(),
  TrafficThrottlePolicy throttle = const TrafficThrottlePolicy(),
}) {
  const parser = VpnConfigParser();
  const builder = SingboxConfigBuilder();
  return builder.build(
    profile: parser.parse(_link).profile,
    settings: settings,
    throttlePolicy: throttle,
  );
}

/// The `tun` inbound of a generated config, or null when the config has none.
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

Map<String, Object?>? _tunFor(SingboxTunImplementation implementation) => _tun(
      _build(
        settings: SingboxFeatureSettings(
          inbound: InboundOptions(tunImplementation: implementation),
        ),
      ),
    );

void main() {
  group('§3.2 the network-stack setting selects a stack', () {
    test('system means the system stack, not gvisor', () {
      expect(
        _tunFor(SingboxTunImplementation.system)?['stack'],
        'system',
        reason: 'gvisor is a userspace Go TCP/IP stack with per-connection '
            'buffers and goroutines; forcing it inside the ~50 MB iOS network '
            'extension is the likeliest cause of jetsam kills under load',
      );
    });

    test('gvisor still means gvisor (Android regression guard)', () {
      expect(
        _tunFor(SingboxTunImplementation.gvisor)?['stack'],
        'gvisor',
        reason: 'the file is shared with Android, where gvisor is the shipped '
            'default and the compatibility option',
      );
    });

    test('the default is unchanged (Android regression guard)', () {
      // InboundOptions defaults to gvisor and connection_settings_controller
      // seeds the same value; an iOS-motivated edit must not silently move
      // every Android install onto a different stack.
      expect(_tun(_build())?['stack'], 'gvisor');
    });

    test('no two implementations collapse onto the same stack', () {
      final stacks = <Object?>{
        for (final impl in SingboxTunImplementation.values)
          _tunFor(impl)?['stack'],
      };
      expect(
        stacks.length,
        SingboxTunImplementation.values.length,
        reason: 'if two enum values map to one string the setting is inert '
            'again — which is exactly how this bug shipped',
      );
    });
  });

  group('§3.4 the tun MTU is not hardcoded', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    Object? mtuOn(TargetPlatform platform) {
      debugDefaultTargetPlatformOverride = platform;
      try {
        return _tun(_build())?['mtu'];
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }

    test('the iOS default MTU is inside the safe VPN range', () {
      final mtu = mtuOn(TargetPlatform.iOS);

      expect(mtu, isA<int>());
      expect(
        mtu as int,
        greaterThanOrEqualTo(1280),
        reason: '1280 is the IPv6 minimum link MTU and the conventional safe '
            'floor; 1100 throws away ~20% of every packet to headers and '
            'multiplies the number of trips through the tun stack',
      );
      expect(mtu, lessThanOrEqualTo(1500),
          reason: 'above the Ethernet MTU the tunnel would fragment');
    });

    test('the Android default is the IPv6 minimum, not the old 1100', () {
      // Changed 2026-08-02, and not for throughput: it is the precondition for
      // giving the Android TUN an inet6 address (docs/open-bugs.md 1.1). An
      // interface below 1280 may not carry IPv6 at all, so "1100 + inet6" is a
      // tunnel that reads as fixed and leaks exactly as before.
      //
      // The pin stays a literal so the next edit has to decide rather than
      // drift: the value the released Android build was device-tested against
      // is 1100, and this one has been on no device at all.
      expect(mtuOn(TargetPlatform.android), 1280);
    });

    test('an explicit InboundOptions.mtu wins over the platform default', () {
      final mtu = _tun(_build(
        settings: const SingboxFeatureSettings(
          inbound: InboundOptions(mtu: 1420),
        ),
      ))?['mtu'];

      expect(mtu, 1420);
    });

    test('a configured tunMtu reaches the tun inbound', () {
      // TrafficThrottlePolicy.tunMtu is the *pre-existing* MTU knob: default
      // 1400, asserted >= 1280, set by every GFW preset, and the value the
      // adaptive probe recomputes. A second knob (InboundOptions.mtu) does not
      // make this one work — while the generator ignores it, everything that
      // drives it is decoration.
      final mtu = _tun(_build(
        throttle: const TrafficThrottlePolicy(tunMtu: 1380),
      ))?['mtu'];

      expect(mtu, 1380);
    });

    test('an adaptively probed MTU reaches the tun inbound', () {
      // The failover path re-writes the config with a lower tunMtu picked from
      // mtuProbeCandidates (singbox_mm_client_endpoint_health.dart:21-27). A
      // hardcoded MTU makes that whole probe a no-op: it measures, decides,
      // rewrites — and emits the same number as before.
      final first = _tun(_build(
        throttle: const TrafficThrottlePolicy(tunMtu: 1400),
      ))?['mtu'];
      final probed = _tun(_build(
        throttle: const TrafficThrottlePolicy(tunMtu: 1320),
      ))?['mtu'];

      expect(first, 1400);
      expect(probed, 1320);
      expect(probed, isNot(first),
          reason: 'adaptive MTU that never changes the emitted MTU cannot fix '
              'a path-MTU problem');
    });

    test('no MTU is claimed when nobody configured one', () {
      // The precondition for the platform default to survive the runtime path
      // below: an unset throttle MTU must stay unset, not resolve to the top
      // probe candidate.
      expect(const TrafficThrottlePolicy().tunMtu, isNull);
      expect(const TrafficThrottlePolicy(tunMtu: 1380).tunMtu, 1380);
    });

    test('proxy-only mode still emits no tun inbound at all', () {
      // Guard against an MTU fix accidentally materialising a tun inbound in
      // the mode that must not have one.
      final config = _build(
        settings: const SingboxFeatureSettings(
          inbound: InboundOptions(serviceMode: SingboxServiceMode.proxyOnly),
        ),
      );

      expect(_tun(config), isNull);
    });
  });
}
