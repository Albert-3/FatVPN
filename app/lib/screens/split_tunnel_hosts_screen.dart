import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../l10n/strings.dart';
import '../services/connection_settings_controller.dart';
import '../theme/app_colors.dart';

/// Host-based split tunneling for iOS, where per-app VPN is impossible for
/// non-MDM apps. The user adds domains (`example.com`, `*.ru`) and IP ranges
/// (`10.0.0.0/8`); each becomes a sing-box `direct` route rule so its traffic
/// bypasses the tunnel. Persisted in [ConnectionSettingsController] and applied
/// on the next connect.
class SplitTunnelHostsScreen extends StatefulWidget {
  const SplitTunnelHostsScreen({super.key, required this.connectionSettings});

  final ConnectionSettingsController connectionSettings;

  @override
  State<SplitTunnelHostsScreen> createState() => _SplitTunnelHostsScreenState();
}

class _SplitTunnelHostsScreenState extends State<SplitTunnelHostsScreen> {
  Future<void> _showAddDialog(Strings s) async {
    final controller = TextEditingController();
    String? error;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> submit() async {
              final value = controller.text.trim();
              if (!ConnectionSettingsController.isValidBypassHost(value)) {
                setDialogState(() => error = s.invalidBypassHost);
                return;
              }
              final added =
                  await widget.connectionSettings.addBypassHost(value);
              if (!added) {
                setDialogState(() => error = s.bypassHostExists);
                return;
              }
              if (dialogContext.mounted) Navigator.of(dialogContext).pop();
            }

            return AlertDialog(
              backgroundColor: AppColors.card,
              title: Text(
                s.addBypassHost,
                style: const TextStyle(color: AppColors.textPrimary),
              ),
              content: TextField(
                controller: controller,
                autofocus: true,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.done,
                onChanged: (_) {
                  if (error != null) setDialogState(() => error = null);
                },
                onSubmitted: (_) => submit(),
                style: const TextStyle(color: AppColors.textPrimary),
                decoration: InputDecoration(
                  hintText: s.bypassHostHint,
                  hintStyle: const TextStyle(color: AppColors.textSecondary),
                  errorText: error,
                  enabledBorder: const UnderlineInputBorder(
                    borderSide: BorderSide(color: AppColors.textSecondary),
                  ),
                  focusedBorder: const UnderlineInputBorder(
                    borderSide: BorderSide(color: AppColors.accent),
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: Text(
                    MaterialLocalizations.of(context).cancelButtonLabel,
                    style: const TextStyle(color: AppColors.textSecondary),
                  ),
                ),
                TextButton(
                  onPressed: submit,
                  child: Text(
                    s.add,
                    style: const TextStyle(color: AppColors.accent),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
    controller.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      backgroundColor: AppColors.background,
      floatingActionButton: AnimatedBuilder(
        animation: widget.connectionSettings,
        builder: (context, _) {
          if (!widget.connectionSettings.splitTunnelEnabled) {
            return const SizedBox.shrink();
          }
          return FloatingActionButton.extended(
            backgroundColor: AppColors.accent,
            foregroundColor: AppColors.background,
            onPressed: () => _showAddDialog(s),
            icon: const Icon(Icons.add),
            label: Text(s.addBypassHost),
          );
        },
      ),
      body: SafeArea(
        child: AnimatedBuilder(
          animation: widget.connectionSettings,
          builder: (context, _) {
            final enabled = widget.connectionSettings.splitTunnelEnabled;
            final hosts = widget.connectionSettings.bypassHosts;
            return Column(
              children: [
                _buildHeader(context, s, enabled),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      s.hostsBypassVpn,
                      style: const TextStyle(
                          color: AppColors.textSecondary, fontSize: 13),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      s.appliesOnNextConnection,
                      style: const TextStyle(
                          color: AppColors.textSecondary, fontSize: 11),
                    ),
                  ),
                ),
                if (!enabled)
                  Expanded(child: _Hint(text: s.splitTunnelHostsDisabledHint))
                else if (hosts.isEmpty)
                  Expanded(child: _Hint(text: s.noBypassHosts))
                else
                  Expanded(child: _buildHostList(hosts)),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildHostList(List<String> hosts) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 96),
      itemCount: hosts.length,
      itemBuilder: (context, i) {
        final host = hosts[i];
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(14),
          ),
          child: ListTile(
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14)),
            leading: const Icon(Icons.public, color: AppColors.textSecondary),
            title: Text(
              host,
              style: const TextStyle(
                  color: AppColors.textPrimary, fontSize: 15),
            ),
            trailing: IconButton(
              icon: const Icon(Icons.close, color: AppColors.textSecondary),
              onPressed: () =>
                  widget.connectionSettings.removeBypassHost(host),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context, Strings s, bool enabled) {
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
              s.splitTunneling,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Switch(
            value: enabled,
            activeTrackColor: AppColors.accent,
            onChanged: (v) =>
                widget.connectionSettings.setSplitTunnelEnabled(v),
          ),
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.call_split, color: AppColors.textSecondary, size: 40),
            const SizedBox(height: 16),
            Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 14, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}
