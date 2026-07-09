import 'package:flutter/material.dart';
import 'package:singbox_mm/singbox_mm.dart';

import '../config/api_config.dart';
import '../l10n/app_localizations.dart';
import '../l10n/strings.dart';
import '../models/account_status.dart';
import '../services/api_client.dart';
import '../services/app_logger.dart';
import '../services/auth_controller.dart';
import '../services/connection_settings_controller.dart';
import '../services/locale_controller.dart';
import '../theme/app_colors.dart';
import 'split_tunneling_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.auth,
    required this.connectionSettings,
  });

  final AuthController auth;
  final ConnectionSettingsController connectionSettings;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final _apiClient = ApiClient(
    onUnauthorized: widget.auth.ensureFreshAccessToken,
  );

  AccountStatus? _accountStatus;
  bool _loading = true;
  String? _error;
  late final TextEditingController _customDnsController;

  @override
  void initState() {
    super.initState();
    _customDnsController = TextEditingController(
      text: widget.connectionSettings.customDns,
    );
    _loadAccountStatus();
  }

  @override
  void dispose() {
    _customDnsController.dispose();
    super.dispose();
  }

  Future<void> _loadAccountStatus() async {
    final session = widget.auth.session;
    if (session == null) {
      setState(() {
        _loading = false;
        _error = S.of(context).notSignedIn;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final status = await _apiClient.getMe(session.accessToken);
      setState(() {
        _accountStatus = status;
        _loading = false;
      });
    } on ApiException catch (e) {
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = S.of(context).couldNotReachServer;
        _loading = false;
      });
    }
  }

  bool _sharingLogs = false;

  Future<void> _clearLogs(Strings s) async {
    await AppLogger.instance.clear();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(s.logsCleared)),
    );
  }

  Future<void> _sendLogs(Strings s) async {
    if (_sharingLogs) return;
    if (AppLogger.instance.inMemoryCount == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(s.noLogsToShare)),
      );
      return;
    }
    setState(() => _sharingLogs = true);
    try {
      await AppLogger.instance.shareSupportBundle(extraContext: _diagnosticsContext());
    } finally {
      if (mounted) setState(() => _sharingLogs = false);
    }
  }

  /// Sanitized snapshot of the current settings/session for the bundle header.
  /// Tokens are masked — never put a full access/refresh token in diagnostics.
  Map<String, String> _diagnosticsContext() {
    final cs = widget.connectionSettings;
    final session = widget.auth.session;
    return {
      'api_domain': bffBaseUrl,
      'dns_preset': cs.dnsPreset.name,
      'custom_dns': cs.customDns.isEmpty ? '(none)' : cs.customDns,
      'network_stack': cs.networkStack.name,
      'split_tunnel_enabled': cs.splitTunnelEnabled.toString(),
      'split_bypass_count': cs.bypassPackages.length.toString(),
      'logged_in': widget.auth.isLoggedIn.toString(),
      'subscription_active': widget.auth.subscriptionActive.toString(),
      'session_expires_at': session?.expiresAt.toIso8601String() ?? '(none)',
      'has_refresh_token': (session?.hasRefreshToken ?? false).toString(),
      'access_token_masked': _mask(session?.accessToken),
    };
  }

  static String _mask(String? token) {
    if (token == null || token.isEmpty) return '(none)';
    if (token.length <= 8) return '****';
    return '${token.substring(0, 4)}…${token.substring(token.length - 4)}';
  }

  String _expiryLabel(Strings s, DateTime expiresAt) {
    final remaining = expiresAt.difference(DateTime.now());
    if (remaining.isNegative) {
      return s.expired;
    }
    // Round to the nearest day (not floor) so a freshly granted N-day trial
    // reads "N days", not "N-1" — expiresAt is a few seconds under N*24h.
    if (remaining.inHours >= 24) {
      return s.expiresInDays((remaining.inHours / 24).round());
    }
    return s.expiresInHours(remaining.inHours);
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final locale = AppLocalizationsScope.of(context);
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(context, s),
            Expanded(
              child: Stack(
                children: [
                  ListView(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 96),
                    children: [
                      _sectionTitle(s.manageAccount),
                      _card(children: [_buildAccountStatus(s)]),
                      _sectionTitle(s.connectionSettings),
                      AnimatedBuilder(
                        animation: widget.connectionSettings,
                        builder: (context, _) {
                          final cs = widget.connectionSettings;
                          final isCustomDns =
                              cs.dnsPreset == DnsProviderPreset.custom;
                          return _card(
                            children: [
                              _pickerRow(
                                s.dnsServer,
                                isCustomDns && cs.customDns.isNotEmpty
                                    ? cs.customDns
                                    : _dnsLabel(cs.dnsPreset),
                                () => _showDnsPicker(s),
                              ),
                              if (isCustomDns) ...[
                                const SizedBox(height: 10),
                                TextField(
                                  controller: _customDnsController,
                                  style: const TextStyle(
                                    color: AppColors.textPrimary,
                                    fontSize: 14,
                                  ),
                                  autocorrect: false,
                                  enableSuggestions: false,
                                  keyboardType: TextInputType.url,
                                  onChanged: cs.setCustomDns,
                                  decoration: InputDecoration(
                                    isDense: true,
                                    hintText: s.customDnsHint,
                                    hintStyle: const TextStyle(
                                      color: AppColors.textSecondary,
                                      fontSize: 12,
                                    ),
                                    filled: true,
                                    fillColor: AppColors.background,
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(10),
                                      borderSide: BorderSide.none,
                                    ),
                                  ),
                                ),
                              ],
                              const Divider(
                                color: AppColors.disabled,
                                height: 24,
                              ),
                              _pickerRow(
                                s.networkStack,
                                _stackLabel(cs.networkStack),
                                () => _showStackPicker(s),
                              ),
                            ],
                          );
                        },
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 6, left: 4),
                        child: Text(
                          s.appliesOnNextConnection,
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 11,
                          ),
                        ),
                      ),
                      _sectionTitle(s.routing),
                      _card(
                        children: [
                          InkWell(
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => SplitTunnelingScreen(
                                  connectionSettings: widget.connectionSettings,
                                ),
                              ),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        s.splitTunnelingSettings,
                                        style: const TextStyle(
                                          color: AppColors.textPrimary,
                                          fontSize: 15,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        s.splitTunnelingSubtitle,
                                        style: const TextStyle(
                                          color: AppColors.textSecondary,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const Icon(
                                  Icons.chevron_right,
                                  color: AppColors.textSecondary,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      _sectionTitle(s.system),
                      _card(children: [_buildLanguageRow(s, locale)]),
                      _sectionTitle(s.logsManagement),
                      _card(
                        children: [
                          Text(
                            s.applicationLogs,
                            style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            s.shareDiagnostics,
                            style: const TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 14),
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton(
                                  onPressed:
                                      _sharingLogs ? null : () => _clearLogs(s),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: AppColors.textPrimary,
                                    side: const BorderSide(
                                      color: AppColors.disabled,
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 12,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                  child: Text(s.clear),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: ElevatedButton(
                                  onPressed:
                                      _sharingLogs ? null : () => _sendLogs(s),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: AppColors.accent,
                                    foregroundColor: AppColors.background,
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 12,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                  child: _sharingLogs
                                      ? const SizedBox(
                                          height: 18,
                                          width: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: AppColors.background,
                                          ),
                                        )
                                      : Text(
                                          s.send,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                      decoration: const BoxDecoration(
                        color: AppColors.background,
                        border: Border(
                          top: BorderSide(color: AppColors.disabled),
                        ),
                      ),
                      child: SizedBox(
                        width: double.infinity,
                        child: OutlinedButton(
                          onPressed: () async {
                            await widget.auth.signOut();
                            if (context.mounted) {
                              Navigator.of(context).popUntil((r) => r.isFirst);
                            }
                          },
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.redAccent,
                            side: const BorderSide(color: Colors.redAccent),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: Text(s.signOut),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAccountStatus(Strings s) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 4),
        child: SizedBox(
          height: 20,
          width: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppColors.accent,
          ),
        ),
      );
    }
    if (_error != null) {
      return Row(
        children: [
          Expanded(
            child: Text(
              _error!,
              style: const TextStyle(color: Colors.redAccent, fontSize: 13),
            ),
          ),
          TextButton(onPressed: _loadAccountStatus, child: Text(s.retry)),
        ],
      );
    }
    final status = _accountStatus!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              status.isActive ? Icons.check_circle : Icons.error,
              size: 16,
              color: status.isActive ? AppColors.accent : Colors.redAccent,
            ),
            const SizedBox(width: 8),
            Text(
              status.isActive ? s.active : s.expired,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          _expiryLabel(s, status.expiresAt),
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
        ),
      ],
    );
  }

  Widget _buildLanguageRow(Strings s, LocaleController locale) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          s.language,
          style: const TextStyle(color: AppColors.textPrimary, fontSize: 15),
        ),
        SegmentedButton<AppLanguage>(
          segments: const [
            ButtonSegment(value: AppLanguage.en, label: Text('EN')),
            ButtonSegment(value: AppLanguage.ru, label: Text('RU')),
          ],
          selected: {locale.language},
          onSelectionChanged: (selection) {
            locale.setLanguage(selection.first);
          },
        ),
      ],
    );
  }

  Widget _buildHeader(BuildContext context, Strings s) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
          ),
          Expanded(
            child: Text(
              s.settingsTitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 48),
        ],
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Text(
        title,
        style: const TextStyle(
          color: AppColors.textSecondary,
          fontSize: 12,
          letterSpacing: 1,
        ),
      ),
    );
  }

  Widget _card({required List<Widget> children}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  Widget _pickerRow(String label, String value, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 15,
              ),
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 14,
            ),
          ),
          const SizedBox(width: 4),
          const Icon(
            Icons.expand_more,
            size: 18,
            color: AppColors.textSecondary,
          ),
        ],
      ),
    );
  }

  // DNS provider brands / IPs are proper nouns, not localized.
  String _dnsLabel(DnsProviderPreset preset) {
    switch (preset) {
      case DnsProviderPreset.cloudflare:
        return 'Cloudflare (1.1.1.1)';
      case DnsProviderPreset.google:
        return 'Google (8.8.8.8)';
      case DnsProviderPreset.quad9:
        return 'Quad9 (9.9.9.9)';
      case DnsProviderPreset.adguard:
        return 'AdGuard (94.140.14.14)';
      case DnsProviderPreset.custom:
        return 'Custom';
    }
  }

  // "Mixed" is the mockup's label for the native (system) tun stack; the plugin
  // only offers system and gVisor. Both are sing-box technical terms.
  String _stackLabel(SingboxTunImplementation stack) {
    return stack == SingboxTunImplementation.system ? 'Mixed' : 'gVisor';
  }

  Future<void> _showDnsPicker(Strings s) {
    final cs = widget.connectionSettings;
    return _showOptionSheet<DnsProviderPreset>(
      title: s.dnsServer,
      options: ConnectionSettingsController.dnsPresets,
      selected: cs.dnsPreset,
      labelOf: _dnsLabel,
      onSelected: cs.setDnsPreset,
    );
  }

  Future<void> _showStackPicker(Strings s) {
    final cs = widget.connectionSettings;
    return _showOptionSheet<SingboxTunImplementation>(
      title: s.networkStack,
      options: ConnectionSettingsController.networkStacks,
      selected: cs.networkStack,
      labelOf: _stackLabel,
      onSelected: cs.setNetworkStack,
    );
  }

  Future<void> _showOptionSheet<T>({
    required String title,
    required List<T> options,
    required T selected,
    required String Function(T) labelOf,
    required void Function(T) onSelected,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    title,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                      letterSpacing: 1,
                    ),
                  ),
                ),
              ),
              for (final option in options)
                ListTile(
                  title: Text(
                    labelOf(option),
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 15,
                    ),
                  ),
                  trailing: option == selected
                      ? const Icon(Icons.check, color: AppColors.accent)
                      : null,
                  onTap: () {
                    onSelected(option);
                    Navigator.of(sheetContext).pop();
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }
}
