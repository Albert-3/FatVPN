import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fatvpn_app/l10n/strings.dart';
import 'package:fatvpn_app/services/home_widget_bridge.dart';
import 'package:singbox_mm/singbox_mm.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('homeWidgetActionFromUri', () {
    test('parses the three widget actions', () {
      expect(
        homeWidgetActionFromUri(Uri.parse('fatvpn://widget/connect')),
        HomeWidgetAction.connect,
      );
      expect(
        homeWidgetActionFromUri(Uri.parse('fatvpn://widget/disconnect')),
        HomeWidgetAction.disconnect,
      );
      expect(
        homeWidgetActionFromUri(Uri.parse('fatvpn://widget/toggle')),
        HomeWidgetAction.toggle,
      );
    });

    test('ignores a key deep link', () {
      // The regression this guards: every fatvpn:// link used to be read as a
      // short token, so a widget tap would have prompted "accept this key?".
      expect(homeWidgetActionFromUri(Uri.parse('fatvpn://token/AB12CD34')), isNull);
    });

    test('ignores an unknown action on the widget host', () {
      // `fatvpn://widget/open` is deliberately not an action: it opens the app
      // and does nothing else, which is what the status half of the widget
      // links to.
      expect(homeWidgetActionFromUri(Uri.parse('fatvpn://widget/open')), isNull);
      expect(homeWidgetActionFromUri(Uri.parse('fatvpn://widget')), isNull);
    });
  });

  group('HomeWidgetSnapshot', () {
    test('serializes dates as epoch milliseconds and states as wire values', () {
      final connectedAt = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      final map = HomeWidgetSnapshot(
        state: VpnConnectionState.connected,
        language: AppLanguage.en,
        signedIn: true,
        locationLabel: 'DE',
        flagEmoji: '🇩🇪',
        connectedAt: connectedAt,
      ).toMap();

      expect(map['v'], HomeWidgetSnapshot.version);
      expect(map['state'], 'connected');
      expect(map['lang'], 'en');
      expect(map['signedIn'], true);
      expect(map['locationLabel'], 'DE');
      expect(map['flagEmoji'], '🇩🇪');
      expect(map['connectedAtMillis'], 1700000000000);
      expect(map['expiresAtMillis'], isNull);
    });

    test('copyWith clears fields only when asked', () {
      final full = HomeWidgetSnapshot(
        locationLabel: 'NL',
        flagEmoji: '🇳🇱',
        connectedAt: DateTime.fromMillisecondsSinceEpoch(1),
      );
      expect(full.copyWith(signedIn: true).locationLabel, 'NL');
      expect(full.copyWith(clearLocation: true).locationLabel, isNull);
      expect(full.copyWith(clearLocation: true).flagEmoji, isNull);
      expect(full.copyWith(clearConnectedAt: true).connectedAt, isNull);
    });
  });

  group('HomeWidgetBridge', () {
    late List<MethodCall> calls;

    setUp(() {
      calls = [];
      HomeWidgetBridge.instance.resetForTest();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(HomeWidgetBridge.channel, (call) async {
        calls.add(call);
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(HomeWidgetBridge.channel, null);
      HomeWidgetBridge.instance.resetForTest();
    });

    test('publishes a patched snapshot and keeps fields it was not given',
        () async {
      await HomeWidgetBridge.instance.update(
        signedIn: true,
        locationLabel: 'DE',
        flagEmoji: '🇩🇪',
      );
      await HomeWidgetBridge.instance.update(state: VpnConnectionState.connected);

      expect(calls.length, 2);
      final last = calls.last.arguments as Map<Object?, Object?>;
      expect(last['state'], 'connected');
      // The state update knew nothing about the location; it must not have
      // blanked it — two publishers own different halves of this snapshot.
      expect(last['locationLabel'], 'DE');
      expect(last['signedIn'], true);
    });

    test('does not republish an unchanged snapshot', () async {
      await HomeWidgetBridge.instance.update(state: VpnConnectionState.connected);
      await HomeWidgetBridge.instance.update(state: VpnConnectionState.connected);
      // The tunnel emits state events in bursts (the reconciliation poll
      // re-reads it once a second); every publish redraws a system widget.
      expect(calls.length, 1);
    });

    test('clearSession wipes the session but keeps the language', () async {
      await HomeWidgetBridge.instance.update(
        state: VpnConnectionState.connected,
        language: AppLanguage.ru,
        signedIn: true,
        locationLabel: 'DE',
        flagEmoji: '🇩🇪',
        connectedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        expiresAt: DateTime.fromMillisecondsSinceEpoch(1800000000000),
      );

      await HomeWidgetBridge.instance.clearSession();

      final last = calls.last.arguments as Map<Object?, Object?>;
      expect(last['signedIn'], false);
      expect(last['state'], 'disconnected');
      expect(last['locationLabel'], isNull);
      expect(last['flagEmoji'], isNull);
      expect(last['connectedAtMillis'], isNull);
      expect(last['expiresAtMillis'], isNull);
      // Kept: the "not signed in" line is drawn in this language.
      expect(last['lang'], 'ru');
    });

    test('a platform without widget support is not retried', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(HomeWidgetBridge.channel, (call) async {
        calls.add(call);
        throw MissingPluginException('no widget implementation here');
      });

      await HomeWidgetBridge.instance.update(state: VpnConnectionState.connected);
      await HomeWidgetBridge.instance.update(state: VpnConnectionState.disconnected);

      expect(calls.length, 1);
    });

    test('a failed publish is retried on the next change', () async {
      var failNext = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(HomeWidgetBridge.channel, (call) async {
        calls.add(call);
        if (failNext) {
          failNext = false;
          throw PlatformException(code: 'BOOM');
        }
        return null;
      });

      await HomeWidgetBridge.instance.update(state: VpnConnectionState.connected);
      // Same snapshot as the failed one: the de-duplication must not swallow it,
      // or a widget would stay wrong until something else changed.
      await HomeWidgetBridge.instance.publish();

      expect(calls.length, 2);
    });
  });
}
