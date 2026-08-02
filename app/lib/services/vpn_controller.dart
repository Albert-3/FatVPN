import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:singbox_mm/singbox_mm.dart';

import '../models/server_country.dart';
import '../utils/parallel.dart';
import '../utils/sanitize.dart';
import 'api_client.dart';
import 'app_logger.dart';
import 'auto_switch_policy.dart';
import 'connection_settings_controller.dart';
import 'ping_service.dart';
import 'secure_store.dart';
import 'vless_config_parser.dart';

/// Owns the sing-box VPN tunnel and exposes real connection state to the UI,
/// replacing the fake local-timer toggle that used to live in [HomeScreen].
class VpnController extends ChangeNotifier {
  VpnController({
    required this.connectionSettings,
    ApiClient? apiClient,
    PingService? pingService,
    AutoSwitchPolicy? autoSwitchPolicy,
  })  : _apiClient = apiClient ?? ApiClient(),
        _pingService = pingService ?? PingService(),
        _autoSwitchPolicy = autoSwitchPolicy ?? AutoSwitchPolicy();

  final ConnectionSettingsController connectionSettings;
  final ApiClient _apiClient;
  final PingService _pingService;
  final AutoSwitchPolicy _autoSwitchPolicy;
  final SignboxVpn _vpn = SignboxVpn();
  final _storage = SecureStore();
  StreamSubscription<VpnConnectionState>? _stateSubscription;

  // Wall-clock start of the current tunnel session, persisted so it survives
  // the app being killed while the tunnel keeps running. Lets the UI show the
  // real elapsed time on relaunch instead of restarting the clock from zero.
  static const _sessionStartKey = 'vpn_session_started_at';
  DateTime? _sessionStartedAt;

  // Bearer token the running tunnel's control API demands, persisted for the
  // same reason as the session start: the app can be relaunched onto a tunnel
  // it didn't start, and without the secret it can't ask that tunnel anything.
  static const _clashApiSecretKey = 'vpn_clash_api_secret';
  String? _clashApiSecret;

  // Where that control API listens, persisted for the same reason as the
  // secret. Not a constant: a fixed port is a fingerprint — any app on the
  // phone can knock on it and learn that this VPN is running, without holding
  // the secret and without any permission beyond INTERNET.
  static const _clashApiPortKey = 'vpn_clash_api_port';
  int? _clashApiPort;

  // Guards against overlapping runtime-state reconciliation polls (launch +
  // resume can both fire syncFromRuntime in quick succession).
  bool _reconciling = false;

  Future<void>? _initFuture;
  // Set while a user-requested disconnect is in flight, so the
  // connected→disconnected transition it causes isn't misread as a runtime
  // tunnel failure by the diagnostics watcher below.
  bool _userDisconnecting = false;

  // ── Connect / disconnect interleaving ────────────────────────────────────
  // A connect takes seconds (a `/config` round-trip, then a ping of every
  // candidate), and the user is free to tap the power button again while it
  // runs — the home screen reads a `connecting` state as "on", so that second
  // tap is a disconnect. Both halves then run at once, and the disconnect's
  // cleanup lands in the middle of the connect it knows nothing about.
  //
  // That cleanup is destructive: [forgetPersistedTunnelState] erases the config
  // the platform is holding. On iOS the config *is* what `startVpn` starts
  // from, so a wipe that lands between the config being pushed and the tunnel
  // being started fails the connect with "Config is missing. Call setConfig()
  // first." — the user sees an error for something they cancelled. (Android
  // does not implement the wipe at all, which is why the symptom is iOS-only.)
  //
  // So the wipe is deferred, not skipped: the connect finishes, notices the
  // disconnect that arrived while it ran, and tears its own session down —
  // config and all. Same end state, without the two halves fighting.
  bool _connecting = false;
  bool _disconnectRequestedDuringConnect = false;
  VpnConnectionState _state = VpnConnectionState.disconnected;
  String? _errorMessage;
  ServerNode? _connectedNode;

  // True when the tunnel came up but a probe through it reached nothing. See
  // [_verifyTunnelCarriesTraffic].
  bool _tunnelNotPassingTraffic = false;

  // Guards against overlapping traffic probes (connect, app resume and the
  // periodic health tick can each ask for one).
  bool _probingTraffic = false;

