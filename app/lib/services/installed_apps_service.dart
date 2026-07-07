import 'package:flutter/services.dart';

/// A launchable (app-drawer) app returned by the native `fatvpn/apps` channel.
class LaunchableApp {
  const LaunchableApp({required this.name, required this.packageName, this.icon});

  final String name;
  final String packageName;
  final Uint8List? icon;
}

/// Lists installed apps that appear in the launcher — the right set for the
/// split-tunneling picker (excludes background services/overlays). Backed by a
/// native `queryIntentActivities(MAIN/LAUNCHER)` call, so no QUERY_ALL_PACKAGES.
class InstalledAppsService {
  static const _channel = MethodChannel('fatvpn/apps');

  static Future<List<LaunchableApp>> getLaunchableApps() async {
    final raw = await _channel.invokeListMethod<Map<dynamic, dynamic>>('getLaunchableApps');
    if (raw == null) return const [];
    return raw.map((m) {
      final map = Map<String, dynamic>.from(m);
      final pkg = map['packageName'] as String;
      return LaunchableApp(
        name: (map['name'] as String?)?.trim().isNotEmpty == true
            ? map['name'] as String
            : pkg,
        packageName: pkg,
        icon: map['icon'] as Uint8List?,
      );
    }).toList();
  }
}
