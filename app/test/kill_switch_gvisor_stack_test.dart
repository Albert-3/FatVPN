// Regression test for the tunnel that never comes up with the kill switch on
// (iPhone 16, 2026-08-04).
//
// sing-box refuses to start the `system` (or `mixed`) TUN stack when the VPN
// profile carries `includeAllNetworks` (sing-tun#25) — the extension dies with
// "START FAILED: `system` and `mixed` stack are not available when
// `includeAllNetworks` is enabled". On this app the two meet by default: the
// audit made `system` the iOS stack (§3.2, memory), and the kill switch sets
// `includeAllNetworks`. On the tester's device every connect failed until the
// switch was turned off — the failure the video showed as "iOS 18+ doesn't
// work" was this, not the widget.
//
// Pinned here: with the kill switch on, an iOS config is built on gvisor — the
// one stack that can start at all — and the user's stored pick comes back the
// moment the switch goes off. Android is untouched either way.
//
// The extension has a second, native guard for configs persisted before the
// switch was flipped (PacketTunnelProvider.forceGvisorStack) — that half can
// only be exercised on CI/device, not from a host test.

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singbox_mm/singbox_mm.dart';

import 'package:fatvpn_app/services/connection_settings_controller.dart';

Future<ConnectionSettingsController> _loadedController() async {
  FlutterSecureStorage.setMockInitialValues(<String, String>{});
  final controller = ConnectionSettingsController();
  await controller.load();
  return controller;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('iOS: the kill switch forces the gvisor stack', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final controller = await _loadedController();
    expect(controller.networkStack, SingboxTunImplementation.system,
        reason: 'setup: iOS defaults to the system stack (§3.2)');

    await controller.setKillSwitch(true);

    expect(
      controller.buildFeatureSettings().inbound.tunImplementation,
      SingboxTunImplementation.gvisor,
      reason: 'includeAllNetworks + system/mixed stack is a tunnel sing-box '
          'refuses to start — not a preference to honour',
    );
  });

  test('iOS: turning the kill switch off gives the stored stack back',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final controller = await _loadedController();
    await controller.setKillSwitch(true);
    await controller.setKillSwitch(false);

    expect(
      controller.buildFeatureSettings().inbound.tunImplementation,
      SingboxTunImplementation.system,
      reason: 'the override must not overwrite the stored pick — the setting '
          'still says what the user chose',
    );
  });

  test('Android: the kill switch does not touch the stack', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final controller = await _loadedController();
    await controller.setKillSwitch(true);

    expect(
      controller.buildFeatureSettings().inbound.tunImplementation,
      SingboxTunImplementation.gvisor,
      reason: 'Android runs gvisor anyway and has no includeAllNetworks — the '
          'device-tested platform must see no change',
    );
  });
}
