import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../l10n/strings.dart';
import '../services/connection_settings_controller.dart';
import '../services/installed_apps_service.dart';
import '../theme/app_colors.dart';
import 'split_tunnel_hosts_screen.dart';

/// Android split tunneling: one screen with two tabs — "Apps" (per-app, via
/// sing-box `exclude_package`/`include_package`) and "Domains/IP" (by host, via
/// `route.rules`, the same model iOS uses). The mode selector above the tabs
/// decides whether the two lists name what skips the VPN or what is the only
/// thing allowed through it. Both feed [ConnectionSettingsController] and apply
/// on the next connect.
class SplitTunnelingScreen extends StatelessWidget {
  const SplitTunnelingScreen({super.key, required this.connectionSettings});

  final ConnectionSettingsController connectionSettings;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: SafeArea(
          child: Column(
            children: [
              SplitTunnelHeader(
                title: s.splitTunneling,
                connectionSettings: connectionSettings,
              ),
              SplitTunnelModeSelector(connectionSettings: connectionSettings),
              TabBar(
                labelColor: AppColors.textPrimary,
                unselectedLabelColor: AppColors.textSecondary,
                indicatorColor: AppColors.accent,
                tabs: [
                  Tab(text: s.splitTunnelAppsTab),
                  Tab(text: s.splitTunnelHostsTab),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    AppBypassPicker(connectionSettings: connectionSettings),
                    HostBypassEditor(connectionSettings: connectionSettings),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Lets the user pick installed apps that either bypass the VPN tunnel
/// (sing-box `exclude_package`) or are the only ones inside it
/// (`include_package`), depending on the active mode. Android-only; embedded as
/// a tab in [SplitTunnelingScreen].
class AppBypassPicker extends StatefulWidget {
  const AppBypassPicker({super.key, required this.connectionSettings});

  final ConnectionSettingsController connectionSettings;

  @override
  State<AppBypassPicker> createState() => _AppBypassPickerState();
}

class _AppBypassPickerState extends State<AppBypassPicker> {
  List<LaunchableApp>? _apps;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _loadApps();
  }

  Future<void> _loadApps() async {
    // Only launcher (app-drawer) apps — includes preinstalled browsers like
    // Chrome but excludes background services/overlays.
    final apps = await InstalledAppsService.getLaunchableApps();
    apps.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    if (mounted) setState(() => _apps = apps);
  }

  void _toggleApp(String packageName, bool selected) {
    final next = Set<String>.from(widget.connectionSettings.activePackages);
    if (selected) {
      next.add(packageName);
    } else {
      next.remove(packageName);
    }
    widget.connectionSettings.setActivePackages(next);
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return AnimatedBuilder(
      animation: widget.connectionSettings,
      builder: (context, _) {
        final whitelist = widget.connectionSettings.splitTunnelMode ==
            SplitTunnelMode.include;
        if (!widget.connectionSettings.splitTunnelEnabled) {
          return SplitTunnelHint(
            text: whitelist
                ? s.splitTunnelIncludeDisabledHint
                : s.splitTunnelDisabledHint,
          );
        }
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  whitelist ? s.appsUseVpnOnly : s.appsBypassVpn,
                  style: const TextStyle(
                      color: AppColors.textSecondary, fontSize: 13),
                ),
              ),
            ),
            // Same reasoning as the host editor's notice: picking no app leaves
            // every app in the tunnel rather than shutting them all out.
            if (whitelist && widget.connectionSettings.activePackages.isEmpty)
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
            Expanded(child: _buildAppList(s)),
          ],
        );
      },
    );
  }

  Widget _buildAppList(Strings s) {
    final apps = _apps;
    if (apps == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: AppColors.accent, strokeWidth: 2),
            const SizedBox(height: 16),
            Text(s.loadingApps, style: const TextStyle(color: AppColors.textSecondary)),
          ],
        ),
      );
    }

    final q = _query.trim().toLowerCase();
    final filtered = q.isEmpty
        ? apps
        : apps.where((a) => a.name.toLowerCase().contains(q)).toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          child: TextField(
            onChanged: (v) => setState(() => _query = v),
            style: const TextStyle(color: AppColors.textPrimary),
            decoration: InputDecoration(
              hintText: s.searchApps,
              hintStyle: const TextStyle(color: AppColors.textSecondary),
              prefixIcon: const Icon(Icons.search, color: AppColors.textSecondary),
              filled: true,
              fillColor: AppColors.card,
              contentPadding: EdgeInsets.zero,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: filtered.length,
            itemBuilder: (context, i) {
              final app = filtered[i];
              final selected = widget.connectionSettings.activePackages
                  .contains(app.packageName);
              return _AppTile(
                app: app,
                selected: selected,
                onChanged: (v) => _toggleApp(app.packageName, v),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _AppTile extends StatelessWidget {
  const _AppTile({
    required this.app,
    required this.selected,
    required this.onChanged,
  });

  final LaunchableApp app;
  final bool selected;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final icon = app.icon;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
      ),
      child: CheckboxListTile(
        value: selected,
        onChanged: (v) => onChanged(v ?? false),
        activeColor: AppColors.accent,
        checkColor: AppColors.background,
        controlAffinity: ListTileControlAffinity.trailing,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        secondary: icon != null
            ? Image.memory(icon, width: 36, height: 36)
            : const Icon(Icons.android, color: AppColors.textSecondary, size: 36),
        title: Text(
          app.name,
          style: const TextStyle(color: AppColors.textPrimary, fontSize: 15),
        ),
      ),
    );
  }
}
