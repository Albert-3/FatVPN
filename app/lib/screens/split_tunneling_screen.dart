import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../l10n/strings.dart';
import '../services/connection_settings_controller.dart';
import '../services/installed_apps_service.dart';
import '../theme/app_colors.dart';

/// Lets the user pick installed apps that bypass the VPN tunnel
/// (sing-box `exclude_package`). Android-only; the selection is persisted in
/// [ConnectionSettingsController] and applied on the next connect.
class SplitTunnelingScreen extends StatefulWidget {
  const SplitTunnelingScreen({super.key, required this.connectionSettings});

  final ConnectionSettingsController connectionSettings;

  @override
  State<SplitTunnelingScreen> createState() => _SplitTunnelingScreenState();
}

class _SplitTunnelingScreenState extends State<SplitTunnelingScreen> {
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

  void _toggleApp(String packageName, bool bypass) {
    final next = Set<String>.from(widget.connectionSettings.bypassPackages);
    if (bypass) {
      next.add(packageName);
    } else {
      next.remove(packageName);
    }
    widget.connectionSettings.setBypassPackages(next);
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: AnimatedBuilder(
          animation: widget.connectionSettings,
          builder: (context, _) {
            final enabled = widget.connectionSettings.splitTunnelEnabled;
            return Column(
              children: [
                _buildHeader(context, s, enabled),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      s.appsBypassVpn,
                      style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                  child: Text(
                    s.appliesOnNextConnection,
                    style: const TextStyle(color: AppColors.textSecondary, fontSize: 11),
                  ),
                ),
                if (!enabled)
                  Expanded(child: _DisabledHint(text: s.splitTunnelDisabledHint))
                else
                  Expanded(child: _buildAppList(s)),
              ],
            );
          },
        ),
      ),
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
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
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
              final bypass = widget.connectionSettings.bypassPackages.contains(app.packageName);
              return _AppTile(
                app: app,
                bypass: bypass,
                onChanged: (v) => _toggleApp(app.packageName, v),
              );
            },
          ),
        ),
      ],
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
            onChanged: (v) => widget.connectionSettings.setSplitTunnelEnabled(v),
          ),
        ],
      ),
    );
  }
}

class _AppTile extends StatelessWidget {
  const _AppTile({required this.app, required this.bypass, required this.onChanged});

  final LaunchableApp app;
  final bool bypass;
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
        value: bypass,
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

class _DisabledHint extends StatelessWidget {
  const _DisabledHint({required this.text});

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
              style: const TextStyle(color: AppColors.textSecondary, fontSize: 14, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}
