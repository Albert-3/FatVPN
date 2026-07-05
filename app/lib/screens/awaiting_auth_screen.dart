import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../services/auth_controller.dart';
import '../theme/app_colors.dart';

/// Onboarding / pairing screen. Fetches a pairing code, lets the user open the
/// Telegram bot to link their account, and polls until the bot confirms.
class AwaitingAuthScreen extends StatefulWidget {
  const AwaitingAuthScreen({super.key, required this.auth});

  final AuthController auth;

  @override
  State<AwaitingAuthScreen> createState() => _AwaitingAuthScreenState();
}

class _AwaitingAuthScreenState extends State<AwaitingAuthScreen> {
  @override
  void initState() {
    super.initState();
    if (widget.auth.pairCode == null && widget.auth.error == null) {
      widget.auth.startPairing();
    }
  }

  Future<void> _openBot() async {
    final uri = widget.auth.telegramPairUri;
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final auth = widget.auth;
    final code = auth.pairCode;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 12),
              Center(child: Image.asset('assets/images/logo.png', height: 56)),
              const SizedBox(height: 28),
              Text(
                s.openBotTitle,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                s.openBotSubtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textSecondary, fontSize: 13, height: 1.4),
              ),
              const SizedBox(height: 32),

              if (auth.error != null) ...[
                _ErrorBlock(message: auth.error!),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: auth.startPairing,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: Text(s.getNewCode, style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
              ] else if (code == null) ...[
                const SizedBox(height: 40),
                const Center(
                  child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accent),
                ),
              ] else ...[
                FilledButton.icon(
                  onPressed: _openBot,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  icon: const Icon(Icons.telegram, size: 22),
                  label: Text(
                    s.connectWithTelegram,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                  ),
                ),
                const SizedBox(height: 28),
                _CrossDeviceBlock(code: code, uri: auth.telegramPairUri!, hint: s.pairingScanHint),
                const SizedBox(height: 28),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accent),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      s.pairingWaiting,
                      style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorBlock extends StatelessWidget {
  const _ErrorBlock({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.redAccent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.redAccent, fontSize: 13),
      ),
    );
  }
}

class _CrossDeviceBlock extends StatelessWidget {
  const _CrossDeviceBlock({required this.code, required this.uri, required this.hint});

  final String code;
  final Uri uri;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          hint,
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 12, height: 1.4),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
          ),
          child: QrImageView(
            data: uri.toString(),
            size: 160,
            backgroundColor: Colors.white,
          ),
        ),
        const SizedBox(height: 16),
        SelectableText(
          code,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 22,
            fontWeight: FontWeight.w700,
            letterSpacing: 4,
            fontFamily: 'monospace',
          ),
        ),
      ],
    );
  }
}
