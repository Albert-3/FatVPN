import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../l10n/strings.dart';
import '../services/connection_settings_controller.dart';
import '../theme/app_colors.dart';

/// Host-based split tunneling for iOS, where per-app VPN is impossible for
/// non-MDM apps. The user adds domains (`example.com`, `*.ru`) and IP ranges
/// (`10.0.0.0/8`); each becomes a sing-box route rule pointing either around
/// the tunnel or into it, depending on the mode the user picked (see
/// [SplitTunnelModeSelector]). Persisted in [ConnectionSettingsController] and
/// applied on the next connect.
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
            SplitTunnelHeader(title: s.splitTunneling),
            SplitTunnelModeSelector(connectionSettings: connectionSettings),
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
  /// Owned by the State, not by [_showAddDialog]: `showDialog`'s future completes
  /// the moment the route is popped, while the dialog is still playing its exit
  /// animation and its `TextField` still listens to this controller. Disposing it
  /// there threw "A TextEditingController was used after being disposed" and then
  /// tripped `_dependents.isEmpty`, replacing the screen with a red error page.
  final _hostController = TextEditingController();

  @override
  void dispose() {
    _hostController.dispose();
    super.dispose();
  }

  Future<void> _showAddDialog(Strings s) async {
    final controller = _hostController..clear();
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
                  await widget.connectionSettings.addActiveHost(value);
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
                    s.cancel,
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
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return AnimatedBuilder(
      animation: widget.connectionSettings,
      builder: (context, _) {
        final enabled = widget.connectionSettings.splitTunnelEnabled;
        final whitelist = widget.connectionSettings.splitTunnelMode ==
            SplitTunnelMode.include;
        final hosts = widget.connectionSettings.activeHosts;
        if (!enabled) {
          return SplitTunnelHint(
            text: whitelist
                ? s.splitTunnelHostsIncludeDisabledHint
                : s.splitTunnelHostsDisabledHint,
          );
        }
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  whitelist ? s.hostsUseVpnOnly : s.hostsBypassVpn,
                  style: const TextStyle(
                      color: AppColors.textSecondary, fontSize: 13),
                ),
              ),
            ),
            // An empty whitelist leaves the full tunnel up rather than routing
            // everything around it (see RouteOptions.tunnelsOnlyListedHosts).
            // That is the safe reading, but it is the opposite of what "only
            // these" implies, so say so instead of letting the user believe a
            // rule is in force.
            if (whitelist && hosts.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.info_outline,
                        color: AppColors.accent, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        s.splitTunnelIncludeEmptyNotice,
                        style: const TextStyle(
                            color: AppColors.accent, fontSize: 12, height: 1.3),
                      ),
                    ),
                  ],
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
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          // A ListTile paints its background and ink on the nearest Material.
          // Inside a decorated box that Material is whatever is *behind* the
          // card, so the ripple is invisible and the tile asserts about it.
          child: Material(
            color: AppColors.card,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
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
                    widget.connectionSettings.removeActiveHost(host),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Shared header (back arrow, centered title) used by the split-tunneling
/// screens.
///
/// The master on/off switch used to sit at the right of this row and now lives
/// in Settings, next to the row that opens these screens: turning the feature
/// on is what people came to Settings for, and it was the one part of it that
/// could only be reached by going a screen deeper.
class SplitTunnelHeader extends StatelessWidget {
  const SplitTunnelHeader({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
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
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          // Balances the back arrow so the title stays optically centred, as
          // the switch used to.
          const SizedBox(width: 48),
        ],
      ),
    );
  }
}

/// Picks which way the split-tunnel lists are read: the listed apps and hosts
/// either go around the VPN, or are the only things allowed through it.
///
/// Shown on both platforms, above the lists it governs — the same entries mean
/// opposite things under the two modes, so the user has to be able to see which
/// one is in force while editing. Each mode keeps its own lists (see
/// [ConnectionSettingsController.setSplitTunnelMode]), so switching back and
/// forth is free and never rewrites anything the user saved.
class SplitTunnelModeSelector extends StatelessWidget {
  const SplitTunnelModeSelector({super.key, required this.connectionSettings});

  final ConnectionSettingsController connectionSettings;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return AnimatedBuilder(
      animation: connectionSettings,
      builder: (context, _) {
        final enabled = connectionSettings.splitTunnelEnabled;
        final mode = connectionSettings.splitTunnelMode;
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: Row(
            children: [
              Text(
                s.splitTunnelModeLabel,
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 13),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.card,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.all(3),
                  child: Row(
                    children: [
                      _modeButton(
                        label: s.splitTunnelModeExclude,
                        selected: mode == SplitTunnelMode.exclude,
                        enabled: enabled,
                        onTap: () => connectionSettings
                            .setSplitTunnelMode(SplitTunnelMode.exclude),
                      ),
                      _modeButton(
                        label: s.splitTunnelModeInclude,
                        selected: mode == SplitTunnelMode.include,
                        enabled: enabled,
                        onTap: () => connectionSettings
                            .setSplitTunnelMode(SplitTunnelMode.include),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _modeButton({
    required String label,
    required bool selected,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(
            color: selected ? AppColors.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: !enabled
                  ? AppColors.disabled
                  : selected
                      ? AppColors.background
                      : AppColors.textSecondary,
            ),
          ),
        ),
      ),
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
