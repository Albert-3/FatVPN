import 'dart:async';

import 'package:flutter/services.dart';
import 'package:singbox_mm/singbox_mm.dart';

import '../l10n/strings.dart';
import '../models/auth_session.dart';
import '../models/server_country.dart';
import '../utils/country_flag.dart';
import 'api_client.dart';
import 'app_logger.dart';
import 'connection_settings_controller.dart';
import 'home_widget_bridge.dart';
import 'locale_controller.dart';
import 'token_storage.dart';
import 'vpn_controller.dart';

/// Channel the background entrypoint reports its verdict on. The native side
/// (`WidgetConnectService`) is waiting on it to decide whether to drop its
/// "connecting" notification or to open the app, because the connect needs a
/// screen this process does not have.
const MethodChannel widgetConnectChannel = MethodChannel('fatvpn/widget_connect');

/// How a widget-initiated connect ended.
enum WidgetConnectOutcome {
  /// The tunnel is up (or on its way up) — nothing else to do.
  connected,

  /// This process cannot finish the job and the app has to: there is no
  /// session, the subscription has lapsed, or the OS wants to show its VPN
  /// consent dialog, which needs an Activity. The caller opens the app on
  /// `fatvpn://widget/connect` so the user lands somewhere they can act.
  handOverToApp,

  /// Tried and failed — a dead network, a subscription with nothing usable in
  /// it, a tunnel that refused to start.
  failed,
}

/// Brings the tunnel up **without the app** — the whole point of the widget's
/// power button.
///
/// Runs in a background Flutter engine started by the widget's tap (Android:
/// `WidgetConnectService`), so it has no UI, no Activity and no localization
/// context. What it deliberately does *not* do is start from the config left on
/// disk by the last session: bringing a tunnel up needs a live entitlement
/// check — `/servers` and `/config` answer 402 the moment a subscription lapses
/// — and reconnecting a user on credentials the panel has already revoked is
/// the exact defect class the 2026-07-27 audit found in the iOS on-demand
/// logic. So this runs the same three steps the home screen runs: refresh the
/// session, ask the BFF what this subscription can reach, connect to the best
/// of it.
///
/// Deliberately not built on [AuthController]: that one owns deep links, a
/// pairing poll and trial recovery, none of which mean anything here, and its
/// `AppLinks` subscription wants an Activity we do not have.
class WidgetConnectRunner {
  WidgetConnectRunner({
    TokenStorage? tokenStorage,
    ApiClient? apiClient,
    ConnectionSettingsController? connectionSettings,
    LocaleController? locale,
    VpnController Function(ConnectionSettingsController, ApiClient)? buildVpn,
  })  : _tokenStorage = tokenStorage ?? TokenStorage(),
        _connectionSettings =
            connectionSettings ?? ConnectionSettingsController(),
        _locale = locale ?? LocaleController(),
        _buildVpn = buildVpn ??
            ((settings, api) =>
                VpnController(connectionSettings: settings, apiClient: api)) {
    _api = apiClient ?? ApiClient();
    _api
      ..readAccessToken = _currentAccessToken
      ..onUnauthorized = _refreshAccessToken;
  }

  final TokenStorage _tokenStorage;
  final ConnectionSettingsController _connectionSettings;
  final LocaleController _locale;
  final VpnController Function(ConnectionSettingsController, ApiClient)
      _buildVpn;
  late final ApiClient _api;

  AuthSession? _session;
  Future<String?>? _refreshInFlight;

  /// Same margin the app uses ([AuthController]): refresh only a token that is
  /// about to run out, because every refresh rotates the refresh token and
  /// every rotation is a chance to lose the session family.
  static const _accessTokenLeeway = Duration(minutes: 2);

  /// How long to wait for the tunnel to report `connected` before finishing
  /// anyway. Not a failure when it elapses — the tunnel has its own foreground
  /// service by then and the widget follows its state broadcast — this only
  /// decides how long the caller's "connecting…" notification hangs around.
  static const _establishTimeout = Duration(seconds: 25);
  static const _establishPoll = Duration(milliseconds: 400);

