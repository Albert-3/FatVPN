import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'config/api_config.dart';
import 'l10n/app_localizations.dart';
import 'screens/awaiting_auth_screen.dart';
import 'screens/home_screen.dart';
import 'screens/splash_screen.dart';
import 'services/app_logger.dart';
import 'services/auth_controller.dart';
import 'services/connection_settings_controller.dart';
import 'services/home_widget_bridge.dart';
import 'services/locale_controller.dart';
import 'services/notification_service.dart';
import 'services/widget_connect_runner.dart';
import 'theme/app_colors.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Open the on-disk log file early so the whole session is captured. Runs in
  // the background — startup never blocks on it (lines buffer until it opens).
  AppLogger.instance.init();
  // Route framework and uncaught platform errors into the diagnostics log so
  // they land in the support bundle instead of only the debug console. Both
  // preserve default behaviour (rethrow / present the error) after logging.
  final previousOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    log.e('FlutterError: ${details.exceptionAsString()}', null, details.stack);
    previousOnError?.call(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    log.e('Uncaught platform error', error, stack);
    return false;
  };
  log.i('App started (${kReleaseMode ? 'release' : 'debug'})');
  _registerWidgetConnectHost();
  // Lock the app to portrait — the UI is designed for vertical phones only.
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const FatVpnApp());
}

/// Lets the iOS widget's power button run its connect **on this engine**.
///
/// The button's intent is performed in the app's process, which the system
/// launches whole — so by the time the intent wants a connect, this engine is
/// already booting right beside it, and spawning a second (headless) engine in
/// the same background process is a race this process cannot report losing.
/// The native side (`FatVpnWidgetAppToggle.runOnMainEngine`) calls `run` here
/// and falls back to the headless `widgetConnectMain` only if this handler
/// never appears. Registered on Android too, where it simply is never called —
/// `WidgetConnectService` owns its own engine there by design (the app process
/// is usually not running at all when an Android widget button is pressed).
void _registerWidgetConnectHost() {
  const channel = MethodChannel('fatvpn/widget_connect_host');
  Future<String>? inFlight;
  channel.setMethodCallHandler((call) async {
    if (call.method != 'run') {
      throw MissingPluginException();
    }
    // A second press joins the run already going, exactly as the native side
    // coalesces — two runners over one tunnel is never what a double-tap means.
    inFlight ??= () async {
      log.i('Widget connect: running on the app engine');
      var outcome = WidgetConnectOutcome.failed;
      try {
        outcome = await WidgetConnectRunner().run();
      } catch (e, stack) {
        log.e('Widget connect: unhandled failure (app engine)', e, stack);
      }
      log.i('Widget connect: ${outcome.name} (app engine)');
      await AppLogger.instance.flush();
      return outcome.name;
    }()
        .whenComplete(() => inFlight = null);
    return inFlight;
  });
}

/// Second entrypoint of the app: the tunnel being brought up from a tap on the
/// home-screen widget's power button, with no UI anywhere in the process.
///
/// Started by name from `WidgetConnectService` in a background Flutter engine.
/// Deliberately lives in this file, next to [main], and not in a library of its
/// own: the compiler builds the program from the root library outwards, and an
/// entrypoint nothing imports would simply not be in a release snapshot for the
/// engine to find. `vm:entry-point` then keeps the function itself, which is
/// otherwise dead code — nothing in Dart calls it.
///
/// No `runApp`: this engine has no window and no Activity. It does what the
/// home screen's power button does and then goes away — see
/// [WidgetConnectRunner] for why it re-checks the entitlement rather than
/// starting from the config the last session left on disk.
@pragma('vm:entry-point')
Future<void> widgetConnectMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppLogger.instance.init();
  log.i('Widget connect: engine started');
  var outcome = WidgetConnectOutcome.failed;
  try {
    outcome = await WidgetConnectRunner().run();
  } catch (e, stack) {
    // Nothing may escape: an unhandled error here leaves the native service
    // waiting for a verdict that never arrives, and the widget stuck on
    // "Connecting…" until its optimism window runs out.
    log.e('Widget connect: unhandled failure', e, stack);
  }
  log.i('Widget connect: ${outcome.name}');
  await AppLogger.instance.flush();
  try {
    await widgetConnectChannel.invokeMethod<void>('finished', outcome.name);
  } catch (e) {
    log.w('Widget connect: could not report the outcome ($e)');
  }
}

class FatVpnApp extends StatefulWidget {
  const FatVpnApp({super.key});

  @override
  State<FatVpnApp> createState() => _FatVpnAppState();
}

