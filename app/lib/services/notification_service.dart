import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../l10n/strings.dart';

/// Schedules **local** (client-side) reminders before the subscription/trial
/// expires — no server or FCM involved. The app knows the expiry from
/// `AuthSession.expiresAt` and re-plans reminders whenever that changes.
///
/// Reminders fire at 3 days before, 1 day before, 30 minutes before, 15 minutes
/// before, and at the moment of expiry (only those still in the future). The
/// two short-notice (minute) reminders use an exact alarm so they aren't delayed
/// past expiry by Doze. Since the session only carries `expiresAt` (not whether
/// it's a trial or a paid plan), the copy is intentionally generic.
class NotificationService {
  NotificationService({FlutterLocalNotificationsPlugin? plugin})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  bool _initialized = false;

  /// Signature of the last scheduled state (`expiry|language`). Guards against
  /// the frequent `notifyListeners` from AuthController re-scheduling needlessly.
  String? _lastSignature;

  static const _channelId = 'subscription_reminders';
  static const _channelName = 'Subscription reminders';
  static const _channelDescription =
      'Reminders before your subscription or trial ends';

  // Fixed ids so a re-sync overwrites the previous schedule instead of stacking.
  static const _idExpiry3d = 2001;
  static const _idExpiry1d = 2002;
  static const _idExpired = 2003;
  static const _idExpiry30m = 2004;
  static const _idExpiry15m = 2005;

  /// Initializes the plugin, the timezone database, and requests the OS
  /// notification permission (Android 13+ / iOS). Safe to call once at startup.
  Future<void> init() async {
    if (_initialized) return;
    // zonedSchedule fires at an absolute instant, so leaving tz.local as the
    // default (UTC) is fine — TZDateTime.from preserves the exact moment. We
    // still initialize the DB so tz.local resolves without throwing.
    tz_data.initializeTimeZones();

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings();
    await _plugin.initialize(
      const InitializationSettings(android: android, iOS: ios),
    );

    await _requestPermission();
    _initialized = true;
  }

  Future<void> _requestPermission() async {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.requestNotificationsPermission();
    // Needed for the exact short-notice (30/15-min) reminders on Android 12+;
    // no-op on older APIs. Best-effort — ignore if the user declines.
    await android?.requestExactAlarmsPermission();

    final ios = _plugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
    await ios?.requestPermissions(alert: true, badge: true, sound: true);
  }

  /// (Re)schedules the reminders for [expiresAt]. Pass null (e.g. after sign-out)
  /// to cancel all pending reminders. Deduplicates so repeated calls with the
  /// same expiry + language are cheap no-ops.
  Future<void> syncFor(
    DateTime? expiresAt,
    Strings strings,
    AppLanguage language,
  ) async {
    if (!_initialized) return;

    final signature = expiresAt == null
        ? 'none'
        : '${expiresAt.toUtc().toIso8601String()}|${language.name}';
    if (signature == _lastSignature) return;
    _lastSignature = signature;

    await _cancelAll();
    if (expiresAt == null) return;

    final now = DateTime.now();
    await _scheduleIfFuture(
      _idExpiry3d,
      expiresAt.subtract(const Duration(days: 3)),
      now,
      strings.notifExpiringSoonTitle,
      strings.notifExpiresInDays(3),
    );
    await _scheduleIfFuture(
      _idExpiry1d,
      expiresAt.subtract(const Duration(days: 1)),
      now,
      strings.notifExpiringSoonTitle,
      strings.notifExpiresInDays(1),
    );
    // Short-notice reminders — exact so Doze can't push them past expiry.
    await _scheduleIfFuture(
      _idExpiry30m,
      expiresAt.subtract(const Duration(minutes: 30)),
      now,
      strings.notifExpiringSoonTitle,
      strings.notifExpiresInMinutes(30),
      exact: true,
    );
    await _scheduleIfFuture(
      _idExpiry15m,
      expiresAt.subtract(const Duration(minutes: 15)),
      now,
      strings.notifExpiringSoonTitle,
      strings.notifExpiresInMinutes(15),
      exact: true,
    );
    await _scheduleIfFuture(
      _idExpired,
      expiresAt,
      now,
      strings.notifExpiredTitle,
      strings.notifExpiredBody,
    );
  }

  Future<void> _cancelAll() async {
    await _plugin.cancel(_idExpiry3d);
    await _plugin.cancel(_idExpiry1d);
    await _plugin.cancel(_idExpiry30m);
    await _plugin.cancel(_idExpiry15m);
    await _plugin.cancel(_idExpired);
  }

  Future<void> _scheduleIfFuture(
    int id,
    DateTime when,
    DateTime now,
    String title,
    String body, {
    bool exact = false,
  }) async {
    if (!when.isAfter(now)) return;
    try {
      await _plugin.zonedSchedule(
        id,
        title,
        body,
        tz.TZDateTime.from(when, tz.local),
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: _channelDescription,
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(),
        ),
        // Day-scale reminders don't need alarm-clock precision (inexact avoids
        // SCHEDULE_EXACT_ALARM); the minute-scale ones must be exact or Doze can
        // delay them past expiry.
        androidScheduleMode: exact
            ? AndroidScheduleMode.exactAllowWhileIdle
            : AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
    } catch (_) {
      // Never let a scheduling failure bubble into the auth/UI flow.
    }
  }
}