  Future<WidgetConnectOutcome> run() async {
    final session = await _readSession();
    if (session == null) {
      log.i('Widget connect: no stored session — handing over to the app');
      return WidgetConnectOutcome.handOverToApp;
    }
    if (session.isExpired) {
      // The renew screen is the honest answer, and only the app has one.
      log.i('Widget connect: subscription lapsed — handing over to the app');
      return WidgetConnectOutcome.handOverToApp;
    }

    await Future.wait([_connectionSettings.load(), _locale.load()]);

    final List<ServerCountry> servers;
    try {
      servers = await _api.getUsableServers();
    } on ApiException catch (e) {
      // 401: the refresh above could not save the session. 402: the panel says
      // the subscription is over. Both are stories the app tells properly.
      final handOver = e.statusCode == 401 || e.statusCode == 402;
      log.w('Widget connect: /servers failed ($e)');
      return handOver
          ? WidgetConnectOutcome.handOverToApp
          : WidgetConnectOutcome.failed;
    } catch (e) {
      log.w('Widget connect: could not load servers ($e)');
      return WidgetConnectOutcome.failed;
    }
    if (servers.isEmpty) {
      log.w('Widget connect: the subscription lists no servers');
      return WidgetConnectOutcome.failed;
    }

    final strings = stringsFor(_locale.language);
    final vpn = _buildVpn(_connectionSettings, _api)
      ..noUsableNodesMessage = strings.noUsableServers;
    try {
      final chosen = await _connect(vpn, servers, strings);
      await _publish(vpn, chosen, session);
      await _awaitEstablished(vpn);
      await _publish(vpn, chosen, session);
      return vpn.state == VpnConnectionState.error
          ? WidgetConnectOutcome.failed
          : WidgetConnectOutcome.connected;
    } on SignboxVpnException catch (e) {
      if (_needsAScreen(e.code)) {
        // The plugin wants a permission dialog, and a dialog needs an Activity
        // this process does not have. That is every *first* connect on a
        // device: the OS asks the user to allow the VPN. The app can show it.
        log.w('Widget connect: the tunnel needs the app (${e.code}: ${e.message})');
        return WidgetConnectOutcome.handOverToApp;
      }
      // A connect that was actually attempted and failed. Deliberately *not* a
      // hand-over: the user asked for a tunnel, not for an app to be opened at
      // them, and a node that would not come up is answered by tapping again —
      // the next attempt re-picks the node.
      log.w('Widget connect: the tunnel refused to start (${e.code}: ${e.message})');
      return WidgetConnectOutcome.failed;
    } catch (e) {
      log.w('Widget connect failed: $e');
      return WidgetConnectOutcome.failed;
    } finally {
      vpn.dispose();
    }
  }

  /// Plugin error codes that mean "this needs a screen", not "this failed".
  ///
  /// All four come from the same place: the plugin asking for a permission and
  /// finding no Activity to ask through (see PluginPermissionCoordinator on
  /// Android). Anything else is a tunnel that genuinely would not start.
  static bool _needsAScreen(String code) => const <String>{
        'NO_ACTIVITY',
        'PERMISSION_DENIED',
        'PERMISSION_PENDING',
        'NOTIFICATION_PERMISSION_DENIED',
      }.contains(code);

  /// Always the fastest node overall — the in-app country choice is
  /// deliberately ignored here (user decision, 2026-08-01): a widget press
  /// with the app closed means "protect me now", not "resume my last pick".
  /// The choice itself stays on disk untouched, for the app's own use.
  Future<ServerCountry?> _connect(
    VpnController vpn,
    List<ServerCountry> servers,
    Strings strings,
  ) {
    return vpn.connectToBestOverall(
      servers,
      networkErrorMessage: strings.couldNotReachServer,
    );
  }

  Future<void> _awaitEstablished(VpnController vpn) async {
    final deadline = DateTime.now().add(_establishTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (vpn.state == VpnConnectionState.connected ||
          vpn.state == VpnConnectionState.error ||
          vpn.state == VpnConnectionState.disconnected) {
        return;
      }
      await Future.delayed(_establishPoll);
    }
  }

  /// Publishes the **whole** snapshot, not a patch of it.
  ///
  /// [HomeWidgetBridge] patches an in-memory record, and this process has an
  /// empty one — the app's is in another isolate. Publishing half a snapshot
  /// would therefore blank the language and the subscription the app wrote,
  /// which is why every field is filled in here from what this process knows.
  Future<void> _publish(
    VpnController vpn,
    ServerCountry? country,
    AuthSession session,
  ) {
    final strings = stringsFor(_locale.language);
    return HomeWidgetBridge.instance.update(
      state: vpn.state,
      language: _locale.language,
      signedIn: true,
      locationLabel: country == null
          ? null
          : countryLabel(country.country, strings.whitelistLocations),
      flagEmoji: country == null ? null : countryCodeToFlagEmoji(country.flag),
      clearLocation: country == null,
      connectedAt: vpn.sessionStartedAt,
      clearConnectedAt: vpn.sessionStartedAt == null,
      expiresAt: session.expiresAt,
    );
  }

  Future<AuthSession?> _readSession() async {
    try {
      _session = await _tokenStorage.read();
    } catch (e) {
      log.w('Widget connect: could not read the stored session ($e)');
      _session = null;
    }
    return _session;
  }

  Future<String?> _currentAccessToken() async {
    final session = _session;
    if (session == null) return null;
    final expiry = session.accessTokenExpiresAt;
    if (expiry != null &&
        expiry.difference(DateTime.now()) > _accessTokenLeeway) {
      return session.accessToken;
    }
    return await _refreshAccessToken() ?? session.accessToken;
  }

  /// One rotation at a time, however many callers ask — the same coalescing
  /// [AuthController] does, for the same reason: two rotations of one refresh
  /// token is what reuse detection revokes a session family for.
  Future<String?> _refreshAccessToken() {
    return _refreshInFlight ??= _rotate().whenComplete(() {
      _refreshInFlight = null;
    });
  }

  Future<String?> _rotate() async {
    final session = _session;
    if (session == null || !session.hasRefreshToken) return null;
    try {
      final fresh = await _api.refreshSession(session.refreshToken);
      _session = fresh;
      // Persisted immediately: the refresh token is rotated server-side the
      // moment that call returns, so a process that dies before writing it back
      // leaves the app holding one the BFF will refuse — and presenting a
      // revoked token is what forces a full re-pair.
      await _tokenStorage.save(fresh);
      return fresh.accessToken;
    } catch (e) {
      log.w('Widget connect: could not refresh the session ($e)');
      return null;
    }
  }
}
