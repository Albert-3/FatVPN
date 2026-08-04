// Regression test for the iOS ≤17 widget button connecting nothing.
//
// One press of the home-screen widget reaches `AuthController._handleUri`
// twice on iOS: the scene delegate parks the URL for `takeLaunchLink` *and*
// still calls `super`, so the engine pushes the same URL as a route into
// `didPushRouteInformation`. The duplicate guard in main.dart covers only the
// route path — it never sees the mailbox arrival — so both deliveries parked a
// toggle. Two toggles are not a no-op: the first starts the connect and flips
// the VPN state to `connecting` synchronously, so the second takes the
// disconnect branch and cancels it. On a real iPhone (iOS 17.6.1) that read
// as: the press buzzes and opens the app, but the VPN never turns on — while
// the disconnect direction kept working, because a connect issued during
// teardown is dropped by the plugin.
//
// Pinned here: the second identical widget action inside the dedup window is
// swallowed at the point every delivery path converges.

import 'package:flutter_test/flutter_test.dart';

import 'package:fatvpn_app/services/auth_controller.dart';
import 'package:fatvpn_app/services/home_widget_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final toggle = Uri.parse('fatvpn://widget/toggle');

  test('the same widget action delivered twice is carried out once', () async {
    final auth = AuthController();

    await auth.handleExternalUri(toggle);
    expect(auth.consumeWidgetAction(), HomeWidgetAction.toggle,
        reason: 'the first delivery must park the action');

    // The second delivery path lands milliseconds later — after the home
    // screen has already consumed and started acting on the first.
    await auth.handleExternalUri(toggle);
    expect(auth.consumeWidgetAction(), isNull,
        reason: 'the echo of the same press must not park a second toggle — '
            'it would cancel the connect the first one just started');
  });

  test('a different action inside the window still goes through', () async {
    final auth = AuthController();

    await auth.handleExternalUri(toggle);
    expect(auth.consumeWidgetAction(), HomeWidgetAction.toggle);

    await auth.handleExternalUri(Uri.parse('fatvpn://widget/disconnect'));
    expect(auth.consumeWidgetAction(), HomeWidgetAction.disconnect,
        reason: 'only an identical action is an echo; a different one is a '
            'new instruction');
  });

  test('the duplicate delivery does not notify listeners', () async {
    final auth = AuthController();
    var notifications = 0;
    auth.addListener(() => notifications++);

    await auth.handleExternalUri(toggle);
    final afterFirst = notifications;
    expect(afterFirst, greaterThan(0),
        reason: 'the first delivery announces the parked action');

    await auth.handleExternalUri(toggle);
    expect(notifications, afterFirst,
        reason: 'a swallowed duplicate must stay silent — a notification '
            'would make the home screen re-consume');
  });
}
