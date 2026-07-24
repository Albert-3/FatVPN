import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:singbox_mm/singbox_mm.dart';

import '../models/server_country.dart';
import 'api_client.dart';
import 'app_logger.dart';
import 'connection_settings_controller.dart';
import 'ping_service.dart';
import 'vless_config_parser.dart';

/// Owns the sing-box VPN tunnel and exposes real connection state to the UI,
/// replacing the fake local-timer toggle that used to live in [HomeScreen].
class VpnController extends ChangeNotifier {
  VpnController({
    required this.connectionSettings,
    ApiClient? apiClient,
    PingService? pingService,
    Future<String?> Function()? onUnauthorized,
  })  : _apiClient = apiClient ?? ApiClient(onUnauthorized: onUnauthorized),
        _pingService = pingService ?? PingService();

  final ConnectionSettingsController connectionSettings;
  final ApiClient _apiClient;
  final PingService _pingService;
  final SignboxVpn _vpn = SignboxVpn();
  final _storage = const FlutterSecureStorage();
  StreamSubscription<VpnConnectionState>? _stateSubscription;

  // Wall-clock start of the current tunnel session, persisted so it survives
  // the app being killed while the tunnel keeps running. Lets the UI show the
  // real elapsed time on relaunch instead of restarting the clock from zero.
  static const _sessionStartKey = 'vpn_session_started_at';
  DateTime? _sessionStartedAt;

  // Guards against overlapping runtime-state reconciliation polls (launch +
  // resume can both fire syncFromRuntime in quick succession).
  bool _reconciling = false;

  bool _initialized = false;
  // Set while a user-requested disconnect is in flight, so the
  // connected→disconnected transition it causes isn't misread as a runtime
  // tunnel failure by the diagnostics watcher below.
  bool _userDisconnecting = false;
  VpnConnectionState _state = VpnConnectionState.disconnected;
  String? _errorMessage;
  String? _connectedNodeName;

  VpnConnectionState get state => _state;
  String? get errorMessage => _errorMessage;
  String? get connectedNodeName => _connectedNodeName;
  bool get isConnected => _state == VpnConnectionState.connected;