  // ── Session health: keeping a live session working, and on a good node ────
  // Everything needed to re-run the connect that established this session, so
  // the watchdog below can move it to a better node without the UI's help. See
  // [_sessionHealthTick] and [_evaluateAutoSwitch].
  Timer? _sessionHealthTimer;
  List<ServerNode> _autoSwitchPool = const [];
  String? _autoSwitchNetworkErrorMessage;
  bool _autoSwitchInProgress = false;
  DateTime? _lastAutoSwitchAt;

  /// How often a live session checks itself: is the tunnel still carrying
  /// traffic, and is there a clearly better node to move to. Long on purpose:
  /// the pings cost real requests, and nothing here is urgent enough to spend
  /// the user's battery on a tighter loop — the tunnel's own watchdog, which
  /// runs inside the VPN service and so survives the app being backgrounded,
  /// is what catches a dead tunnel quickly.
  ///
  /// Slower still on iOS, where the packet-tunnel extension runs a watchdog of
  /// its own around the clock: two independent loops asking the same question
  /// is the one place this app spends battery for nothing, and the extension's
  /// is both the better-informed and the unavoidable one.
  static Duration get _sessionHealthInterval =>
      defaultTargetPlatform == TargetPlatform.iOS
          ? const Duration(minutes: 6)
          : const Duration(minutes: 3);

  /// Minimum quiet period after a switch. Without it a pair of nodes whose
  /// latencies straddle the threshold could bounce the session back and forth,
  /// which is worse than either server.
  static const _autoSwitchCooldown = Duration(minutes: 10);

  /// Notified when the session moves itself to a different node, so the UI can
  /// reflect the new location and tell the user why their connections blipped.
  void Function(ServerNode from, ServerNode to)? onAutoSwitched;

  /// Localized text for "this subscription lists nothing we can connect to".
  /// Supplied by the UI, which owns the language; without it the user was shown
  /// the raw `Bad state: No available node in this subscription`.
  String? noUsableNodesMessage;

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

  /// Runs initialization exactly once, however many callers race for it.
  ///
  /// Two awaits separate "not initialized yet" from "initialized", and the home
  /// screen enters here twice on launch (`syncFromRuntime` and the trial
  /// auto-connect). Without the shared future the second pass subscribed to the
  /// broadcast state stream again and overwrote the handle to the first
  /// subscription, leaking it and doubling every event for the rest of the
  /// process.
  Future<void> _ensureInitialized() => _initFuture ??= _doInitialize();

  Future<void> _doInitialize() async {
    // Restore the persisted session start *before* subscribing to the state
    // stream. On relaunch with a live tunnel the stream emits `connected`
    // almost immediately; if we hadn't loaded the real start first,
    // `_trackSessionStart` would see a null start and clobber the stored value
    // with `now`, resetting the timer to zero. Priming it here means the
    // `connected` event finds a non-null start and leaves it untouched.
    final stored = await Future.wait([
      _storage.read(key: _sessionStartKey),
      _storage.read(key: _clashApiSecretKey),
      _storage.read(key: _clashApiPortKey),
    ]);
    final storedStart = stored[0];
    if (storedStart != null) {
      _sessionStartedAt = DateTime.tryParse(storedStart);
    }
    _clashApiSecret = stored[1];
    // Null on a tunnel started by a build that had no port to store; the probe
    // falls back to the old constant, which is what that tunnel is listening on.
    _clashApiPort = int.tryParse(stored[2] ?? '');
    await _vpn.initialize(const SingboxRuntimeOptions(logLevel: 'warn'));
    await _stateSubscription?.cancel();
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
        // The user opening the app on a tunnel that has been up for hours is
        // very often the user checking *why* nothing loads. Ask the tunnel
        // itself rather than waiting for the next scheduled round: a dead one
        // gets flagged on screen and escalated to another node from here.
        unawaited(_verifyTunnelCarriesTraffic());
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
    ServerCountry country, {
    required String networkErrorMessage,
  }) async {
    await _connect(country.nodes, networkErrorMessage: networkErrorMessage);
  }

