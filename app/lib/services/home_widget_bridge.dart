import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:singbox_mm/singbox_mm.dart';

import '../l10n/strings.dart';
import 'app_logger.dart';

/// What a tap on the widget asked the app to do.
///
/// The widget cannot connect on its own: bringing the tunnel up needs a live
/// entitlement check (`/servers` answers 402 once the subscription lapses), a
/// fresh subscription config and, on a first run, the OS VPN consent dialog —
/// none of which exist outside the app process. So the widget hands the intent
/// over through a deep link and the app performs it.
enum HomeWidgetAction {
  connect,
  disconnect,

  /// "Do the opposite of whatever is running" — what the single power button on
  /// the widget sends when it cannot be sure the state it drew is still current.
  toggle,
}

/// Deep-link host reserved for widget taps. Kept distinct from the key deep
/// link (`fatvpn://token/<code>`, see [AuthController]) because *any* app on the
/// device can fire a `fatvpn://` intent, and a widget action must never be
/// mistaken for a key handed to us by a stranger.
const String homeWidgetLinkHost = 'widget';

/// Parses `fatvpn://widget/<action>`, or null when [uri] is not a widget link.
HomeWidgetAction? homeWidgetActionFromUri(Uri uri) {
  if (uri.host != homeWidgetLinkHost) return null;
  return homeWidgetActionFromName(
    uri.pathSegments.isEmpty ? '' : uri.pathSegments.last,
  );
}

/// The same action names as the deep link, arriving the other way round: a
/// platform that can wake the app but cannot hand it a URL parks the name
/// instead, and the app comes and takes it
/// ([HomeWidgetBridge.takePendingAction]).
HomeWidgetAction? homeWidgetActionFromName(String action) {
  switch (action) {
    case 'connect':
      return HomeWidgetAction.connect;
    case 'disconnect':
      return HomeWidgetAction.disconnect;
    case 'toggle':
      return HomeWidgetAction.toggle;
    default:
      return null;
  }
}

/// Everything the home-screen widgets draw.
///
/// Deliberately small and flat: it crosses a platform channel on every tunnel
/// state change and is then re-read by a widget process that may run long after
/// the app is gone, so it holds display-ready values rather than references to
/// app state.
@immutable
class HomeWidgetSnapshot {
  const HomeWidgetSnapshot({
    this.state = VpnConnectionState.disconnected,
    this.language = AppLanguage.ru,
    this.signedIn = false,
    this.locationLabel,
    this.flagEmoji,
    this.connectedAt,
    this.expiresAt,
  });

  /// Bumped when the shape below changes, so a widget left over from an older
  /// install renders its fallback instead of misreading fields.
  static const int version = 1;

  final VpnConnectionState state;
  final AppLanguage language;

  /// False when there is no session at all: the widget then offers "open the
  /// app" rather than a power button that could only ever fail.
  final bool signedIn;

  /// Country label as the home screen shows it ("DE", or the localized
  /// "whitelist" bucket) — null in "best server" mode, where the widget draws
  /// its own localized label instead of a location that isn't chosen yet.
  final String? locationLabel;
  final String? flagEmoji;

  /// Start of the running session, mirrored so the widget can tick its own
  /// clock without waking the app. Null when not connected.
  final DateTime? connectedAt;
  final DateTime? expiresAt;

  HomeWidgetSnapshot copyWith({
    VpnConnectionState? state,
    AppLanguage? language,
    bool? signedIn,
    String? locationLabel,
    String? flagEmoji,
    DateTime? connectedAt,
    DateTime? expiresAt,
    bool clearLocation = false,
    bool clearConnectedAt = false,
    bool clearExpiresAt = false,
  }) {
    return HomeWidgetSnapshot(
      state: state ?? this.state,
      language: language ?? this.language,
      signedIn: signedIn ?? this.signedIn,
      locationLabel: clearLocation ? null : (locationLabel ?? this.locationLabel),
      flagEmoji: clearLocation ? null : (flagEmoji ?? this.flagEmoji),
      connectedAt: clearConnectedAt ? null : (connectedAt ?? this.connectedAt),
      expiresAt: clearExpiresAt ? null : (expiresAt ?? this.expiresAt),
    );
  }

