// The session a widget press starts without the app.
//
// On iOS the widget's power button performs in the widget extension's own
// process and drives NETunnelProviderManager natively. There is no Flutter
// there, so `VpnController.connect` — the one place a session is anchored —
// never runs, and the app opening onto that tunnel used to show the clock of
// whatever session it last watched: the reporter's screen recording of an
// iPhone 15 (2026-08-04) has the home screen reading `00:00:46` over a tunnel
// that had been up for seven seconds.
//
// The press now leaves its start in the App Group and the app collects it on
// the next reconciliation. What has to hold, and is asserted below:
//
//   · a marked start that is newer than the one on disk replaces it;
//   · a marker is spent once — a second reconciliation must not re-anchor;
//   · an older marker is ignored, so an in-app connect that deliberately
//     continues a session (a server switch, `endSession: false`) cannot be
//     overruled by a press that happened before it;
//   · a platform that answers nothing (Android, or a build without the call)
//     changes nothing at all.

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singbox_mm/singbox_mm.dart';
import 'package:singbox_mm/singbox_mm_platform_interface.dart';

import 'package:fatvpn_app/services/connection_settings_controller.dart';
import 'package:fatvpn_app/services/home_widget_bridge.dart';
import 'package:fatvpn_app/services/vpn_controller.dart';

import 'support/fake_vpn_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeVpnPlatform platform;
  late ConnectionSettingsController settings;
  late VpnController vpn;

  /// What the native side is holding for us, and how often it was asked.
  DateTime? marked;
  var takes = 0;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    platform = FakeVpnPlatform();
    SignboxVpnPlatform.instance = platform;
    settings = ConnectionSettingsController();
    await settings.load();
    marked = null;
    takes = 0;
    HomeWidgetBridge.instance.resetForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(HomeWidgetBridge.channel, (call) async {
      if (call.method != 'takeNativeSessionStart') return null;
      takes++;
      final at = marked;
      // Read once and cleared, exactly as the App Group copy is.
      marked = null;
      return at?.millisecondsSinceEpoch;
    });
    vpn = VpnController(connectionSettings: settings);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(HomeWidgetBridge.channel, null);
    HomeWidgetBridge.instance.resetForTest();
    vpn.dispose();
    platform.dispose();
  });

  test('the app adopts the session the widget press started', () async {
    final stale = DateTime.now().subtract(const Duration(minutes: 40));
    await FlutterSecureStorage().write(
      key: 'vpn_session_started_at',
      value: stale.toIso8601String(),
    );
    // Millisecond precision on purpose: the marker crosses the channel as
    // epoch milliseconds, which is all the App Group copy keeps.
    final pressedAt = DateTime.fromMillisecondsSinceEpoch(
        DateTime.now().millisecondsSinceEpoch - 7000);
    marked = pressedAt;
    platform.reportedState = VpnConnectionState.connected;

    await vpn.syncFromRuntime();

    expect(vpn.sessionStartedAt, pressedAt,
        reason: 'the tunnel on screen is the one the press raised seven '
            'seconds ago, not the session that ended 40 minutes ago');
  });

  test('a marker is spent once', () async {
    marked = DateTime.now().subtract(const Duration(seconds: 5));
    platform.reportedState = VpnConnectionState.connected;

    await vpn.syncFromRuntime();
    final adopted = vpn.sessionStartedAt;
    await vpn.syncFromRuntime();

    expect(takes, 2, reason: 'every reconciliation asks');
    expect(vpn.sessionStartedAt, adopted,
        reason: 'a second resume must not re-anchor the clock to the same '
            'press — the session is already running');
  });

  test('a start older than the running session is ignored', () async {
    final running = DateTime.now().subtract(const Duration(minutes: 2));
    await FlutterSecureStorage().write(
      key: 'vpn_session_started_at',
      value: running.toIso8601String(),
    );
    marked = running.subtract(const Duration(minutes: 5));
    platform.reportedState = VpnConnectionState.connected;

    await vpn.syncFromRuntime();

    expect(vpn.sessionStartedAt, running,
        reason: 'a stale marker must never drag the clock backwards — an '
            'in-app reconnect that kept the session on purpose would lose it');
  });

  test('a platform that holds nothing leaves the clock alone', () async {
    final running = DateTime.now().subtract(const Duration(minutes: 3));
    await FlutterSecureStorage().write(
      key: 'vpn_session_started_at',
      value: running.toIso8601String(),
    );
    platform.reportedState = VpnConnectionState.connected;

    await vpn.syncFromRuntime();

    expect(vpn.sessionStartedAt, running);
  });
}