  /// Connects to the fastest node across *all* countries — used when the
  /// user hasn't explicitly chosen a location yet (still on the default
  /// "Best Server" state) so first launch doesn't force a manual pick.
  ///
  /// "All countries" excludes the panel's bypass bucket (see
  /// [autoPickCandidates]): reaching it is a deliberate choice, never an
  /// automatic one. The filtered list is also what becomes the session's pool,
  /// so the auto-switch can't drift onto a bypass host later either.
  ///
  /// Returns the country the chosen node belongs to, so the caller can
  /// reflect the auto-picked location in the UI.
  Future<ServerCountry?> connectToBestOverall(
    List<ServerCountry> countries, {
    required String networkErrorMessage,
  }) async {
    final candidates = autoPickCandidates(countries);
    final allNodes = candidates.expand((c) => c.nodes).toList();
    final node = await _connect(allNodes, networkErrorMessage: networkErrorMessage);
    if (node == null) return null;
    return candidates.firstWhere((c) => c.nodes.contains(node));
  }

  /// Endpoint the post-connect probe hits. Google's captive-portal check:
  /// an empty 204, served from everywhere, and designed for exactly this.
  static const _trafficProbeUrl = 'https://www.gstatic.com/generate_204';
  static const _trafficProbeTimeout = Duration(seconds: 8);

  // The tunnel reports "established" as soon as the interface is up, a moment
  // before the OS finishes installing its routes. Probing inside that window is
  // worthless: the request slips out over the *old* default route and succeeds
  // no matter how broken the tunnel is — which is exactly how an unreachable
  // server passed this check during testing. Wait for routing to settle first.
  //
  // The wait is generous because the *first* request through a node costs far
  // more than the ones after it, and this probe is the first: a TLS handshake,
  // and for the panel's shutdown-bypass host an HTTP session through a CDN on
  // top of that. Judging a node before it has finished coming up is not a
  // cosmetic mistake — the verdict flags the server on screen and escalates to
  // [_evaluateAutoSwitch], moving the user off a node that was about to work.
  // For the bypass host that is the worst possible outcome, since it is chosen
  // precisely when the alternatives are unreachable.
  static const _trafficProbeSettleDelay = Duration(seconds: 8);
  static const _trafficProbeRetryDelay = Duration(seconds: 6);

  /// How many times the probe asks before it will call a tunnel dead.
  ///
  /// Three rather than two so the attempts span a real warm-up window instead
  /// of landing twice in the same cold moment.
  static const _trafficProbeAttempts = 3;

  /// The port a tunnel raised before this app learned to randomise one is
  /// listening on — [MiscOptions.clashApiPort]'s own default.
  static const _legacyClashApiPort = 16756;

  /// sing-box's local control API (`experimental.clash_api`), on whichever port
  /// the running tunnel was started with.
  String get _singboxApiBase =>
      'http://127.0.0.1:${_clashApiPort ?? _legacyClashApiPort}';

  /// Confirms the established tunnel actually carries traffic, and flags it when
  /// it doesn't.
  ///
  /// This is reliable precisely *because* the tun device is up: with a default
  /// route into the tunnel there is no direct path left, so a dead outbound
  /// can't be masked by the request slipping out around it — it simply times
  /// out. A single failure isn't enough to accuse the server, so the retries
  /// ([_trafficProbeAttempts]) absorb both a transient blip and a node that is
  /// merely slow to warm up.
  ///
  /// Never tears the tunnel down: a probe is weaker evidence than the user's
  /// own experience, and yanking a connection out from under someone over one
  /// unreachable URL would be worse than the symptom.
  Future<void> _verifyTunnelCarriesTraffic() async {
    // Connect, resume and the periodic health tick can all ask at once; one
    // verdict at a time is enough, and overlapping probes would just multiply
    // the requests a dying tunnel is already failing to carry.
    if (_probingTraffic) return;
    _probingTraffic = true;
    try {
      await _runTrafficProbe();
    } finally {
      _probingTraffic = false;
    }
  }

