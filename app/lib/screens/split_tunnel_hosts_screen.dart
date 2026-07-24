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
///
/// The editor body is factored out into [HostBypassEditor] so Android can embed
/// it as a tab alongside the per-app picker.
class SplitTunnelHostsScreen extends StatelessWidget {
  const SplitTunnelHostsScreen({super.key, required this.connectionSettings});

  final ConnectionSettingsController connectionSettings;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            SplitTunnelHeader(
              title: s.splitTunneling,
              connectionSettings: connectionSettings,
            ),
            Expanded(child: HostBypassEditor(connectionSettings: connectionSettings)),
          ],
        ),
      ),
    );
  }
}

/// Reusable body that lets the user manage the domain/IP bypass list. Shown on
/// iOS as a full screen and on Android as a tab.
class HostBypassEditor extends StatefulWidget {
  const HostBypassEditor({super.key, required this.connectionSettings});

  final ConnectionSettingsController connectionSettings;

  @override
  State<HostBypassEditor> createState() => _HostBypassEditorState();
}

class _HostBypassEditorState extends State<HostBypassEditor> {
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
    return AnimatedBuilder(
      animation: widget.connectionSettings,
      builder: (context, _) {
        final enabled = widget.connectionSettings.splitTunnelEnabled;
        final hosts = widget.connectionSettings.bypassHosts;
        if (!enabled) {
          return SplitTunnelHint(text: s.splitTunnelHostsDisabledHint);
        }
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  s.hostsBypassVpn,
                  style: const TextStyle(
                      color: AppColors.textSecondary, fontSize: 13),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => _showAddDialog(s),
                  icon: const Icon(Icons.add, color: AppColors.accent),
                  label: Text(
                    s.addBypassHost,
                    style: const TextStyle(color: AppColors.accent),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: AppColors.accent),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            ),
            if (hosts.isEmpty)
              Expanded(child: SplitTunnelHint(text: s.noBypassHosts))
            else
              Expanded(child: _buildHostList(hosts)),
          ],
        );
      },
    );
  }

  Widget _buildHostList(List<String> hosts) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
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
              style:
                  const TextStyle(color: AppColors.textPrimary, fontSize: 15),
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
}

/// Shared header (back arrow, centered title, master split-tunnel switch) used
/// by the split-tunneling screens.
class SplitTunnelHeader extends StatelessWidget {
  const SplitTunnelHeader({
    super.key,
    required this.title,
    required this.connectionSettings,
  });

  final String title;
  final ConnectionSettingsController connectionSettings;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: connectionSettings,
      builder: (context, _) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: [
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon:
                    const Icon(Icons.arrow_back, color: AppColors.textPrimary),
              ),
              Expanded(
                child: Text(
                  title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Switch(
                value: connectionSettings.splitTunnelEnabled,
                activeTrackColor: AppColors.accent,
                onChanged: connectionSettings.setSplitTunnelEnabled,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Centered hint shown when a split-tunnel list is empty or disabled.
class SplitTunnelHint extends StatelessWidget {
  const SplitTunnelHint({super.key, required this.text});

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
