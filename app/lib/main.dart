import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  // Lock the app to portrait — the UI is designed for vertical phones only.
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const FatVpnApp());
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
