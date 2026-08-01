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

  test('the published payload carries nulls, and the platform must survive them',
      () {
    // This is a contract test, not a style one. A session with no location
    // picked and no clock running publishes null for four of its eight fields,
    // and on iOS those cross the channel as NSNull — which UserDefaults refuses
    // with an ObjC exception no Swift code can catch. Build 205 died on exactly
    // that, on its first publish, before a screen appeared; the guard now lives
    // in FatVpnWidgetStore.plistSafe.
    //
    // So: if this ever stops emitting nulls, that guard has lost its reason to
    // exist and someone should be told, rather than finding out from a crash
    // report a build later.
    final map = const HomeWidgetSnapshot(signedIn: true).toMap();

    expect(map['locationLabel'], isNull);
    expect(map['flagEmoji'], isNull);
    expect(map['connectedAtMillis'], isNull);
    expect(map['expiresAtMillis'], isNull);
    // And the keys are present rather than omitted — which is what makes the
    // values reach the platform at all.
    expect(
      map.keys,
      containsAll(<String>[
        'locationLabel',
        'flagEmoji',
        'connectedAtMillis',
        'expiresAtMillis',
      ]),
    );
  });

  group('a press the platform parked', () {
    late List<MethodCall> calls;
    late List<MethodCall> platformCalls;

    setUp(() {
      calls = [];
      platformCalls = [];
      HomeWidgetBridge.instance.resetForTest();
      // HapticFeedback goes out over SystemChannels.platform, so the buzz is
      // observable without a device.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        platformCalls.add(call);
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        ..setMockMethodCallHandler(HomeWidgetBridge.channel, null)
        ..setMockMethodCallHandler(SystemChannels.platform, null);
      HomeWidgetBridge.instance.resetForTest();
    });

    void mockPlatform(Future<Object?> Function(MethodCall) reply) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(HomeWidgetBridge.channel, (call) async {
        calls.add(call);
        return reply(call);
      });
    }

    test('a collected action buzzes, because iOS 17 has no other chance to',
        () async {
      // The whole point of the split: on iOS 17 the press opens the app and the
      // native side stays silent — a widget extension has no vibromotor, and the
      // app's process has no usable one until it is in front of the user, which
      // is this moment. If this buzz goes, that press has none at all.
      mockPlatform((call) async => call.method == 'takePendingAction' ? 'toggle' : null);

      expect(await HomeWidgetBridge.instance.takePendingAction(),
          HomeWidgetAction.toggle);
      expect(
        platformCalls.map((c) => c.arguments),
        contains('HapticFeedbackType.mediumImpact'),
      );
    });

    test('nothing parked, nothing buzzes', () async {
      // takePendingAction is polled on every resume. A buzz on an empty poll
      // would have the phone tick each time the user came back to the app.
      mockPlatform((call) async => null);

      expect(await HomeWidgetBridge.instance.takePendingAction(), isNull);
      expect(platformCalls, isEmpty);
    });

    test('the platform can announce a press the app is already running for',
        () async {
      // The listener half. The poll alone misses the press made while the app is
      // alive: on iOS the intent runs in this very process, *after* the resume
      // callback has already polled.
      mockPlatform((call) async => null);
      var announced = 0;
      HomeWidgetBridge.instance.onActionAvailable = () => announced++;
      HomeWidgetBridge.instance.listenForActions();

      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        HomeWidgetBridge.channel.name,
        HomeWidgetBridge.channel.codec
            .encodeMethodCall(const MethodCall('actionAvailable')),
        (_) {},
      );

      expect(announced, 1);
    });

    test('the native press trail is drained once', () async {
      // Read once and cleared natively; this only checks that the app asks, and
      // asks before it takes the action — the trail narrates the very launch
      // that is collecting it.
      mockPlatform((call) async {
        if (call.method == 'takeBreadcrumbs') return <String>['press → app copy'];
        return null;
      });

      await HomeWidgetBridge.instance.reportPressTrail();

      expect(calls.map((c) => c.method), ['takeBreadcrumbs']);
    });

    test('a platform with no trail to give is not an error', () async {
      // Android writes none: its press lands in a broadcast receiver that logs
      // for itself.
      mockPlatform((call) async => throw MissingPluginException('no trail here'));

      await HomeWidgetBridge.instance.reportPressTrail();

      expect(calls.map((c) => c.method), ['takeBreadcrumbs']);
    });
  });
}