  /// When the current session started (persisted across app restarts). Null
  /// when not connected. Used to render the session timer from real elapsed
  /// time rather than a per-second counter.
  DateTime? get sessionStartedAt => _sessionStartedAt;

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    // Restore the persisted session start *before* subscribing to the state
    // stream. On relaunch with a live tunnel the stream emits `connected`
    // almost immediately; if we hadn't loaded the real start first,
    // `_trackSessionStart` would see a null start and clobber the stored value
    // with `now`, resetting the timer to zero. Priming it here means the
    // `connected` event finds a non-null start and leaves it untouched.
    final storedStart = await _storage.read(key: _sessionStartKey);
    if (storedStart != null) {
      _sessionStartedAt = DateTime.tryParse(storedStart);
    }
    await _vpn.initialize(const SingboxRuntimeOptions(logLevel: 'warn'));
    _stateSubscription = _vpn.stateStream.listen((state) {
      final previous = _state;
      _state = state;
      _trackSessionStart(state);
      notifyListeners();
      // A stream event can land us back on a transient state — e.g. a stale
      // `connecting` that arrives *after* getState already settled us on
      // `connected` (both sample the same on-disk snapshot at slightly
      // different instants). Re-arm the self-heal poll so the UI doesn't get
      // stuck on "Connecting..."; the poll is a no-op if one is already
      // running or if we've already left the transient band.
      _maybeSelfHeal();
      // An unexpected drop to disconnected means the tunnel failed at runtime:
      // either it never established (connecting→disconnected) or it came up and
      // died shortly after (connected→disconnected, e.g. an NE memory jetsam
      // kill). Both leave the real reason only in sing-box's stderr, which the
      // NE can't stream to us — so pull the persisted diagnostics into the
      // support bundle (see PacketTunnelProvider.writeDiagnostics + getLastError).
      // A user-requested disconnect also lands here; skip it so it isn't logged
      // as a failure.
      if (state == VpnConnectionState.disconnected &&
          !_userDisconnecting &&
          (previous == VpnConnectionState.connecting ||
              previous == VpnConnectionState.connected)) {
        unawaited(_captureTunnelFailure());
      }
      if (state == VpnConnectionState.disconnected) {
        _userDisconnecting = false;
      }
    });
    _initialized = true;
  }

  /// Reconciles the UI state with a tunnel that may already be running — e.g.
  /// after the app was swiped away and relaunched while the VPN stayed up (the
  /// tunnel lives in the OS extension/service, not the app process). Without
  /// this a fresh launch shows the toggle as "disconnected" even though the
  /// system VPN is active. Safe to call on startup and on app resume.
  Future<void> syncFromRuntime() async {
    try {
      await _ensureInitialized();
      final actual = await _vpn.getState();
      await _applyRuntimeState(actual);
      // A tunnel that's still finishing its handshake when we relaunch reports
      // `connecting`/`preparing`. The `connected` transition may have been
      // published by the plugin *before* we subscribed to the state stream, so
      // the stream never delivers it — leaving the toggle stuck on
      // "Connecting..." until the user manually closed and reopened the app
      // (by which time the plugin had settled). Poll getState until it settles
      // so the UI self-heals instead.
      _maybeSelfHeal();
    } catch (e) {
      // Best-effort: if the platform query fails, leave the state untouched.
      log.w('syncFromRuntime failed: $e');
    }
  }

  /// Arms the runtime-state reconciliation poll when the UI is sitting on a
  /// transient (`connecting`/`preparing`) state, so a handshake that settled
  /// while we weren't listening still surfaces. No-op when already settled or
  /// when a poll is already in flight (guarded by [_reconciling]).
  void _maybeSelfHeal() {
    if (_isTransientState(_state)) {
      unawaited(_pollRuntimeStateUntilSettled());
    }
  }

  static bool _isTransientState(VpnConnectionState state) =>
      state == VpnConnectionState.connecting ||
      state == VpnConnectionState.preparing;

  /// Mirrors a state read from the plugin into the UI, restoring the persisted
  /// session start when we discover a live tunnel.
  Future<void> _applyRuntimeState(VpnConnectionState actual) async {
    if (actual == VpnConnectionState.connected && _sessionStartedAt == null) {
      // Restore the persisted start so the session timer resumes from real
      // elapsed time rather than restarting at zero on relaunch.
      final stored = await _storage.read(key: _sessionStartKey);
      _sessionStartedAt =
          (stored != null ? DateTime.tryParse(stored) : null) ?? DateTime.now();
    }
    if (actual != _state) {
      _state = actual;
      notifyListeners();
    }
  }

  /// Re-queries the plugin's connection state until it leaves the transient
  /// `connecting`/`preparing` band (or a timeout elapses), so a handshake that
  /// completed while we weren't listening still surfaces in the UI. Bails early
  /// if a stream event or user action already moved us off a transient state.
  Future<void> _pollRuntimeStateUntilSettled() async {
    if (_reconciling) return;
    _reconciling = true;
    try {
      // Generous window: a slow first handshake, or an OS-restarted tunnel
      // service re-establishing its connection, can stay transient well past
      // the old 20s budget.
      final deadline = DateTime.now().add(const Duration(seconds: 60));
      while (DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(seconds: 1));
        if (!_isTransientState(_state)) return;
        try {
          final actual = await _vpn.getState();
          await _applyRuntimeState(actual);
          if (!_isTransientState(actual)) return;
        } catch (e) {
          // A single failed query (channel momentarily busy) shouldn't abort the
          // whole poll — keep trying until the deadline.
          log.w('Runtime-state poll query failed: $e');
        }
      }
      // Still transient after the deadline: the tunnel almost certainly failed
      // to come up (e.g. the service died mid-handshake leaving a stale
      // `connecting` snapshot that never advances). Fall back to `disconnected`
      // so the UI shows a retriable state instead of an eternal spinner — the
      // user can just tap Connect rather than force-closing the app.
      if (_isTransientState(_state)) {
        log.w('Tunnel state never settled; treating as disconnected');
        _state = VpnConnectionState.disconnected;
        notifyListeners();
      }
    } finally {
      _reconciling = false;
    }
  }

  /// Records the session start the first time the tunnel comes up, keeping a
  /// persisted copy so [sessionStartedAt] survives an app restart.
  ///
  /// Deliberately does **not** clear the start on `disconnected`: automatic
  /// drops, reconnects, and OS-driven service restarts all pass through
  /// `disconnected`, and clearing here would restart the session clock from
  /// zero on every blip. The session timer must keep accumulating total time
  /// until the *user* turns the VPN off — see [disconnect]'s `endSession`.
  void _trackSessionStart(VpnConnectionState state) {
    if (state == VpnConnectionState.connected && _sessionStartedAt == null) {
      _sessionStartedAt = DateTime.now();
      unawaited(_storage.write(
        key: _sessionStartKey,
        value: _sessionStartedAt!.toIso8601String(),
      ));
    }
  }

  /// Clears the persisted session start so the next connection's timer starts
  /// from zero. Invoked only when the user fully turns the VPN off.
  void _clearSessionStart() {
    _sessionStartedAt = null;
    unawaited(_storage.delete(key: _sessionStartKey));
  }

  Future<void> connectToBestNode(
    ServerCountry country,
    String accessToken, {
    required String networkErrorMessage,
  }) async {
    await _connect(country.nodes, accessToken, networkErrorMessage: networkErrorMessage);
  }

  /// Connects to the fastest node across *all* countries — used when the
  /// user hasn't explicitly chosen a location yet (still on the default
  /// "Best Server" state) so first launch doesn't force a manual pick.
  ///
  /// Returns the country the chosen node belongs to, so the caller can
  /// reflect the auto-picked location in the UI.
  Future<ServerCountry?> connectToBestOverall(
    List<ServerCountry> countries,
    String accessToken, {
    required String networkErrorMessage,
  }) async {
    final allNodes = countries.expand((c) => c.nodes).toList();
    final node = await _connect(allNodes, accessToken, networkErrorMessage: networkErrorMessage);
    if (node == null) return null;
    return countries.firstWhere((c) => c.nodes.contains(node));
  }

  /// True for low-level connectivity failures (no signal, airplane mode,
  /// DNS unreachable) reaching the BFF — as opposed to app/server-level
  /// errors, which already carry a user-facing message.
  bool _isNetworkError(Object e) => e is SocketException || e is http.ClientException;

  Future<ServerNode?> _connect(
    List<ServerNode> candidates,
    String accessToken, {
    required String networkErrorMessage,
  }) async {
    _errorMessage = null;
    _userDisconnecting = false;
    _state = VpnConnectionState.connecting;
    notifyListeners();

    try {
      await _ensureInitialized();

      // `/servers` lists every Remnawave node regardless of squad, but
      // `/config` only contains entries for nodes in this user's subscription —
      // narrow to the intersection before picking by ping, otherwise the "best"
      // node can be one this subscription can't use.
      final (content, _) = await _apiClient.getConfig(accessToken);
      final uris = parseConfigUris(content);
      final usableNodes = candidates.where((n) => findUriForNode(uris, n) != null).toList();
      if (usableNodes.isEmpty) {
        throw StateError('No available node in this subscription');
      }

      final node = await _pickBestNode(usableNodes);
      final uri = findUriForNode(uris, node)!;

      log.i('Connecting to node "${node.name}" '
          '(dns=${connectionSettings.dnsPreset.name}, '
          'stack=${connectionSettings.networkStack.name}, '
          'split=${connectionSettings.splitTunnelEnabled})');
      // Built fresh here so DNS / network-stack preference edits in Settings
      // take effect on this (re)connect.
      await _vpn.connectManualConfigLink(
        configLink: uri,
        featureSettings: connectionSettings.buildFeatureSettings(),
      );
      _connectedNodeName = node.name;
      log.i('Tunnel established to "${node.name}"');
      return node;
    } catch (e) {
      _state = VpnConnectionState.error;
      _errorMessage = e is SignboxVpnException
          ? e.message
          : _isNetworkError(e)
          ? networkErrorMessage
          : e.toString();
      log.e('Connect failed', e.toString());
      notifyListeners();
      rethrow;
    }
  }

  Future<ServerNode> _pickBestNode(List<ServerNode> nodes) async {
    ServerNode? best;
    int? bestPing;
    for (final node in nodes) {
      final ms = await _pingService.pingMs(node.address, node.port);
      if (ms != null && (bestPing == null || ms < bestPing)) {
        best = node;
        bestPing = ms;
      }
    }
    return best ?? nodes.first;
  }

  /// Pulls the tunnel's last-failure report (on iOS, the PacketTunnel
  /// extension's persisted reason + sing-box stderr tail) into the app log so it
  /// lands in the shareable support bundle, and surfaces it to the UI.
  Future<void> _captureTunnelFailure() async {
    try {
      final err = await _vpn.getLastError();
      if (err != null && err.trim().isNotEmpty) {
        _errorMessage = err;
        log.e('Tunnel failed at runtime', err);
        notifyListeners();
      } else {
        log.w('Tunnel dropped during connect but reported no diagnostics');
      }
    } catch (e) {
      log.w('Failed to read tunnel diagnostics: $e');
    }
  }

  /// Stops the tunnel. [endSession] distinguishes a full user-initiated
  /// power-off (resets the session timer) from an internal teardown that's part
  /// of a reconnect — e.g. switching server/location or re-applying connection
  /// settings — which keeps the VPN "on" and so must preserve the timer.
  Future<void> disconnect({bool endSession = true}) async {
    log.i('Disconnecting tunnel (endSession=$endSession)');
    _userDisconnecting = true;
    if (endSession) {
      _clearSessionStart();
    }
    await _vpn.stop();
    _connectedNodeName = null;
  }

  @override
  void dispose() {
    _stateSubscription?.cancel();
    super.dispose();
  }
}
