// Regression test for docs/improvement-plan-app-android.md §2.3 —
// "Гонка в VpnController._ensureInitialized → дублирующая подписка".
//
// `_ensureInitialized` checks `_initialized` and only sets it two `await`s
// later. HomeScreen genuinely enters it twice concurrently (`syncFromRuntime()`
// on line 81 and `_loadServers() → _autoConnect() → _connect()` on line 82), so
// the second pass re-runs `initialize()` and calls `stateStream.listen` again.
// `stateStream` is a broadcast stream, so that is a *second* subscription while
// `_stateSubscription` keeps only the last one: the first leaks past dispose()
// and every state event is handled twice (session-start tracking, failure
// capture, self-heal).

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singbox_mm/singbox_mm.dart';
import 'package:singbox_mm/singbox_mm_platform_interface.dart';

import 'package:fatvpn_app/services/connection_settings_controller.dart';
import 'package:fatvpn_app/services/vpn_controller.dart';

import 'support/fake_vpn_platform.dart';

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
  });

  tearDown(() {
    vpn.dispose();
    platform.dispose();
  });

  test('two concurrent initializations produce one initialize and one listener',
      () async {
    await Future.wait(<Future<void>>[
      vpn.syncFromRuntime(),
      vpn.syncFromRuntime(),
    ]);

    expect(platform.initializeCalls, 1,
        reason: 'the second caller must await the first, not re-run init');
    expect(platform.stateStreamReads, 1,
        reason: 'a second listen leaks the first subscription past dispose() '
            'and doubles every state event');
  });

  test('three concurrent initializations are still one', () async {
    await Future.wait(<Future<void>>[
      vpn.syncFromRuntime(),
      vpn.syncFromRuntime(),
      vpn.syncFromRuntime(),
    ]);

    expect(platform.initializeCalls, 1);
    expect(platform.stateStreamReads, 1);
  });

  test('a later call reuses the completed initialization', () async {
    await vpn.syncFromRuntime();
    await vpn.syncFromRuntime();

    expect(platform.initializeCalls, 1);
    expect(platform.stateStreamReads, 1);
  });

  test('each state event is handled exactly once', () async {
    await Future.wait(<Future<void>>[
      vpn.syncFromRuntime(),
      vpn.syncFromRuntime(),
    ]);

    var notifications = 0;
    vpn.addListener(() => notifications++);
    platform.states.add(VpnConnectionState.connecting);
    // Let the broadcast reach every subscriber there is.
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(notifications, 1,
        reason: 'a duplicate subscription runs _trackSessionStart, '
            '_captureTunnelFailure and _maybeSelfHeal twice per event');
  });
}
