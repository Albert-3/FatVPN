// A tunnel stopped from *outside* the app is not a tunnel that failed.
//
// The Android service records `STOPPED_BY_USER` as its "last error" when the
// stop came from the notification's Stop button or — now — from the home-screen
// widget's power button. `VpnController` treats an unexpected drop to
// disconnected as a runtime failure and copies that error onto the home screen,
// so before this the user saw a raw `STOPPED_BY_USER` banner for doing exactly
// what the button is for. The plugin itself has always known better (it
// suppresses managed-mode failover on the same marker).

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singbox_mm/singbox_mm.dart';
import 'package:singbox_mm/singbox_mm_platform_interface.dart';

import 'package:fatvpn_app/services/connection_settings_controller.dart';
import 'package:fatvpn_app/services/vpn_controller.dart';

import 'support/fake_vpn_platform.dart';

Future<void> _drop(FakeVpnPlatform platform) async {
  platform.states.add(VpnConnectionState.connected);
  await Future<void>.delayed(const Duration(milliseconds: 20));
  platform.states.add(VpnConnectionState.disconnected);
  await Future<void>.delayed(const Duration(milliseconds: 20));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeVpnPlatform platform;
  late VpnController vpn;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    platform = FakeVpnPlatform();
    SignboxVpnPlatform.instance = platform;
    final settings = ConnectionSettingsController();
    await settings.load();
    vpn = VpnController(connectionSettings: settings);
    await vpn.syncFromRuntime();
  });

  tearDown(() {
    vpn.dispose();
    platform.dispose();
  });

  test('a stop from the widget or the notification shows no error', () async {
    platform.lastError = 'STOPPED_BY_USER';

    await _drop(platform);

    expect(vpn.errorMessage, isNull);
  });

  test('a genuine runtime failure still surfaces', () async {
    platform.lastError = 'tunnel died: connection refused';

    await _drop(platform);

    expect(vpn.errorMessage, contains('connection refused'));
  });
}