  Map<String, Object?> toMap() => <String, Object?>{
        'v': version,
        'state': state.wireValue,
        'lang': language == AppLanguage.ru ? 'ru' : 'en',
        'signedIn': signedIn,
        'locationLabel': locationLabel,
        'flagEmoji': flagEmoji,
        // Milliseconds since epoch, not ISO strings: both widget runtimes work
        // in absolute time (Android's Chronometer, SwiftUI's timer style) and
        // neither should be parsing dates.
        'connectedAtMillis': connectedAt?.millisecondsSinceEpoch,
        'expiresAtMillis': expiresAt?.millisecondsSinceEpoch,
      };

  @override
  bool operator ==(Object other) =>
      other is HomeWidgetSnapshot &&
      other.state == state &&
      other.language == language &&
      other.signedIn == signedIn &&
      other.locationLabel == locationLabel &&
      other.flagEmoji == flagEmoji &&
      other.connectedAt == connectedAt &&
      other.expiresAt == expiresAt;

  @override
  int get hashCode => Object.hash(
        state,
        language,
        signedIn,
        locationLabel,
        flagEmoji,
        connectedAt,
        expiresAt,
      );
}

/// Publishes [HomeWidgetSnapshot] to the platform so the Android app widget can
/// render the session without the app running.
///
/// A single instance owns the whole snapshot and callers patch the fields they
/// know about ([update]) — the home screen knows the tunnel, `main` knows the
/// session and the language, and neither should be able to blank the other's
/// half by publishing a partial record.
class HomeWidgetBridge {
  HomeWidgetBridge._();

  static final HomeWidgetBridge instance = HomeWidgetBridge._();

  @visibleForTesting
  static const MethodChannel channel = MethodChannel('fatvpn/widget');

  HomeWidgetSnapshot _snapshot = const HomeWidgetSnapshot();
  HomeWidgetSnapshot? _published;

  /// True once the platform side has told us it has no widget code (desktop and
  /// web builds share this Dart). Stops us logging the same miss forever.
  bool _unsupported = false;

  HomeWidgetSnapshot get snapshot => _snapshot;

  @visibleForTesting
  void resetForTest() {
    _snapshot = const HomeWidgetSnapshot();
    _published = null;
    _unsupported = false;
    onActionAvailable = null;
    channel.setMethodCallHandler(null);
  }

  /// Patches the snapshot and pushes it to the platform when something actually
  /// changed. Every argument is optional; omitting one leaves it as it was.
  Future<void> update({
    VpnConnectionState? state,
    AppLanguage? language,
    bool? signedIn,
    String? locationLabel,
    String? flagEmoji,
    DateTime? connectedAt,
    DateTime? expiresAt,
    bool clearLocation = false,
    bool clearConnectedAt = false,
    bool clearExpiresAt = false,
  }) {
    _snapshot = _snapshot.copyWith(
      state: state,
      language: language,
      signedIn: signedIn,
      locationLabel: locationLabel,
      flagEmoji: flagEmoji,
      connectedAt: connectedAt,
      expiresAt: expiresAt,
      clearLocation: clearLocation,
      clearConnectedAt: clearConnectedAt,
      clearExpiresAt: clearExpiresAt,
    );
    return publish();
  }

  /// Wipes everything about the session the widget could still be showing — the
  /// location, the clock, the subscription — while keeping the language, which
  /// is what the "not signed in" line is drawn in.
  ///
  /// Called when the session goes away (sign-out, or a subscription that
  /// lapsed). A widget still naming the last country and counting a session
  /// timer would be both wrong and a small leak from an account that is no
  /// longer signed in on this device.
  Future<void> clearSession({AppLanguage? language}) => update(
        state: VpnConnectionState.disconnected,
        language: language,
        signedIn: false,
        clearLocation: true,
        clearConnectedAt: true,
        clearExpiresAt: true,
      );

  /// Called when the platform says a widget tap is waiting to be collected —
  /// see [listenForActions].
  VoidCallback? onActionAvailable;

  /// Listens for taps the platform parks while this app is already running.
  ///
  /// The poll ([takePendingAction] on launch and on resume) cannot be the only
  /// path on iOS. The power button is an App Intent performed **in this
  /// process**, and on iOS 17 the system performs it *after* the app it opened
  /// is already active — i.e. after both polls have run. Without this the press
  /// would sit in the App Group until the user backgrounded and reopened the
  /// app, which is a button that does nothing as far as anyone pressing it is
  /// concerned.
  void listenForActions() {
    channel.setMethodCallHandler((call) async {
      if (call.method != 'actionAvailable') {
        throw MissingPluginException();
      }
      onActionAvailable?.call();
      return null;
    });
  }