  Future<void> _runTrafficProbe() async {
    await Future.delayed(_trafficProbeSettleDelay);
    for (var attempt = 0; attempt < _trafficProbeAttempts; attempt++) {
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
  /// The two platforms need different approaches:
  ///
  /// * **Android** — the tunnel carries this app's traffic like any other
  ///   app's, so a plain request would be answered by *some* path but tells us
  ///   nothing about the outbound in particular: the OS can still satisfy it
  ///   over the underlay while the proxy is dead. Asking sing-box over its
  ///   local Clash API is precise — its delay test dials the probe URL through
  ///   the active outbound, which is the question we actually want answered.
  /// * **iOS** — the Clash API is not an option: it listens inside the network
  ///   extension, a separate process whose 127.0.0.1 this app cannot reach. The
  ///   container app's traffic does go through the packet tunnel, so a plain
  ///   request is both possible and correct there.
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

  /// A fresh bearer token for the control API. 128 bits from the platform
  /// CSPRNG: this is the only thing standing between any app on the device and
  /// the user's live connection list.
  static String _newClashApiSecret() {
    final random = Random.secure();
    return List<String>.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  /// A free loopback port for the control API, different at every connect.
  ///
  /// Asked of the OS rather than picked at random from a range: a port that
  /// turns out to be taken makes sing-box fail to start, which would trade a
  /// fingerprinting hole for a VPN that sometimes refuses to connect. Binding
  /// and immediately releasing leaves a short window in which something else
  /// could claim it, so a failure to bind — or a race that loses — falls back
  /// to the old fixed port rather than dropping the tunnel.
  static Future<int> _pickClashApiPort() async {
    try {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      return port;
    } catch (e) {
      log.w('Could not reserve a control-API port, using the fixed one: $e');
      return _legacyClashApiPort;
    }
  }

  /// GET against the tunnel's local control API, carrying the secret the config
  /// was built with (see [_clashApiSecret]).
  Future<http.Response> _singboxApiGet(Uri uri, Duration timeout) {
    final secret = _clashApiSecret;
    return http
        .get(uri, headers: {
          if (secret != null && secret.isNotEmpty)
            'Authorization': 'Bearer $secret',
        })
        .timeout(timeout);
  }

  Future<bool?> _probeViaSingboxApi() async {
    // Traffic that actually arrived outranks any question we could ask; see
    // [_carriedTrafficSinceLastCheck].
    if (await _carriedTrafficSinceLastCheck()) return true;
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
      final response = await _singboxApiGet(
        uri,
        _trafficProbeTimeout + const Duration(seconds: 4),
      );
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

  /// Bytes received through the tunnel when this probe last looked. Null until
  /// the first look, and reset by a restart along with the counter it mirrors.
  int? _lastReceivedBytes;

  /// Whether the tunnel has demonstrably carried traffic since the previous
  /// check.
  ///
  /// The delay test is an interrogation, and a witness beats an interrogation.
  /// It opens a *fresh* connection through the outbound and allows it eight
  /// seconds — but a node fronted by a CDN can need longer for a cold dial, so
  /// "dead" comes back for a tunnel the user is browsing through right then.
  /// Believing it costs the user the server: the banner tells them to pick
  /// another one and [_evaluateAutoSwitch] moves them off it.
  ///
  /// Received bytes can't lie that way — they are data the far end sent back,
  /// so any increase means the whole path worked. Sent bytes are weaker (they
  /// can pile into a socket that never answers), so only receives count.
  ///
  /// A tunnel nobody is using produces no evidence, and then the delay test is
  /// still the right question to ask.
  Future<bool> _carriedTrafficSinceLastCheck() async {
    final received = await _receivedBytes();
    if (received == null) return false;
    final previous = _lastReceivedBytes;
    _lastReceivedBytes = received;
    // A restart zeroes the counter. Lower than last time proves nothing.
    if (previous == null || received < previous) return false;
    return received > previous;
  }

  Future<int?> _receivedBytes() async {
    try {
      final response = await _singboxApiGet(
        Uri.parse('$_singboxApiBase/connections'),
        const Duration(seconds: 5),
      );
      if (response.statusCode != 200) return null;
      final total =
          (jsonDecode(response.body) as Map<String, dynamic>)['downloadTotal'];
      return total is int ? total : null;
    } catch (_) {
      return null;
    }
  }

  /// Tag of the proxy outbound currently in use, read back from sing-box.
  ///
  /// Taken from the running instance rather than assumed from the node we asked
  /// for: the tag is the config link's own fragment, which need not match the
  /// node name `/servers` reports.
  Future<String?> _activeOutboundTag() async {
    try {
      final response = await _singboxApiGet(
        Uri.parse('$_singboxApiBase/proxies'),
        const Duration(seconds: 5),
      );
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
    List<ServerNode> candidates, {
    required String networkErrorMessage,
    ServerNode? preferred,
  }) async {
    _errorMessage = null;
    _tunnelNotPassingTraffic = false;
    _userDisconnecting = false;
    _connecting = true;
    _disconnectRequestedDuringConnect = false;
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
      final (content, _) = await _apiClient.getConfig();
      final uris = parseConfigUris(content);
      String? uriFor(ServerNode n) => n.configUri ?? findUriForNode(uris, n);

      final usableNodes = candidates.where((n) => uriFor(n) != null).toList();
      if (usableNodes.isEmpty) {
        throw _NoUsableNodes();
      }

      final node = preferred != null && usableNodes.contains(preferred)
          ? preferred
          : await _pickBestNode(usableNodes);
      final uri = uriFor(node)!;

      log.i('Connecting to node "${node.name}" '
          '(dns=${connectionSettings.dnsPreset.name}, '
          'stack=${connectionSettings.networkStack.name}, '
          'split=${connectionSettings.splitTunnelEnabled}'
          '/${connectionSettings.splitTunnelMode.name})');
      // How the OS itself should treat this tunnel — whether it may bring it
      // back on its own after a crash, a memory kill or a reboot, and whether
      // traffic is allowed out while it is down. Pushed before the start
      // because that is when the platform writes them into the VPN profile.
      //
      // Caught rather than allowed to abort the connect: failing here costs the
      // user their auto-reconnect preference, and refusing to connect at all
      // over that would be a far worse trade. Logged, not swallowed — the
      // symptom is otherwise invisible ("I turned the kill switch on and
      // nothing happens").
      try {
        await _vpn.setTunnelPreferences(
          onDemandEnabled: connectionSettings.autoReconnect,
          killSwitchEnabled: connectionSettings.killSwitch,
        );
      } catch (e) {
        log.w('Could not apply tunnel preferences (auto-reconnect / '
            'kill switch); connecting without them: $e');
      }
      // A new tunnel gets a new control-API secret, so a secret that leaked
      // (a support bundle, a shared log) stops working at the next connect.
      final clashApiSecret = _newClashApiSecret();
      // …and a new port, so the running VPN stops being something any app can
      // spot by knocking on a well-known number.
      final clashApiPort = await _pickClashApiPort();
      // Adopted *before* the connect, not after. `connectManualConfigLink` can
      // throw after the config is already installed and the tunnel started (the
      // second-core fallback does exactly that), and a throw past this point
      // would leave a running tunnel holding the new secret while this field
      // still held the old one: every probe would answer 401, the outbound tag
      // would read as null, and a dead tunnel would stop being detectable. The
      // port has the same problem with a louder failure: probes would go to a
      // port nothing is listening on.
      _clashApiSecret = clashApiSecret;
      _clashApiPort = clashApiPort;
      unawaited(
        _storage.write(key: _clashApiSecretKey, value: clashApiSecret),
      );
      unawaited(
        _storage.write(key: _clashApiPortKey, value: '$clashApiPort'),
      );
      // Built fresh here so DNS / network-stack preference edits in Settings
      // take effect on this (re)connect.
      await _vpn.connectManualConfigLink(
        configLink: uri,
        featureSettings: connectionSettings.buildFeatureSettings(
          clashApiSecret: clashApiSecret,
          clashApiPort: clashApiPort,
        ),
      );
      // The user asked for the VPN to be off while this was still running (see
      // [_disconnectRequestedDuringConnect]). Honour that rather than leaving
      // them on a session they cancelled — and do it here, where no wipe can
      // land inside somebody else's connect.
      if (_disconnectRequestedDuringConnect) {
        log.i('Connect completed after a disconnect request; taking it down');
        _connecting = false;
        _disconnectRequestedDuringConnect = false;
        await disconnect();
        return null;
      }
      _connectedNode = node;
      log.i('Tunnel established to "${node.name}"');
      // Watch this session from here on, so a node that degrades later doesn't
      // hold it for the rest of the day.
      _armSessionHealth(usableNodes, networkErrorMessage);
      // Deliberately not awaited: the tunnel is up, so the UI should say so
      // immediately. The probe corrects that claim a few seconds later if
      // nothing actually gets through.
      unawaited(_verifyTunnelCarriesTraffic());
      return node;
    } catch (e) {
      _state = VpnConnectionState.error;
      // Never e.toString(): whatever falls through here is shown under the power
      // button, and a user whose subscription had run out was reading
      // "ApiException(502): config_failed" with nothing said about their key.
      // An unrecognized failure is still a failure to reach the server, which is
      // both true and something the user can act on.
      _errorMessage = switch (e) {
        SignboxVpnException() => e.message,
        _NoUsableNodes() => noUsableNodesMessage ?? networkErrorMessage,
        _ => networkErrorMessage,
      };
      log.e('Connect failed', e.toString());
      notifyListeners();
      rethrow;
    } finally {
      _connecting = false;
      // A disconnect that arrived mid-connect had its cleanup deferred to this
      // method; if the connect failed instead of completing, the deferral must
      // still be honoured, or a cancelled session would leave the subscription
      // on disk.
      if (_disconnectRequestedDuringConnect) {
        _disconnectRequestedDuringConnect = false;
        unawaited(forgetPersistedTunnelState());
      }
    }
  }

  /// Starts (or restarts) the watchdog that keeps this session healthy and on a
  /// good node.
  ///
  /// Armed on every successful connect, from the exact candidate list that
  /// connect chose out of — so the session can only ever move within the
  /// selection the user made. In "Best server" mode that's every node in the
  /// subscription; with a country picked it's that country's nodes, and the
  /// flag on screen stays true no matter what the watchdog does.
  void _armSessionHealth(
    List<ServerNode> pool,
    String networkErrorMessage,
  ) {
    _autoSwitchPool = pool;
    _autoSwitchNetworkErrorMessage = networkErrorMessage;
    // Evidence gathered about the previous node says nothing about this one.
    _autoSwitchPolicy.reset();
    _sessionHealthTimer?.cancel();
    // Armed even with a single node in the pool, where there is nowhere to
    // move: the tick still asks whether the tunnel carries traffic, which is
    // what puts the warning on screen instead of leaving a green toggle over a
    // dead connection.
    _sessionHealthTimer = Timer.periodic(
      _sessionHealthInterval,
      (_) => unawaited(_sessionHealthTick()),
    );
  }

  void _disarmSessionHealth() {
    _sessionHealthTimer?.cancel();
    _sessionHealthTimer = null;
    _autoSwitchPolicy.reset();
  }

  /// One round of looking after a live session: first whether the tunnel still
  /// works at all, then whether a better node is available.
  ///
  /// The order matters. Until now the periodic round only compared *latencies*,
  /// which says nothing about the tunnel itself — a node that answers pings
  /// while its tunnel passes no traffic looked perfectly healthy, so a session
  /// that had silently died stayed dead until the user noticed and toggled the
  /// VPN by hand. The probe is the part that can tell those two apart, and it
  /// escalates to a switch on its own when the answer is "nothing gets through"
  /// (see [_verifyTunnelCarriesTraffic]).
  Future<void> _sessionHealthTick() async {
    if (_state != VpnConnectionState.connected) return;
    await _verifyTunnelCarriesTraffic();
    // A dead tunnel has already been escalated; re-measuring alternatives now
    // would only race the switch that verdict just started.
    if (_tunnelNotPassingTraffic) return;
    if (_autoSwitchPool.length < 2) return;
    await _evaluateAutoSwitch();
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
    final networkErrorMessage = _autoSwitchNetworkErrorMessage;
    if (current == null || networkErrorMessage == null) {
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
      final measurements = await mapConcurrently(
        pool,
        (n) => _pingService.pingMs(n.address, n.port),
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

      final usersByNodeId = await _liveUserCounts(pool);

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
  /// Fetched fresh each round, past the client's cache: the counts on [pool]
  /// were taken when the server list was loaded, possibly hours ago, and a
  /// snapshot from then cannot show that a server filled up *during* this
  /// session — which is the entire reason to consult load at all. The cache's
  /// five-minute TTL is longer than the gap between rounds, so without `force`
  /// this round would mostly re-read the previous one's answer.
  ///
  /// Best-effort. `/servers` failing (offline, or 402 on a lapsed subscription)
  /// leaves the pool's own counts in place; those are what the connect-time
  /// decision ran on, so falling back to them is no worse than not having the
  /// signal.
  Future<Map<String, int>> _liveUserCounts(List<ServerNode> pool) async {
    final counts = <String, int>{};
    for (final node in pool) {
      final users = node.usersOnline;
      if (users != null) counts[node.id] = users;
    }
    final poolIds = pool.map((n) => n.id).toSet();
    try {
      final servers = await _apiClient.getServers(force: true);
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
    required String networkErrorMessage,
  }) async {
    _lastAutoSwitchAt = DateTime.now();
    // Not a user power-off: the VPN stays on across the swap, so the session
    // timer must keep running (see [disconnect]).
    await disconnect(endSession: false);
    await waitForDisconnected();
    try {
      await _connect(
        pool,
        networkErrorMessage: networkErrorMessage,
        preferred: to,
      );
      onAutoSwitched?.call(from, to);
    } catch (e) {
      log.w('Auto-switch to "${to.name}" failed, restoring "${from.name}": $e');
      try {
        await waitForDisconnected();
        await _connect(
          pool,
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
  ///
  /// The window is sized against the service's own teardown budget
  /// (`VpnCoreServiceCoordinator.RESTART_CLOSE_SUPPRESSION_MS` = 15 s): the old
  /// four-second deadline expired silently on any teardown that took longer,
  /// and the caller then went ahead and reconnected anyway — the exact outcome
  /// this is here to prevent. Expiry is now logged rather than assumed benign.
  Future<void> waitForDisconnected() async {
    if (_isDown(_state)) return;
    try {
      await _vpn.stateStream
          .firstWhere(_isDown)
          .timeout(const Duration(seconds: 10));
    } on TimeoutException {
      log.w('Tunnel did not report disconnected within 10s; continuing anyway');
    }
  }

  static bool _isDown(VpnConnectionState state) =>
      state == VpnConnectionState.disconnected ||
      state == VpnConnectionState.error;

  /// Fastest node of [nodes], or the first one when none answered.
  ///
  /// Measured in parallel: this runs on every Connect tap, and in "Best server"
  /// mode the candidates are every node of every country — serially, a handful
  /// of unreachable ones alone cost three seconds each before the tunnel even
  /// starts coming up.
  Future<ServerNode> _pickBestNode(List<ServerNode> nodes) async {
    final measurements = await mapConcurrently(
      nodes,
      (n) => _pingService.pingMs(n.address, n.port),
    );
    ServerNode? best;
    int? bestPing;
    for (var i = 0; i < nodes.length; i++) {
      final ms = measurements[i];
      if (ms != null && (bestPing == null || ms < bestPing)) {
        best = nodes[i];
        bestPing = ms;
      }
    }
    return best ?? nodes.first;
  }

  /// Pulls the tunnel's last-failure report (on iOS, the PacketTunnel
  /// extension's persisted reason + sing-box stderr tail) into the app log so it
  /// lands in the shareable support bundle, and surfaces it to the UI.
  /// What the Android tunnel service records as its "error" when the stop came
  /// from the *user* rather than from a failure — the notification's Stop
  /// button, or the home-screen widget's power button. The plugin already
  /// treats it as a deliberate stop (it suppresses managed-mode failover on
  /// it); this controller did not, so a stop from outside the app was captured
  /// as a runtime failure and put a raw `STOPPED_BY_USER` on the home screen.
  static const _stoppedByUserMarker = 'STOPPED_BY_USER';

  Future<void> _captureTunnelFailure() async {
    try {
      final err = await _vpn.getLastError();
      if (err != null && err.trim() == _stoppedByUserMarker) {
        log.i('Tunnel stopped by the user from outside the app');
        return;
      }
      if (err != null && err.trim().isNotEmpty) {
        // Both the banner and the log end up somewhere the user can share, and
        // the stderr tail quotes the outbound it was dialling — see
        // [sanitizeDiagnostics].
        final safe = sanitizeDiagnostics(err);
        _errorMessage = safe;
        log.e('Tunnel failed at runtime', safe);
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
        log.w('Tunnel diagnostics on live tunnel: ${sanitizeDiagnostics(err)}');
      }
    } catch (e) {
      log.w('Failed to read tunnel diagnostics: $e');
    }
  }

  /// Pushes the current auto-reconnect / kill-switch preferences into the
  /// platform's VPN profile, without touching the tunnel.
  ///
  /// These two live in the OS profile, not in the sing-box config, so a flip
  /// needs no reconnect — and used to get one anyway, tearing a live session
  /// for a setting the tunnel itself doesn't read. Worse, the push only
  /// happened inside a connect at all: a user who turned auto-reconnect off
  /// while the tunnel was down (say, after the OS resurrected a session they
  /// no longer wanted) left `onDemand = true` sitting in the profile, and the
  /// OS kept bringing the tunnel back until their next manual connect.
  ///
  /// Best-effort like the connect-path push, and for the same reason: the
  /// symptom of a platform failure here is a stale preference, which is worth
  /// a log line, not an error screen.
  Future<void> applyTunnelPreferences() async {
    try {
      await _ensureInitialized();
      await _vpn.setTunnelPreferences(
        onDemandEnabled: connectionSettings.autoReconnect,
        killSwitchEnabled: connectionSettings.killSwitch,
      );
      log.i('Tunnel preferences pushed '
          '(onDemand=${connectionSettings.autoReconnect}, '
          'killSwitch=${connectionSettings.killSwitch})');
    } catch (e) {
      log.w('Could not apply tunnel preferences: $e');
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
    _disarmSessionHealth();
    // Drop the node *before* the teardown, not after. Stopping the tunnel takes
    // a moment and emits state events all the way through, and every listener
    // that reads connectedNode during that window used to be told we were still
    // on the node being abandoned. That cost a user-visible bug: picking a new
    // country while connected made the home screen follow the old node back
    // (see _handleVpnChange) and reconnect to the very server the user was
    // leaving — which also stranded anyone trying to escape a dead one.
    _connectedNode = null;
    await _vpn.stop();
    if (endSession) {
      await forgetPersistedTunnelState();
    }
  }

  /// Erases everything the platform still holds about the subscription that was
  /// just running: the stored sing-box config, and on iOS the extension's
  /// start-options snapshot and its diagnostics.
  ///
  /// The snapshot is the one that matters. It exists so the OS can bring the
  /// tunnel back without the app — which is right while the user wants a VPN,
  /// and wrong the moment they don't: after a power-off, a logout or an expired
  /// subscription it would reconnect them to the last node they used, on
  /// credentials the panel may have revoked since. The config and the
  /// diagnostics go with it because both quote those credentials verbatim.
  ///
  /// Best-effort by design: failing to clean up must not turn a sign-out into
  /// an error the user is shown.
  Future<void> forgetPersistedTunnelState() async {
    if (_connecting) {
      // A connect is in flight: it has either just handed the platform the
      // config it is about to start from, or is about to. Erasing that config
      // now is what produced "Config is missing. Call setConfig() first." on
      // iOS — an error for a session the user had just cancelled. The connect
      // performs this teardown itself once it lands (see [_connect]).
      log.i('Wipe requested during an in-flight connect; deferring it');
      _disconnectRequestedDuringConnect = true;
      return;
    }
    _clashApiSecret = null;
    _clashApiPort = null;
    await _wipePersistedTunnelState(_vpn, _storage);
  }

  /// Stops the tunnel and erases the persisted state without a live
  /// [VpnController].
  ///
  /// The session can die while [HomeScreen] — which owns the app's controller —
  /// is not on the tree: a refresh rejected with 401 signs the user out from
  /// the renew screen, and a 402 can land after the gate has already swapped
  /// Home out. Those paths still have to bring the tunnel down and erase what
  /// the platform holds, or (on iOS with on-demand) the OS keeps resurrecting
  /// the tunnel on credentials the panel has revoked. Erases the same state as
  /// [forgetPersistedTunnelState], plus the session clock; the tunnel stop is
  /// unconditional because with no controller there is no state to consult,
  /// and stopping a stopped tunnel is a no-op.
  static Future<void> stopAndForgetStandalone() async {
    final vpn = SignboxVpn();
    try {
      await vpn.stop();
    } catch (e) {
      log.w('Standalone tunnel stop failed: $e');
    }
    final storage = SecureStore();
    try {
      await storage.delete(key: _sessionStartKey);
    } catch (e) {
      log.w('Could not clear the persisted session start: $e');
    }
    await _wipePersistedTunnelState(vpn, storage);
  }

  static Future<void> _wipePersistedTunnelState(
    SignboxVpn vpn,
    SecureStore storage,
  ) async {
    try {
      await storage.delete(key: _clashApiSecretKey);
    } catch (e) {
      log.w('Could not delete the stored tunnel API secret: $e');
    }
    try {
      await storage.delete(key: _clashApiPortKey);
    } catch (e) {
      log.w('Could not delete the stored tunnel API port: $e');
    }
    try {
      await vpn.clearPersistedState();
    } catch (e) {
      log.w('Could not clear persisted tunnel state: $e');
    }
  }

  @override
  void dispose() {
    _sessionHealthTimer?.cancel();
    _stateSubscription?.cancel();
    super.dispose();
  }
}

/// The subscription carries no link this build can connect with. Its own type
/// so [VpnController._connect] can swap in a localized message instead of
/// rendering an exception at the user.
class _NoUsableNodes implements Exception {
  @override
  String toString() => 'No available node in this subscription';
}