class _FatVpnAppState extends State<FatVpnApp> with WidgetsBindingObserver {
  final _auth = AuthController();
  final _locale = LocaleController();
  final _connectionSettings = ConnectionSettingsController();
  final _notifications = NotificationService();
  // Needed to raise the deep-link confirmation over whatever screen is up: the
  // link can arrive at any moment, from onboarding or from Home.
  final _navigatorKey = GlobalKey<NavigatorState>();
  bool _deepLinkPromptOpen = false;

  // Holds the animated splash for a minimum beat so it plays fully even when
  // the stored session resolves instantly. Flips true after [_minSplashTime].
  bool _minSplashElapsed = false;
  static const _minSplashTime = Duration(milliseconds: 1400);

  // The engine regularly delivers the same launch URL twice within a second
  // (both arrivals were visible in the build-197 bundle as the double
  // null-check crash) — and a toggle carried out twice is a connect
  // immediately undone.
  Uri? _lastRouteUri;
  DateTime? _lastRouteUriAt;

  /// iOS delivery path for `fatvpn://` links: the engine's own deep-link
  /// channel, claimed here before `WidgetsApp` can push the URL as a named
  /// route the app does not define (that was the caught null-check crash all
  /// over the build-197 bundle). This observer is registered before
  /// `WidgetsApp`'s, so returning true stops the dispatch there.
  ///
  /// It has to be this channel because the obvious one is broken: app_links —
  /// which Android relies on and iOS was assumed to share — was proven by the
  /// build-199 bundle to deliver nothing on the scene-based iOS template (the
  /// app opened from the widget's tap URL with no 'Deep link arrived' line),
  /// while the engine's channel demonstrably carries the URL end-to-end into
  /// Dart on a device. Android is untouched: `flutter_deeplinking_enabled` is
  /// false in its manifest, so nothing arrives here.
  @override
  Future<bool> didPushRouteInformation(RouteInformation routeInformation) async {
    final uri = _deepLinkFromRoute(routeInformation.uri);
    if (uri == null) {
      return super.didPushRouteInformation(routeInformation);
    }
    final now = DateTime.now();
    final duplicate = _lastRouteUri == uri &&
        _lastRouteUriAt != null &&
        now.difference(_lastRouteUriAt!) < const Duration(seconds: 2);
    _lastRouteUri = uri;
    _lastRouteUriAt = now;
    if (duplicate) {
      log.i('Deep link (route) duplicate ignored');
      return true;
    }
    await _auth.handleExternalUri(uri);
    return true;
  }