  /// Drains the native trace of the last widget press into the app's log.
  ///
  /// The press runs with no UI and no console reachable from the device, so
  /// this is the only record of a press whose process died, or whose intent the
  /// system never routed anywhere. Read once and cleared natively, so a trace is
  /// reported against exactly one launch.
  Future<void> reportPressTrail() async {
    if (_unsupported) return;
    try {
      final trail = await channel.invokeListMethod<String>('takeBreadcrumbs');
      if (trail == null || trail.isEmpty) return;
      for (final step in trail) {
        log.i('Widget press: $step');
      }
    } on MissingPluginException {
      // A platform whose widget leaves no trail (Android writes none — its
      // press lands in a broadcast receiver that can log for itself).
    } catch (e) {
      log.w('Could not read the widget press trail: $e');
    }
  }

  /// Takes the `fatvpn://` URL the platform is holding for us, leaving nothing
  /// behind. Null when there is none.
  ///
  /// This is how a link reaches the app when the link is what *started* it.
  /// Flutter's own delivery is a race there: `defaultRouteName` does not carry
  /// the URL on iOS, and the push through `didPushRouteInformation` happens
  /// while the Dart isolate is still booting, with nothing listening yet. The
  /// simulator smoke test measured it — a cold `fatvpn://widget/toggle` arrived
  /// nowhere at all.
  ///
  /// So the native side records every open and holds it; this reads it on
  /// launch and on every resume. Android answers null: its widget delivers taps
  /// through its own intent, and its deep links arrive the ordinary way.
  Future<Uri?> takeLaunchLink() async {
    if (_unsupported) return null;
    try {
      final raw = await channel.invokeMethod<String>('takeLaunchLink');
      if (raw == null || raw.isEmpty) return null;
      return Uri.tryParse(raw);
    } on MissingPluginException {
      return null;
    } catch (e) {
      log.w('Could not read the launch link: $e');
      return null;
    }
  }

  /// Takes the action a widget tap parked with the platform, leaving nothing
  /// behind. Null when there is none.
  ///
  /// This is how an iOS press arrives: the power button is an App Intent, which
  /// may ask the system to open its app but cannot hand that app a URL, so the
  /// request is left in the shared App Group and collected here. The Android
  /// widget delivers its taps as `fatvpn://widget/...` links and parks nothing,
  /// so this answers null there.
  Future<HomeWidgetAction?> takePendingAction() async {
    if (_unsupported) return null;
    try {
      final name = await channel.invokeMethod<String>('takePendingAction');
      if (name == null || name.isEmpty) return null;
      // The press's own haptic, and the only one it gets on iOS 17.
      //
      // There the power button opens the app rather than working in the
      // background, and the native side deliberately stays silent: a widget
      // extension has no vibromotor at all, and the app's own process has no
      // usable one until it is actually in front of the user — which is exactly
      // now. The iOS 18 press never reaches this line: it is served entirely in
      // the background and buzzes there instead.
      unawaited(HapticFeedback.mediumImpact());
      return homeWidgetActionFromName(name);
    } on MissingPluginException {
      // An older platform build (or a desktop one) that only knows `publish`.
      // Deliberately does not set [_unsupported]: publishing may well work, and
      // a widget that stops updating is a much bigger loss than a tap that has
      // to arrive by deep link.
      return null;
    } catch (e) {
      log.w('Could not read the pending widget action: $e');
      return null;
    }
  }

  /// Sends the current snapshot to the platform, unless it is byte-for-byte
  /// what we sent last time.
  ///
  /// The de-duplication is not cosmetic: the tunnel emits state events in
  /// bursts (the reconciliation poll re-reads it once a second while a
  /// handshake settles), and every publish redraws a system widget.
  Future<void> publish() async {
    if (_unsupported) return;
    final snapshot = _snapshot;
    if (snapshot == _published) return;
    try {
      await channel.invokeMethod<void>('publish', snapshot.toMap());
      _published = snapshot;
    } on MissingPluginException {
      // No widget implementation on this platform (desktop/web) — nothing is
      // broken, there is simply nothing to draw.
      _unsupported = true;
    } catch (e) {
      // A widget that fails to update is never worth an error on screen; the
      // next state change publishes again. Deliberately does not remember the
      // failed snapshot as published, so that retry actually happens.
      log.w('Could not publish widget snapshot: $e');
    }
  }
}
