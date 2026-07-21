import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../l10n/strings.dart';
import '../services/auth_controller.dart';
import '../theme/app_colors.dart';

/// Onboarding / pairing screen. Fetches a pairing code, lets the user open the
/// Telegram bot to link their account, and polls until the bot confirms.
class AwaitingAuthScreen extends StatefulWidget {
  const AwaitingAuthScreen({super.key, required this.auth, this.renew = false});

  final AuthController auth;

  /// Renew mode: the user is logged in but the subscription has lapsed. Shows
  /// a "subscription expired" heading, hides the trial option, and offers a
  /// "check again" action after they renew.
  final bool renew;

  @override
  State<AwaitingAuthScreen> createState() => _AwaitingAuthScreenState();
}

class _AwaitingAuthScreenState extends State<AwaitingAuthScreen> {
  @override
  void initState() {
    super.initState();
    // Defer to after the first frame: startPairing() notifies its listeners
    // synchronously, and firing that during this build marks the auth-gate
    // ListenableBuilder dirty mid-build (a "!_dirty" assertion in debug that
    // can wedge later rebuilds).
    // Pairing (Telegram deep link) is used by the renew flow and by the
    // trial-used recovery flow (a device that already spent its trial and is
    // logged out — no trial button, so it needs the Telegram/key path). A
    // first-run device that still has its trial is trial-only and starts no code.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final needsPairing = widget.renew || !widget.auth.trialAvailable;
      if (needsPairing &&
          widget.auth.pairCode == null &&
          widget.auth.error == null) {
        widget.auth.startPairing();
      }
    });
  }

  Future<void> _openBot() async {
    final uri = widget.auth.telegramPairUri;
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _startTrial(Strings s) async {
    await widget.auth.requestTrial(
      conflictMessage: s.trialAlreadyUsed,
      noCapacityMessage: s.trialNoCapacity,
      genericMessage: s.trialFailed,
    );
  }

  Future<void> _continueTrial(Strings s) async {
    await widget.auth.resumeTrial(
      expiredMessage: s.trialAlreadyUsed,
      genericMessage: s.trialFailed,
    );
  }

  bool _checking = false;

  Future<void> _checkAgain() async {
    setState(() => _checking = true);
    await widget.auth.refreshOnResume();
    if (mounted) setState(() => _checking = false);
  }

  /// Telegram/pairing CTA. Filled (primary) when it's the top action, outlined
  /// (secondary) when the free-trial button already sits above it.
  Widget _telegramButton(Strings s, {required bool primary}) {
    final icon = const Icon(Icons.telegram, size: 22);
    final label = Text(
      widget.renew ? s.renewViaTelegram : s.connectWithTelegram,
      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
    );
    const padding = EdgeInsets.symmetric(vertical: 14);
    if (primary) {
      return FilledButton.icon(
        onPressed: _openBot,
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.accent,
          foregroundColor: Colors.black,
          padding: padding,
        ),
        icon: icon,
        label: label,
      );
    }
    return OutlinedButton.icon(
      onPressed: _openBot,
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.accent,
        side: const BorderSide(color: AppColors.accent),
        padding: padding,
      ),
      icon: icon,
      label: label,
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final auth = widget.auth;
    final code = auth.pairCode;
    // Trial-used recovery: logged out on a device that already spent its trial.
    // Shows the Telegram/key path with its own heading (not the "2 days free"
    // onboarding copy, which would be a promise the app can't keep).
    final recovery = !widget.renew && !auth.trialAvailable;

    // Compact layout tuned to fit the whole onboarding on one screen without
    // needing to scroll. SingleChildScrollView stays only as an overflow safety
    // net for very short screens / large system font scales.
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
            child: ConstrainedBox(
              // Fill the viewport (minus the 12+12 vertical padding) so the
              // content can be vertically centered, while still scrolling when
              // the taller renew/recovery layouts overflow.
              constraints: BoxConstraints(
                minHeight: constraints.maxHeight - 24,
              ),
              child: IntrinsicHeight(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: Alignment.centerRight,
                      child: _LanguageToggle(),
                    ),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const SizedBox(height: 4),
                          Center(
                            child: Image.asset(
                              'assets/images/logo.png',
                              height: 44,
                            ),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            widget.renew
                                ? s.subscriptionExpiredTitle
                                : recovery
                                ? (auth.trialResumable
                                      ? s.trialResumableTitle
                                      : s.trialUsedTitle)
                                : s.openBotTitle,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            widget.renew
                                ? s.subscriptionExpiredSubtitle
                                : recovery
                                ? (auth.trialResumable
                                      ? s.trialResumableSubtitle
                                      : s.trialUsedSubtitle)
                                : s.openBotSubtitle,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 13,
                              height: 1.35,
                            ),
                          ),
                          const SizedBox(height: 20),

                          // First run with an unused trial: the only path is the free
                          // trial. The user buys a subscription in Telegram afterwards
                          // and enters/pastes the key from Settings.
                          if (!widget.renew && auth.trialAvailable) ...[
                            FilledButton.icon(
                              onPressed: auth.trialBusy
                                  ? null
                                  : () => _startTrial(s),
                              style: FilledButton.styleFrom(
                                backgroundColor: AppColors.accent,
                                foregroundColor: Colors.black,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 16,
                                ),
                              ),
                              icon: auth.trialBusy
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.black,
                                      ),
                                    )
                                  : const Icon(Icons.bolt, size: 22),
                              label: Text(
                                s.tryFreeTrial,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 15,
                                ),
                              ),
                            ),
                            if (auth.error != null) ...[
                              const SizedBox(height: 14),
                              _ErrorBlock(message: auth.error!),
                            ],
                          ] else if (!widget.renew) ...[
                            // Trial-used recovery: the device already spent its free
                            // trial but has no session (e.g. it signed out, or left
                            // the app right after the grant). If the trial it had
                            // might still be running, offer to resume it directly;
                            // Telegram bot + manual key entry are always available
                            // below as the way to move past the trial for good.
                            if (auth.trialResumable) ...[
                              FilledButton.icon(
                                onPressed: auth.trialResumeBusy
                                    ? null
                                    : () => _continueTrial(s),
                                style: FilledButton.styleFrom(
                                  backgroundColor: AppColors.accent,
                                  foregroundColor: Colors.black,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 16,
                                  ),
                                ),
                                icon: auth.trialResumeBusy
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.black,
                                        ),
                                      )
                                    : const Icon(Icons.bolt, size: 22),
                                label: Text(
                                  s.continueTrial,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 15,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 14),
                              const Divider(color: AppColors.disabled, height: 1),
                              const SizedBox(height: 14),
                            ],
                            if (auth.error != null) ...[
                              _ErrorBlock(message: auth.error!),
                              const SizedBox(height: 12),
                            ],
                            if (code == null)
                              const Center(
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: AppColors.accent,
                                ),
                              )
                            else
                              _telegramButton(s, primary: !auth.trialResumable),
                            const SizedBox(height: 14),
                            const Divider(color: AppColors.disabled, height: 1),
                            _ManualKeyEntry(auth: auth),
                          ] else ...[
                            // Renew mode: a lapsed subscriber renews via Telegram or
                            // pastes a new key, then re-checks.
                            if (auth.error != null) ...[
                              _ErrorBlock(message: auth.error!),
                              const SizedBox(height: 12),
                              OutlinedButton(
                                onPressed: auth.startPairing,
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: AppColors.accent,
                                  side: const BorderSide(
                                    color: AppColors.accent,
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 13,
                                  ),
                                ),
                                child: Text(
                                  s.getNewCode,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ] else if (code == null) ...[
                              const SizedBox(height: 8),
                              const Center(
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: AppColors.accent,
                                ),
                              ),
                            ] else ...[
                              _telegramButton(s, primary: true),
                              const SizedBox(height: 12),
                              _CrossDeviceBlock(
                                code: code,
                                uri: auth.telegramPairUri!,
                                hint: s.pairingScanHint,
                              ),
                              const SizedBox(height: 10),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: AppColors.accent,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Text(
                                    s.pairingWaiting,
                                    style: const TextStyle(
                                      color: AppColors.textSecondary,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                            const SizedBox(height: 12),
                            OutlinedButton(
                              onPressed: _checking ? null : _checkAgain,
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppColors.accent,
                                side: const BorderSide(color: AppColors.accent),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 13,
                                ),
                              ),
                              child: _checking
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: AppColors.accent,
                                      ),
                                    )
                                  : Text(
                                      s.checkAgain,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                            ),
                            const SizedBox(height: 14),
                            const Divider(color: AppColors.disabled, height: 1),
                            _ManualKeyEntry(auth: auth),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Fallback for users who already have a 32-char key (from the bot's
/// "Поменять ключ" flow) and want to enter it manually instead of pairing.
class _ManualKeyEntry extends StatefulWidget {
  const _ManualKeyEntry({required this.auth});

  final AuthController auth;

  @override
  State<_ManualKeyEntry> createState() => _ManualKeyEntryState();
}

class _ManualKeyEntryState extends State<_ManualKeyEntry> {
  final _controller = TextEditingController();
  bool _expanded = false;
  bool _submitting = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final code = _controller.text.trim();
    if (code.isEmpty || _submitting) return;
    final s = S.of(context);
    setState(() => _submitting = true);
    await widget.auth.exchangeShortToken(code, conflictMessage: s.keyBoundToOtherDevice);
    if (mounted) setState(() => _submitting = false);
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextButton.icon(
          onPressed: () => setState(() => _expanded = !_expanded),
          icon: Icon(
            _expanded ? Icons.expand_less : Icons.vpn_key_outlined,
            size: 18,
            color: AppColors.textSecondary,
          ),
          label: Text(
            s.haveKeyTitle,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13,
            ),
          ),
        ),
        if (_expanded) ...[
          const SizedBox(height: 8),
          TextField(
            controller: _controller,
            autocorrect: false,
            enableSuggestions: false,
            textCapitalization: TextCapitalization.characters,
            style: const TextStyle(
              color: AppColors.textPrimary,
              letterSpacing: 1.5,
            ),
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              hintText: s.enterKeyHint,
              hintStyle: const TextStyle(color: AppColors.textSecondary),
              filled: true,
              fillColor: AppColors.card,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _submitting ? null : _submit,
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            child: _submitting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.black,
                    ),
                  )
                : Text(
                    s.submitKey,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
          ),
        ],
      ],
    );
  }
}

class _LanguageToggle extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final locale = AppLocalizationsScope.of(context);
    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(20),
      ),
      padding: const EdgeInsets.all(3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final lang in AppLanguage.values)
            GestureDetector(
              onTap: () => locale.setLanguage(lang),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: locale.language == lang
                      ? AppColors.accent
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Text(
                  lang == AppLanguage.ru ? 'RU' : 'EN',
                  style: TextStyle(
                    color: locale.language == lang
                        ? Colors.black
                        : AppColors.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
        ],
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
  const _CrossDeviceBlock({
    required this.code,
    required this.uri,
    required this.hint,
  });

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
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 12,
            height: 1.3,
          ),
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
          ),
          child: QrImageView(
            data: uri.toString(),
            size: 116,
            backgroundColor: Colors.white,
          ),
        ),
        const SizedBox(height: 10),
        SelectableText(
          code,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 20,
            fontWeight: FontWeight.w700,
            letterSpacing: 4,
            fontFamily: 'monospace',
          ),
        ),
      ],
    );
  }
}