  /// Recognizes a `fatvpn://` link in whichever shape the engine pushed it —
  /// the full URL, or stripped down to its path (`widget/toggle`). Which shape
  /// arrives is undocumented and not worth a build cycle to find out; the
  /// namespace guard (only `widget/...` and `token/...`) keeps an ordinary
  /// route push, like the initial "/", out of the deep-link path either way.
  Uri? _deepLinkFromRoute(Uri uri) {
    if (uri.scheme == deepLinkScheme) return uri;
    if (uri.scheme.isNotEmpty) return null;
    final segments = uri.pathSegments;
    if (segments.length < 2) return null;
    const deepLinkHosts = {homeWidgetLinkHost, 'token'};
    if (!deepLinkHosts.contains(segments.first)) return null;
    return Uri(
      scheme: deepLinkScheme,
      host: segments.first,
      pathSegments: segments.skip(1),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Future.delayed(_minSplashTime, () {
      if (mounted) setState(() => _minSplashElapsed = true);
    });
    // Re-plan local expiry reminders whenever the session (expiry) or the
    // language changes. syncFor no-ops until init() completes, then the first
    // sync runs once init resolves.
    _auth.addListener(_syncNotifications);
    _auth.addListener(_maybePromptForDeepLinkKey);
    _auth.addListener(_syncHomeWidget);
    _locale.addListener(_syncNotifications);
    _locale.addListener(_syncHomeWidget);
    _auth.start();
    _locale.load();
    _connectionSettings.load();
    _notifications.init().then((_) => _syncNotifications());
  }

  void _syncNotifications() {
    // Ask for the notification permission only once there is a subscription to
    // remind the user about — see [NotificationService.requestPermission].
    if (_auth.subscriptionActive) {
      unawaited(_notifications.requestPermission());
    }
    _notifications.syncFor(
      _auth.session?.expiresAt,
      _locale.strings,
      _locale.language,
    );
  }

  /// Keeps the home-screen widgets in step with the *session*: the language
  /// they render in, whether there is a subscription to connect with, and when
  /// it runs out.
  ///
  /// The tunnel half of the snapshot comes from [HomeScreen] instead, which is
  /// the only place that knows it — and which does not exist while the user is
  /// signed out or their subscription has lapsed, exactly when the widget most
  /// needs to stop offering a power button.
  void _syncHomeWidget() {
    // Still initializing: the stored session has not been read yet, and
    // publishing "signed out" here would blank a perfectly good widget for the
    // second or two it takes to resolve.
    if (_auth.initializing) return;
    if (!_auth.isLoggedIn || !_auth.subscriptionActive) {
      unawaited(HomeWidgetBridge.instance.clearSession(language: _locale.language));
      return;
    }
    unawaited(HomeWidgetBridge.instance.update(
      language: _locale.language,
      signedIn: true,
      expiresAt: _auth.session?.expiresAt,
      clearExpiresAt: _auth.session?.expiresAt == null,
    ));
  }

  /// Asks before accepting a key that arrived over `fatvpn://` — see
  /// [AuthController.pendingDeepLinkToken].
  Future<void> _maybePromptForDeepLinkKey() async {
    final token = _auth.pendingDeepLinkToken;
    if (token == null || _deepLinkPromptOpen) return;
    final navigator = _navigatorKey.currentState;
    if (navigator == null) return;
    _deepLinkPromptOpen = true;
    try {
      final s = _locale.strings;
      final accepted = await showDialog<bool>(
        context: navigator.context,
        builder: (context) => AlertDialog(
          title: Text(s.deepLinkKeyTitle),
          content: Text(s.deepLinkKeyBody(token)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(s.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(s.submitKey),
            ),
          ],
        ),
      );
      if (accepted ?? false) {
        await _auth.confirmPendingDeepLinkToken(
          conflictMessage: s.keyBoundToOtherDevice,
          deviceLimitMessage: s.keyDeviceLimitReached,
          notFoundMessage: s.keyNotFound,
          genericMessage: s.couldNotReachServer,
        );
      } else {
        _auth.dismissPendingDeepLinkToken();
      }
    } finally {
      _deepLinkPromptOpen = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // On resume, refresh the session so an extended (or lapsed) subscription is
    // reflected — e.g. the user renewed in Telegram and came back.
    if (state == AppLifecycleState.resumed) {
      _auth.refreshOnResume();
      _auth.setPairingPaused(false);
      // A widget tap that arrived while the app was already running: on iOS the
      // power button opens the app through an App Intent, with the action left
      // in the shared App Group rather than in a deep link.
      unawaited(_auth.pollWidgetAction());
    } else if (state == AppLifecycleState.paused) {
      // The user is in Telegram completing the pairing; polling from a
      // suspended app is 30 requests a minute nobody is looking at. Flush the
      // log too — a process killed in the background loses whatever is buffered.
      _auth.setPairingPaused(true);
      unawaited(AppLogger.instance.flush());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _auth.removeListener(_syncNotifications);
    _auth.removeListener(_maybePromptForDeepLinkKey);
    _auth.removeListener(_syncHomeWidget);
    _locale.removeListener(_syncNotifications);
    _locale.removeListener(_syncHomeWidget);
    _auth.dispose();
    _locale.dispose();
    _connectionSettings.dispose();
    super.dispose();
  }

  Widget _rootScreen() {
    if (_auth.initializing || !_minSplashElapsed) {
      return const SplashScreen();
    }
    if (!_auth.isLoggedIn) {
      return AwaitingAuthScreen(auth: _auth);
    }
    if (!_auth.subscriptionActive) {
      // Logged in but the subscription has lapsed — prompt to renew instead of
      // dropping back to the trial/onboarding flow.
      return AwaitingAuthScreen(auth: _auth, renew: true);
    }
    return HomeScreen(auth: _auth, connectionSettings: _connectionSettings);
  }

  @override
  Widget build(BuildContext context) {
    return AppLocalizationsScope(
      controller: _locale,
      child: MaterialApp(
        title: 'FatVPN',
        navigatorKey: _navigatorKey,
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          scaffoldBackgroundColor: AppColors.background,
          colorScheme: ColorScheme.fromSeed(
            seedColor: AppColors.accent,
            brightness: Brightness.dark,
          ),
        ),
        home: ListenableBuilder(
          listenable: _auth,
          builder: (context, _) {
            // Cross-fade the splash into the resolved screen instead of a hard
            // cut once the session settles.
            return AnimatedSwitcher(
              duration: const Duration(milliseconds: 450),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              child: _rootScreen(),
            );
          },
        ),
      ),
    );
  }
}
