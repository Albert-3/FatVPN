// App-side half of docs/improvement-plan-ios.md §3.3 — "cache_file on by
// default on iOS" — plus the §2.4 guard that the app never asks sing-box for
// debug-level logs.
//
// `buildFeatureSettings()` never passes `advanced:`, so `memoryLimit` stays
// false and the plugin duly emits `cache_file.enabled = true` and
// `store_fakeip = true`. On Android that is merely wasteful; inside the iOS
// network extension it is spent out of a ~50 MB jetsam budget, and a jetsam
// kill means the tunnel dies with no on-demand rule to bring it back (§1.3).
//
// The plan asks for the decision to be taken per platform via
// `defaultTargetPlatform`, which is what these tests drive. A fix written
// against `dart:io`'s `Platform.isIOS` instead would leave this behaviour
// unverifiable from a host test run.

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singbox_mm/singbox_mm.dart';

import 'package:fatvpn_app/services/connection_settings_controller.dart';

Future<SingboxFeatureSettings> _settingsOn(TargetPlatform platform) async {
  debugDefaultTargetPlatformOverride = platform;
  try {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    final controller = ConnectionSettingsController();
    await controller.load();
    return controller.buildFeatureSettings();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  group('§3.3 the memory profile follows the platform', () {
    test('iOS runs with the memory limit on', () async {
      final settings = await _settingsOn(TargetPlatform.iOS);

      expect(
        settings.advanced.memoryLimit,
        isTrue,
        reason: 'cache_file and store_fakeip are paid for out of the network '
            "extension's ~50 MB jetsam budget, and a jetsam kill takes the "
            'tunnel down with nothing configured to restart it',
      );
    });

    test('Android is left as it shipped', () async {
      final settings = await _settingsOn(TargetPlatform.android);

      expect(
        settings.advanced.memoryLimit,
        isFalse,
        reason: 'the Android service has no such cap and the audit asked for '
            'no change there — a shared-code fix must not quietly drop the '
            "fakeip store on the platform that is already device-tested",
      );
    });
  });

  group('§3.2 the default network stack follows the platform', () {
    // SingboxInboundBuilder maps `system` onto sing-box's system stack now, but
    // the *default* the user gets is decided here: `_networkStack` seeds
    // SingboxTunImplementation.gvisor and buildFeatureSettings passes it
    // straight through. A mapping fix alone leaves every iOS install on gvisor
    // unless the user goes and flips the setting by hand — which is not what
    // §3.2 is about: the memory cost is what kills the extension.
    test('iOS defaults to the system stack', () async {
      final settings = await _settingsOn(TargetPlatform.iOS);

      expect(
        settings.inbound.tunImplementation,
        SingboxTunImplementation.system,
        reason: 'gvisor is a userspace Go TCP/IP stack with per-connection '
            'buffers inside a ~50 MB jetsam budget; leaving it as the default '
            'leaves the jetsam kills in place for everyone who never opens '
            'Settings',
      );
    });

    test('Android still defaults to gvisor', () async {
      final settings = await _settingsOn(TargetPlatform.android);

      expect(settings.inbound.tunImplementation,
          SingboxTunImplementation.gvisor,
          reason: 'the shipped, device-tested Android default');
    });
  });

  group('the network-stack picker only offers what the platform has run', () {
    // `system` was inert on both platforms until `_toTunStack` was fixed, so on
    // Android it now names a code path the shipped, device-tested build has
    // never executed. Offering it there would trade "the setting lies" for "the
    // tunnel behaves unfamiliarly" on the platform that is ready to ship.
    test('Android offers gvisor only; iOS offers both', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(ConnectionSettingsController.networkStacks,
          <SingboxTunImplementation>[SingboxTunImplementation.gvisor]);

      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(
        ConnectionSettingsController.networkStacks,
        containsAll(<SingboxTunImplementation>[
          SingboxTunImplementation.system,
          SingboxTunImplementation.gvisor,
        ]),
      );
    });

    test('a stored `system` is coerced back to gvisor on Android', () async {
      // The real regression path: installs that picked "Mixed" while the
      // setting was inert already have `system` on disk. It bypasses the picker
      // completely, so filtering the list alone would have moved exactly those
      // users onto the untested stack — silently, on their next launch.
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      FlutterSecureStorage.setMockInitialValues(<String, String>{
        'conn_network_stack': 'system',
      });

      final controller = ConnectionSettingsController();
      await controller.load();

      expect(controller.networkStack, SingboxTunImplementation.gvisor);
      expect(controller.buildFeatureSettings().inbound.tunImplementation,
          SingboxTunImplementation.gvisor);
    });

    test('the coercion is written back, not just applied in memory', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      FlutterSecureStorage.setMockInitialValues(<String, String>{
        'conn_network_stack': 'system',
      });

      await ConnectionSettingsController().load();

      expect(
        await const FlutterSecureStorage().read(key: 'conn_network_stack'),
        'gvisor',
        reason: 'left on disk, the value would be re-read and re-coerced every '
            'launch — and would take effect the moment Android offers the '
            'option again',
      );
    });

    test('a stored `system` is honoured on iOS', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      FlutterSecureStorage.setMockInitialValues(<String, String>{
        'conn_network_stack': 'system',
      });

      final controller = ConnectionSettingsController();
      await controller.load();

      expect(controller.networkStack, SingboxTunImplementation.system);
    });

    test('a stored `gvisor` is honoured on both', () async {
      for (final platform in <TargetPlatform>[
        TargetPlatform.iOS,
        TargetPlatform.android,
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        FlutterSecureStorage.setMockInitialValues(<String, String>{
          'conn_network_stack': 'gvisor',
        });

        final controller = ConnectionSettingsController();
        await controller.load();

        expect(controller.networkStack, SingboxTunImplementation.gvisor,
            reason: 'an explicit gvisor choice is valid everywhere ($platform)');
      }
    });

    test('the default survives a load on each platform', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      final ios = ConnectionSettingsController();
      await ios.load();
      expect(ios.networkStack, SingboxTunImplementation.system);

      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      final android = ConnectionSettingsController();
      await android.load();
      expect(android.networkStack, SingboxTunImplementation.gvisor);
    });
  });

  group('§2.4 the app never asks for debug-level tunnel logs', () {
    test('neither platform enables debugMode', () async {
      for (final platform in <TargetPlatform>[
        TargetPlatform.iOS,
        TargetPlatform.android,
      ]) {
        final advanced = (await _settingsOn(platform)).advanced;

        expect(advanced.debugMode, isFalse,
            reason: 'at debug level sing-box writes every destination domain '
                'into the stderr tail the support bundle carries ($platform)');
        expect(advanced.logLevel, isNot('debug'), reason: '$platform');
        expect(advanced.logLevel, isNot('trace'), reason: '$platform');
      }
    });
  });

  group('the control-API secret is still the caller\'s to supply', () {
    test('none is invented when the caller passes nothing', () async {
      // VpnController owns the secret because it also has to present it when
      // probing; if the settings layer started minting its own, the probe
      // would authenticate with the wrong one.
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      final controller = ConnectionSettingsController();
      await controller.load();

      expect(controller.buildFeatureSettings().misc.clashApiSecret, isNull);
      expect(
        controller.buildFeatureSettings(clashApiSecret: 'abc').misc
            .clashApiSecret,
        'abc',
      );
    });
  });
}
