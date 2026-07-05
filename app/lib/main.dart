import 'package:flutter/material.dart';

import 'l10n/app_localizations.dart';
import 'screens/awaiting_auth_screen.dart';
import 'screens/home_screen.dart';
import 'services/auth_controller.dart';
import 'services/connection_settings_controller.dart';
import 'services/locale_controller.dart';
import 'theme/app_colors.dart';

void main() {
  runApp(const FatVpnApp());
}

class FatVpnApp extends StatefulWidget {
  const FatVpnApp({super.key});

  @override
  State<FatVpnApp> createState() => _FatVpnAppState();
}

class _FatVpnAppState extends State<FatVpnApp> {
  final _auth = AuthController();
  final _locale = LocaleController();
  final _connectionSettings = ConnectionSettingsController();

  @override
  void initState() {
    super.initState();
    _auth.start();
    _locale.load();
    _connectionSettings.load();
  }

  @override
  void dispose() {
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
            if (!_auth.isAuthenticated) {
              return AwaitingAuthScreen(auth: _auth);
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
