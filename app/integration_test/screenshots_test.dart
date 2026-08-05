// Store-listing screenshots, driven through the real app against the real BFF.
// Runs on an iOS simulator (see the ios-screenshots workflow): authenticates
// with the App Review demo key, then walks the screens the listing shows.
// The tunnel itself cannot start in a simulator (no NetworkExtension), so every
// shot is of the disconnected-but-signed-in app — which is also the state a
// first-time viewer of the listing will meet.
//
// Finders use the app's own string tables (ruStrings/enStrings), so the test
// survives locale switches and wording edits alike.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fatvpn_app/main.dart' as app;
import 'package:fatvpn_app/l10n/strings.dart';

const _demoKey = String.fromEnvironment('DEMO_KEY');

/// Pumps frames for [d] without demanding the tree settles — spinners and
/// looping animations make pumpAndSettle a deadlock, not a wait.
Future<void> _pumpFor(WidgetTester t, Duration d) async {
  final end = DateTime.now().add(d);
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// Polls for [f] to appear; fails the test with [what] after [timeout].
Future<void> _waitFor(WidgetTester t, Finder f, String what,
    {Duration timeout = const Duration(seconds: 45)}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 200));
    if (f.evaluate().isNotEmpty) return;
  }
  fail('Timed out waiting for $what');
}

/// Matches a Text carrying either locale's variant of a string. A predicate
/// rather than a resolved find.text, so the finder stays valid for
/// scrollUntilVisible, which must re-evaluate it after every scroll.
Finder _text(String Function(Strings) pick) => find.byWidgetPredicate(
      (w) => w is Text && (w.data == pick(ruStrings) || w.data == pick(enStrings)),
    );

/// Asks the shell side to take the shot and holds still while it does.
///
/// Not binding.takeScreenshot: that captures the Flutter surface alone, so
/// every shot came back with an empty status bar — no clock, no battery, which
/// on a store listing reads as a broken mock-up. The workflow watches this
/// marker on stdout and fires `simctl io screenshot`, which captures the whole
/// device including the status bar the workflow pinned to 9:41.
Future<void> _shot(WidgetTester t, String name) async {
  debugPrint('SHOT:$name');
  await _pumpFor(t, const Duration(seconds: 5));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('store screenshots', (t) async {
    expect(_demoKey, isNotEmpty,
        reason: 'pass --dart-define=DEMO_KEY=... to flutter drive');

    app.main();
    // Splash → onboarding. Generous first wait: a debug build on a freshly
    // booted CI simulator takes tens of seconds to warm up.
    await _pumpFor(t, const Duration(seconds: 8));
    await _waitFor(t, _text((s) => s.haveKeyTitle), 'the onboarding screen',
        timeout: const Duration(seconds: 60));
    await _pumpFor(t, const Duration(seconds: 1));
    await _shot(t, '01-onboarding');

    // Paste the demo key and sign in.
    await t.tap(_text((s) => s.haveKeyTitle));
    await _pumpFor(t, const Duration(seconds: 1));
    await t.enterText(find.byType(TextField).last, _demoKey);
    await _pumpFor(t, const Duration(milliseconds: 300));
    await t.testTextInput.receiveAction(TextInputAction.done);

    // Home is recognizable by its power button.
    final power = find.byIcon(Icons.power_settings_new);
    await _waitFor(t, power, 'the home screen');
    // Signing in auto-connects, and a simulator has no NetworkExtension, so the
    // attempt dies with "VPN permission denied by user" in red — which must not
    // ship on a store listing. A fresh connect clears the message
    // (VpnController._connect resets it on entry) and a second press asks to
    // stop, landing back on a clean "Отключено". Let the failure happen first,
    // or the tap races it and the error reappears afterwards.
    await _pumpFor(t, const Duration(seconds: 8));
    await t.tap(power);
    await _pumpFor(t, const Duration(seconds: 2));
    await t.tap(power);
    // Long enough for the server list to land, so the card names a location.
    await _pumpFor(t, const Duration(seconds: 8));
    await _shot(t, '02-home');

    // Server list: the home card opens it; the chevron is its tap affordance.
    await t.tap(find.byIcon(Icons.chevron_right).first);
    await _pumpFor(t, const Duration(seconds: 8)); // pings settle
    await _shot(t, '03-servers');
    // Not pageBack(): the screen's back affordance is custom-drawn, and the
    // finder behind pageBack() sees neither a Material nor a Cupertino button.
    t.state<NavigatorState>(find.byType(Navigator).last).pop();
    await _pumpFor(t, const Duration(seconds: 1));

    // Settings, scrolled past the account card. That card prints the key code
    // in full, and the key here is the App Review demo key — a listing
    // screenshot would publish working credentials. Below it sits the part
    // worth showing anyway: DNS, network stack, tracker protection.
    await t.tap(find.byIcon(Icons.settings));
    await _pumpFor(t, const Duration(seconds: 2));
    await t.drag(find.byType(Scrollable).first, const Offset(0, -420));
    await _pumpFor(t, const Duration(seconds: 1));
    await _shot(t, '04-settings');

    // Split tunneling, opened from settings. The entry sits below the fold of
    // a ListView, whose off-screen children are never built — so it has to be
    // scrolled to before it can be found, not merely ensured visible.
    final split = _text((s) => s.splitTunnelingSettings);
    await t.scrollUntilVisible(split, 200,
        scrollable: find.byType(Scrollable).first);
    await _pumpFor(t, const Duration(milliseconds: 500));
    await t.tap(split.first);
    await _pumpFor(t, const Duration(seconds: 3));
    await _shot(t, '05-split-tunneling');
  });
}
