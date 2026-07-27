import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:singbox_mm/singbox_mm.dart';

import '../models/server_country.dart';
import 'api_client.dart';
import 'app_logger.dart';
import 'auto_switch_policy.dart';
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
    AutoSwitchPolicy? autoSwitchPolicy,
    Future<String?> Function()? onUnauthorized,
  })  : _apiClient = apiClient ?? ApiClient(onUnauthorized: onUnauthorized),
        _pingService = pingService ?? PingService(),
        _autoSwitchPolicy = autoSwitchPolicy ?? AutoSwitchPolicy();

  final ConnectionSettingsController connectionSettings;
  final ApiClient _apiClient;
  final PingService _pingService;
  final AutoSwitchPolicy _autoSwitchPolicy;
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
  ServerNode? _connectedNode;

  // True when the tunnel came up but a probe through it reached nothing. See
  // [_verifyTunnelCarriesTraffic].
  bool _tunnelNotPassingTraffic = false;

  // ── Auto-switch: keeping a live session on a good node ────────────────────
  // Everything needed to re-run the connect that established this session, so
  // the watchdog below can move it to a better node without the UI's help. See
  // [_evaluateAutoSwitch].
  Timer? _autoSwitchTimer;
  List<ServerNode> _autoSwitchPool = const [];
  String? _autoSwitchAccessToken;
  String? _autoSwitchNetworkErrorMessage;
  bool _autoSwitchInProgress = false;
  DateTime? _lastAutoSwitchAt;

  /// How often a live session re-measures its alternatives. Long on purpose:
  /// the pings cost real requests, and nothing here is urgent enough to spend
  /// the user's battery on a tighter loop.
  static const _autoSwitchInterval = Duration(minutes: 3);

  /// Minimum quiet period after a switch. Without it a pair of nodes whose
  /// latencies straddle the threshold could bounce the session back and forth,
  /// which is worse than either server.
  static const _autoSwitchCooldown = Duration(minutes: 10);

  /// Notified when the session moves itself to a different node, so the UI can
  /// reflect the new location and tell the user why their connections blipped.
  void Function(ServerNode from, ServerNode to)? onAutoSwitched;

  VpnConnectionState get state => _state;
  String? get errorMessage => _errorMessage;
  String? get connectedNodeName => _connectedNode?.name;

  /// The node this session is currently running on. Changes without any user
  /// action when the auto-switch moves the session, which is how the UI learns
  /// to re-render the location card.
  ServerNode? get connectedNode => _connectedNode;
  bool get isConnected => _state == VpnConnectionState.connected;

  /// True while the tunnel is established but nothing gets through it.
  ///
  /// "Connected" only ever meant "the OS brought the tun device up", which
  /// happens before — and independently of — sing-box reaching the server. A
  /// server that accepts no traffic therefore looked exactly like a working
  /// one: green toggle, running session timer, no internet. This flag is what
  /// lets the UI tell those two apart.
  bool get tunnelNotPassingTraffic => _tunnelNotPassingTraffic;

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
        // A verdict about traffic only describes a tunnel that exists; carrying
        // it into the next connection would blame a new server for the old
        // one's failure.
        _tunnelNotPassingTraffic = false;
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
      if (actual == VpnConnectionState.connected) {
        // A tunnel can die at runtime *without* changing state: sing-box loses
        // the underlay and stops passing packets, but NEVPNStatus stays
        // .connected, so the UI keeps saying "connected" while nothing works.
        // The connected→disconnected watcher below never fires for that, so
        // pull whatever the extension persisted every time we reconcile a live
        // tunnel — it's the only way the stderr tail reaches the support bundle
        // for this failure mode.
        unawaited(_logTunnelDiagnostics());
      }
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
      final parsed = stored != null ? DateTime.tryParse(stored) : null;
      if (parsed != null) {
        _sessionStartedAt = parsed;
      } else {
        // Nothing usable on disk, yet the tunnel is up — the session started
        // outside this app process (OS-restarted extension, or the app was
        // killed before the start could be written). Anchor it now *and
        // persist it*: leaving it in memory only made the reset permanent,
        // because the next relaunch would land here again and restart the
        // clock from zero on every single open.
        _rememberSessionStart(DateTime.now());
      }
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
      _rememberSessionStart(DateTime.now());
    }
  }

  /// Sets the session start and writes it through to storage, so the timer
  /// survives the app being killed while the tunnel keeps running. Every place
  /// that anchors a new session must go through here — an in-memory-only start
  /// silently resets the clock on the next launch.
  void _rememberSessionStart(DateTime start) {
    _sessionStartedAt = start;
    unawaited(_storage.write(
      key: _sessionStartKey,
      value: start.toIso8601String(),
    ));
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
  /// DNS unreachable, or a request that ran out of time) reaching the BFF — as
  /// opposed to app/server-level errors, which already carry a user-facing
  /// message. A timeout belongs here: with the app's traffic inside the tunnel,
  /// that is what a request through a dying one looks like.
  bool _isNetworkError(Object e) =>
      e is SocketException || e is http.ClientException || e is TimeoutException;

  /// Endpoint the post-connect probe hits. Google's captive-portal check:
  /// an empty 204, served from everywhere, and designed for exactly this.
  static const _trafficProbeUrl = 'https://www.gstatic.com/generate_204';
  static const _trafficProbeTimeout = Duration(seconds: 8);

  // The tunnel reports "established" as soon as the interface is up, a moment
  // before the OS finishes installing its routes. Probing inside that window is
  // worthless: the request slips out over the *old* default route and succeeds
  // no matter how broken the tunnel is — which is exactly how an unreachable
  // server passed this check during testing. Wait for routing to settle first.
  static const _trafficProbeSettleDelay = Duration(seconds: 3);
  static const _trafficProbeRetryDelay = Duration(seconds: 2);

  /// sing-box's local control API (`experimental.clash_api`), on the port
  /// SingboxFeatureSettings.clashApiPort defaults to.
  static const _singboxApiBase = 'http://127.0.0.1:16756';

  /// Confirms the established tunnel actually carries traffic, and flags it when
  /// it doesn't.
  ///
  /// This is reliable precisely *because* the tun device is up: with a default
  /// route into the tunnel there is no direct path left, so a dead outbound
  /// can't be masked by the request slipping out around it — it simply times
  /// out. A single failure isn't enough to accuse the server, so one retry
  /// absorbs a transient blip.
  ///
  /// Never tears the tunnel down: a probe is weaker evidence than the user's
  /// own experience, and yanking a connection out from under someone over one
  /// unreachable URL would be worse than the symptom.
  Future<void> _verifyTunnelCarriesTraffic() async {
    await Future.delayed(_trafficProbeSettleDelay);
    for (var attempt = 0; attempt < 2; attempt++) {
      // The user may have switched servers or powered off while we probed;
      // a verdict about a tunnel that no longer exists is meaningless.
      if (_state != VpnConnectionState.connected) return;
      if (attempt > 0) await Future.delayed(_trafficProbeRetryDelay);
      final reachable = await _probeThroughTunnel();
      // No verdict — the probe itself couldn't run. Staying silent is right:
      // an unprovable claim must not be turned into an accusation.
      if (reachable == null) return;
      if (reachable) {
        if (_tunnelNotPassingTraffic) {
          _tunnelNotPassingTraffic = false;
          notifyListeners();
        }
        return;
      }
    }
    if (_state != VpnConnectionState.connected) return;
    log.w('Tunnel is up but the probe reached nothing — outbound looks dead');
    _tunnelNotPassingTraffic = true;
    notifyListeners();
    unawaited(_logTunnelDiagnostics());
    // This is exactly the case the auto-switch exists for: the node is up
    // enough to hold a tunnel but useless to the user. Don't wait for the next
    // scheduled round — a session that carries nothing has nothing to lose.
    unawaited(_evaluateAutoSwitch(tunnelIsDead: true));
  }

  /// True when traffic gets through, false when it demonstrably doesn't, null
  /// when the probe couldn't be carried out and nothing can be concluded.
  ///
  /// The two platforms need opposite approaches, because the tunnel treats this
  /// app's own traffic differently on each:
  ///
  /// * **Android** — the tunnel service deliberately keeps this app's sockets
  ///   out of the tun device ("prevent self-capture loops", see
  ///   VpnTunBuilderConfigurator). A request issued from here therefore never
  ///   touches the tunnel and comes back successful no matter how dead it is —
  ///   which is exactly how a server that passed no traffic at all was measured
  ///   as healthy during testing. So we ask sing-box itself over its local
  ///   Clash API: its delay test dials the probe URL *through the active
  ///   outbound*, which is the question we actually want answered.
  /// * **iOS** — the container app's traffic does go through the packet tunnel,
  ///   so a plain request is both possible and correct. The Clash API is not an
  ///   option there: it listens inside the network extension, a separate
  ///   process whose 127.0.0.1 this app cannot reach.
  Future<bool?> _probeThroughTunnel() {
    return Platform.isAndroid ? _probeViaSingboxApi() : _probeDirectly();
  }

  Future<bool?> _probeDirectly() async {
    try {
      final response = await http
          .get(Uri.parse(_trafficProbeUrl))
          .timeout(_trafficProbeTimeout);
      return response.statusCode >= 200 && response.statusCode < 400;
    } catch (_) {
      return false;
    }
  }

  Future<bool?> _probeViaSingboxApi() async {
    // Fetching the tag doubles as a liveness check on the API itself: if this
    // succeeds, anything that goes wrong afterwards is about the outbound, not
    // about our ability to ask.
    final tag = await _activeOutboundTag();
    if (tag == null) return null;
    try {
      final uri = Uri.parse('$_singboxApiBase/proxies/${Uri.encodeComponent(tag)}/delay')
          .replace(queryParameters: <String, String>{
        'url': _trafficProbeUrl,
        'timeout': '${_trafficProbeTimeout.inMilliseconds}',
      });
      final response = await http
          .get(uri)
          .timeout(_trafficProbeTimeout + const Duration(seconds: 4));
      return response.statusCode == 200;
    } catch (_) {
      // A dead outbound makes this request hang rather than fail: sing-box
      // accepts the connection and then never answers, ignoring the `timeout`
      // parameter entirely (observed: 30s, zero bytes). Our own timeout is
      // therefore the verdict, not an inconclusive result — the API answered a
      // moment ago, so silence here is the outbound's silence.
      return false;
    }
  }

  /// Tag of the proxy outbound currently in use, read back from sing-box.
  ///
  /// Taken from the running instance rather than assumed from the node we asked
  /// for: the tag is the config link's own fragment, which need not match the
  /// node name `/servers` reports.
  Future<String?> _activeOutboundTag() async {
    try {
      final response = await http
          .get(Uri.parse('$_singboxApiBase/proxies'))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) return null;
      final proxies = (jsonDecode(response.body) as Map<String, dynamic>)['proxies'];
      if (proxies is! Map<String, dynamic>) return null;
      for (final entry in proxies.entries) {
        final value = entry.value;
        if (value is! Map<String, dynamic>) continue;
        final type = (value['type'] as String?)?.toLowerCase();
        if (type == null || _nonProxyOutboundTypes.contains(type)) continue;
        return entry.key;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Outbound types that are not the server we want to test.
  static const _nonProxyOutboundTypes = <String>{
    'direct',
    'block',
    'reject',
    'dns',
    'selector',
    'urltest',
    'compatible',
    'fallback',
  };

  /// Brings the tunnel up on one of [candidates].
  ///
  /// [preferred] names a node the caller has already decided on — used by the
  /// auto-switch, which has just measured every candidate and must not have its
  /// verdict overruled by a second round of pings here. The full [candidates]
  /// list still becomes the pool the session can later move within, so
  /// narrowing the connect to one node doesn't strand the session on it.
  Future<ServerNode?> _connect(
    List<ServerNode> candidates,
    String accessToken, {
    required String networkErrorMessage,
    ServerNode? preferred,
  }) async {
    _errorMessage = null;
    _tunnelNotPassingTraffic = false;
    _userDisconnecting = false;
    _state = VpnConnectionState.connecting;
    notifyListeners();

    try {
      await _ensureInitialized();

      // Nodes built from `/config` already carry their exact link (see
      // ApiClient.getUsableServers). Re-deriving it by address would pick
      // whichever inbound happened to come first when a host publishes more
      // than one — which is how the Hysteria2 entries stayed unreachable even
      // once they were listed. Only fall back to an address lookup for nodes
      // that came straight from `/servers`.
      final (content, _) = await _apiClient.getConfig(accessToken);
      final uris = parseConfigUris(content);
      String? uriFor(ServerNode n) => n.configUri ?? findUriForNode(uris, n);

      final usableNodes = candidates.where((n) => uriFor(n) != null).toList();
      if (usableNodes.isEmpty) {
        throw StateError('No available node in this subscription');
      }

      final node = preferred != null && usableNodes.contains(preferred)
          ? preferred
          : await _pickBestNode(usableNodes);
      final uri = uriFor(node)!;

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
      _connectedNode = node;
      log.i('Tunnel established to "${node.name}"');
      // Watch this session from here on, so a node that degrades later doesn't
      // hold it for the rest of the day.
      _armAutoSwitch(usableNodes, accessToken, networkErrorMessage);
      // Deliberately not awaited: the tunnel is up, so the UI should say so
      // immediately. The probe corrects that claim a few seconds later if
      // nothing actually gets through.
      unawaited(_verifyTunnelCarriesTraffic());
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

  /// Starts (or restarts) the watchdog that keeps this session on a good node.
  ///
  /// Armed on every successful connect, from the exact candidate list that
  /// connect chose out of — so the session can only ever move within the
  /// selection the user made. In "Best server" mode that's every node in the
  /// subscription; with a country picked it's that country's nodes, and the
  /// flag on screen stays true no matter what the watchdog does.
  void _armAutoSwitch(
    List<ServerNode> pool,
    String accessToken,
    String networkErrorMessage,
  ) {
    _autoSwitchPool = pool;
    _autoSwitchAccessToken = accessToken;
    _autoSwitchNetworkErrorMessage = networkErrorMessage;
    // Evidence gathered about the previous node says nothing about this one.
    _autoSwitchPolicy.reset();
    _autoSwitchTimer?.cancel();
    _autoSwitchTimer = null;
    // With a single node there is nowhere to move; a timer would only burn
    // battery to rediscover that every few minutes.
    if (pool.length < 2) return;
    _autoSwitchTimer = Timer.periodic(
      _autoSwitchInterval,
      (_) => unawaited(_evaluateAutoSwitch()),
    );
  }

  void _disarmAutoSwitch() {
    _autoSwitchTimer?.cancel();
    _autoSwitchTimer = null;
    _autoSwitchPolicy.reset();
  }

  /// Re-measures the session's alternatives — latency from this device, client
  /// counts from the panel — and moves it if one is clearly better (see
  /// [AutoSwitchPolicy] for what "clearly" means and how the two signals rank).
  ///
  /// [tunnelIsDead] comes from the traffic probe and means the current node has
  /// stopped being useful, not merely slow — the policy then takes any reachable
  /// alternative straight away.
  ///
  /// Both platforms measure the real underlay rather than the live tunnel, but
  /// they get there differently — see [PingService]: Android's tunnel keeps
  /// this app's sockets out of the tun device, while on iOS the measurement is
  /// delegated to the packet-tunnel extension, whose own traffic bypasses the
  /// tunnel it provides.
  ///
  /// ⚠️ Timers only run while the app is awake, so a backgrounded session is
  /// re-evaluated when the user next opens the app rather than continuously.
  Future<void> _evaluateAutoSwitch({bool tunnelIsDead = false}) async {
    if (_autoSwitchInProgress) return;
    if (_state != VpnConnectionState.connected) return;
    final current = _connectedNode;
    final accessToken = _autoSwitchAccessToken;
    final networkErrorMessage = _autoSwitchNetworkErrorMessage;
    if (current == null || accessToken == null || networkErrorMessage == null) {
      return;
    }
    final lastSwitch = _lastAutoSwitchAt;
    if (!tunnelIsDead &&
        lastSwitch != null &&
        DateTime.now().difference(lastSwitch) < _autoSwitchCooldown) {
      return;
    }

    _autoSwitchInProgress = true;
    try {
      final pool = _autoSwitchPool;
      final measurements = await Future.wait(
        pool.map((n) => _pingService.pingMs(n.address, n.port)),
      );
      final pingsByNodeId = <String, int>{};
      for (var i = 0; i < pool.length; i++) {
        final ms = measurements[i];
        if (ms != null) pingsByNodeId[pool[i].id] = ms;
      }

      // Measuring takes seconds, and the user may have disconnected or switched
      // servers in the meantime. Acting on a verdict about a session that no
      // longer exists would yank a connection they just made.
      if (_state != VpnConnectionState.connected || _connectedNode != current) {
        return;
      }

      final usersByNodeId = await _liveUserCounts(accessToken, pool);

      // Every round's raw numbers, so the crowding thresholds can be sanity-
      // checked against what this panel actually looks like in the field —
      // from a support bundle, without reproducing anything.
      log.d('Auto-switch round: ${pool.map((n) => '${n.name}='
          '${pingsByNodeId[n.id] ?? '-'}ms/'
          '${usersByNodeId[n.id] ?? '?'}u').join(', ')}');

      final target = _autoSwitchPolicy.evaluate(
        current: current,
        pool: pool,
        pingsByNodeId: pingsByNodeId,
        usersByNodeId: usersByNodeId,
        tunnelIsDead: tunnelIsDead,
      );
      if (target == null) return;

      String describe(ServerNode n) {
        final ping = pingsByNodeId[n.id];
        final users = usersByNodeId[n.id];
        return '"${n.name}" (${ping == null ? 'unreachable' : '${ping}ms'}, '
            '${users == null ? 'load unknown' : '$users users'})';
      }

      log.i('Auto-switching from ${describe(current)} to ${describe(target)}'
          '${tunnelIsDead ? ' — tunnel was passing no traffic' : ''}');
      await _performAutoSwitch(
        from: current,
        to: target,
        pool: pool,
        accessToken: accessToken,
        networkErrorMessage: networkErrorMessage,
      );
    } catch (e) {
      log.w('Auto-switch evaluation failed: $e');
    } finally {
      _autoSwitchInProgress = false;
    }
  }

  /// Current client counts for the nodes in [pool], keyed by node id, with
  /// nodes the panel reports nothing for left out entirely (see
  /// [ServerNode.usersOnline] — absent means unknown, and the policy abstains
  /// rather than reading it as an empty server).
  ///
  /// Re-fetched each round rather than read off [pool]: those counts were taken
  /// when the server list was loaded, possibly hours ago, and a snapshot from
  /// then cannot show that a server filled up *during* this session — which is
  /// the entire reason to consult load at all.
  ///
  /// Best-effort. `/servers` failing (offline, or 402 on a lapsed subscription)
  /// leaves the pool's own counts in place; those are what the connect-time
  /// decision ran on, so falling back to them is no worse than not having the
  /// signal.
  Future<Map<String, int>> _liveUserCounts(
    String accessToken,
    List<ServerNode> pool,
  ) async {
    final counts = <String, int>{};
    for (final node in pool) {
      final users = node.usersOnline;
      if (users != null) counts[node.id] = users;
    }
    final poolIds = pool.map((n) => n.id).toSet();
    try {
      final servers = await _apiClient.getServers(accessToken);
      for (final country in servers) {
        for (final node in country.nodes) {
          final users = node.usersOnline;
          if (users != null && poolIds.contains(node.id)) {
            counts[node.id] = users;
          }
        }
      }
    } catch (e) {
      log.w('Auto-switch could not refresh node load, using last known: $e');
    }
    return counts;
  }

  /// Rebuilds the tunnel on [to], falling back to [from] if that fails.
  ///
  /// The fallback is the point of this method: the session being replaced is a
  /// *working* one, and an optimisation the user never asked for must not be
  /// able to leave them offline. If the new node won't come up we put the old
  /// one back before giving up.
  Future<void> _performAutoSwitch({
    required ServerNode from,
    required ServerNode to,
    required List<ServerNode> pool,
    required String accessToken,
    required String networkErrorMessage,
  }) async {
    _lastAutoSwitchAt = DateTime.now();
    // Not a user power-off: the VPN stays on across the swap, so the session
    // timer must keep running (see [disconnect]).
    await disconnect(endSession: false);
    await _waitForDisconnected();
    try {
      await _connect(
        pool,
        accessToken,
        networkErrorMessage: networkErrorMessage,
        preferred: to,
      );
      onAutoSwitched?.call(from, to);
    } catch (e) {
      log.w('Auto-switch to "${to.name}" failed, restoring "${from.name}": $e');
      try {
        await _waitForDisconnected();
        await _connect(
          pool,
          accessToken,
          networkErrorMessage: networkErrorMessage,
          preferred: from,
        );
      } catch (e2) {
        // Both nodes refused. The error state and message from [_connect] are
        // already on screen, and the user can retry from the power button.
        log.e('Auto-switch fallback to "${from.name}" failed too', e2.toString());
      }
    }
  }

  /// Blocks until the tunnel has actually torn down. A connect issued while the
  /// previous session is still going down gets dropped by the plugin, which
  /// would leave the session on the old node while we believe we moved it.
  Future<void> _waitForDisconnected() async {
    final deadline = DateTime.now().add(const Duration(seconds: 4));
    while (_state != VpnConnectionState.disconnected &&
        _state != VpnConnectionState.error &&
        DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 150));
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

  /// Records the extension's persisted diagnostics into the app log without
  /// touching the UI. Unlike [_captureTunnelFailure] this makes no claim that
  /// anything failed — the tunnel may well be healthy — so it never sets
  /// [errorMessage]; it exists purely so a silently-dead tunnel leaves a trail
  /// in the shareable support bundle.
  Future<void> _logTunnelDiagnostics() async {
    try {
      final err = await _vpn.getLastError();
      if (err != null && err.trim().isNotEmpty) {
        log.w('Tunnel diagnostics on live tunnel: $err');
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
    // The watchdog belongs to the session being torn down; the next connect
    // arms a fresh one for whatever it establishes.
    _disarmAutoSwitch();
    // Drop the node *before* the teardown, not after. Stopping the tunnel takes
    // a moment and emits state events all the way through, and every listener
    // that reads connectedNode during that window used to be told we were still
    // on the node being abandoned. That cost a user-visible bug: picking a new
    // country while connected made the home screen follow the old node back
    // (see _handleVpnChange) and reconnect to the very server the user was
    // leaving — which also stranded anyone trying to escape a dead one.
    _connectedNode = null;
    await _vpn.stop();
  }

  @override
  void dispose() {
    _autoSwitchTimer?.cancel();
    _stateSubscription?.cancel();
    super.dispose();
  }
}
