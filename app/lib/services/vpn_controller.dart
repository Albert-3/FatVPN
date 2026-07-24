import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
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
  StreamSubscription<VpnConnectionState>? _stateSubscription;

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

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    await _vpn.initialize(const SingboxRuntimeOptions(logLevel: 'warn'));
    _stateSubscription = _vpn.stateStream.listen((state) {
      final previous = _state;
      _state = state;
      notifyListeners();
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

  Future<void> disconnect() async {
    log.i('Disconnecting tunnel');
    _userDisconnecting = true;
    await _vpn.stop();
    _connectedNodeName = null;
  }

  @override
  void dispose() {
    _stateSubscription?.cancel();
    super.dispose();
  }
}
