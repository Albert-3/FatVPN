// Regression test for docs/improvement-plan-app-android.md §2.15 —
// "_waitForDisconnected — busy-wait с фиксированным дедлайном, продублирован".
//
// The old version polled `_state` every 150 ms against a 4 s deadline, in two
// copy-pasted places (VpnController and HomeScreen). The deadline expired
// *silently*, so `_performAutoSwitch` went on to connect over a tunnel that was
// still coming down — the very thing the wait exists to prevent — and 4 s is a
// quarter of the service's own teardown budget
// (`VpnCoreServiceCoordinator.RESTART_CLOSE_SUPPRESSION_MS` = 15 s).

import 'dart:async';

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
    // This file awaits initialization inside a `testWidgets` body, where a
    // delay only completes on a pump.
    platform = FakeVpnPlatform(initializeDelay: Duration.zero);
    SignboxVpnPlatform.instance = platform;
    final settings = ConnectionSettingsController();
    await settings.load();
    vpn = VpnController(connectionSettings: settings);
  });

  tearDown(() {
    vpn.dispose();
    platform.dispose();
  });

  testWidgets('returns immediately when the tunnel is already down',
      (tester) async {
    await vpn.syncFromRuntime();

    var returned = false;
    unawaited(vpn.waitForDisconnected().then((_) => returned = true));
    await tester.pump();

    expect(returned, isTrue);
  });

  testWidgets('waits for the event rather than polling a 4 s deadline',
      (tester) async {
    await vpn.syncFromRuntime();
    // Bring it up so the wait has something to wait for.
    platform.states.add(VpnConnectionState.connected);
    await tester.pump();

    var returned = false;
    unawaited(vpn.waitForDisconnected().then((_) => returned = true));

    // Past the old 4 s deadline, and the tunnel is still down-bound: the old
    // busy-wait would have given up here and let the caller reconnect over it.
    await tester.pump(const Duration(seconds: 6));
    expect(returned, isFalse,
        reason: 'the service is allowed up to 15 s to tear down');

    platform.states.add(VpnConnectionState.disconnected);
    await tester.pump();
    expect(returned, isTrue, reason: 'the state event must release the wait');
    // Let the diagnostics capture the drop triggers settle, so the framework's
    // pending-timer check doesn't fire on work this test started.
    await tester.pump(const Duration(seconds: 15));
  });

  testWidgets('gives up eventually instead of hanging forever', (tester) async {
    await vpn.syncFromRuntime();
    platform.states.add(VpnConnectionState.connected);
    await tester.pump();

    var returned = false;
    unawaited(vpn.waitForDisconnected().then((_) => returned = true));

    await tester.pump(const Duration(seconds: 30));
    expect(returned, isTrue,
        reason: 'a tunnel that never reports down must not block the reconnect '
            'path forever');
  });
}
