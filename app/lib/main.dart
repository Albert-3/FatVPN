import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'l10n/app_localizations.dart';
import 'screens/awaiting_auth_screen.dart';
import 'screens/home_screen.dart';
import 'services/auth_controller.dart';
import 'services/connection_settings_controller.dart';
import 'services/locale_controller.dart';
import 'services/notification_service.dart';
import 'theme/app_colors.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Re-plan local expiry reminders whenever the session (expiry) or the
    // language changes. syncFor no-ops until init() completes, then the first
    // sync runs once init resolves.
    _auth.addListener(_syncNotifications);
    _locale.addListener(_syncNotifications);
    _auth.start();
    _locale.load();
    _connectionSettings.load();
    _notifications.init().then((_) => _syncNotifications());
  }

  void _syncNotifications() {
    _notifications.syncFor(
      _auth.session?.expiresAt,
      _locale.strings,
      _locale.language,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // On resume, refresh the session so an extended (or lapsed) subscription is
    // reflected — e.g. the user renewed in Telegram and came back.
    if (state == AppLifecycleState.resumed) {
      _auth.refreshOnResume();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _auth.removeListener(_syncNotifications);
    _locale.removeListener(_syncNotifications);
    _auth.dispose();
    _locale.dispose();
    _connectionSettings.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppLocalizationsScope(
      controller: _locale,
      child: MaterialApp(
        title: 'FatVPN',
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
            if (_auth.initializing) {
              return const Scaffold(
                backgroundColor: AppColors.background,
                body: Center(
                  child: CircularProgressIndicator(color: AppColors.accent),
                ),
              );
            }
            if (!_auth.isLoggedIn) {
              return AwaitingAuthScreen(auth: _auth);
            }
            if (!_auth.subscriptionActive) {
              // Logged in but the subscription has lapsed — prompt to renew
              // instead of dropping back to the trial/onboarding flow.
              return AwaitingAuthScreen(auth: _auth, renew: true);
            }
            return HomeScreen(
              auth: _auth,
              connectionSettings: _connectionSettings,
            );
          },
        ),
      ),
    );
  }
}
