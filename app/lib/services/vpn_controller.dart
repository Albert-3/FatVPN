import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:singbox_mm/singbox_mm.dart';

import '../models/server_country.dart';
import 'api_client.dart';
import 'ping_service.dart';
import 'vless_config_parser.dart';

/// Owns the sing-box VPN tunnel and exposes real connection state to the UI,
/// replacing the fake local-timer toggle that used to live in [HomeScreen].
class VpnController extends ChangeNotifier {
  VpnController({ApiClient? apiClient, PingService? pingService})
      : _apiClient = apiClient ?? ApiClient(),
        _pingService = pingService ?? PingService();

  final ApiClient _apiClient;
  final PingService _pingService;
  final SignboxVpn _vpn = SignboxVpn();
  StreamSubscription<VpnConnectionState>? _stateSubscription;

  bool _initialized = false;
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
      _state = state;
      notifyListeners();
    });
    _initialized = true;
  }

  Future<void> connectToBestNode(ServerCountry country, String accessToken) async {
    _errorMessage = null;
    _state = VpnConnectionState.connecting;
    notifyListeners();

    try {
      await _ensureInitialized();

      final node = await _pickBestNode(country);
      final (content, _) = await _apiClient.getConfig(accessToken);
      final uris = parseVlessUris(content);
      final uri = findUriForNode(uris, node);
      if (uri == null) {
        throw StateError('No matching config found for ${node.name}');
      }

      await _vpn.connectManualConfigLink(configLink: uri);
      _connectedNodeName = node.name;
    } catch (e) {
      _state = VpnConnectionState.error;
      _errorMessage = e is SignboxVpnException ? e.message : e.toString();
      notifyListeners();
      rethrow;
    }
  }

  Future<ServerNode> _pickBestNode(ServerCountry country) async {
    ServerNode? best;
    int? bestPing;
    for (final node in country.nodes) {
      final ms = await _pingService.pingMs(node.address, node.port);
      if (ms != null && (bestPing == null || ms < bestPing)) {
        best = node;
        bestPing = ms;
      }
    }
    return best ?? country.nodes.first;
  }

  Future<void> disconnect() async {
    await _vpn.stop();
    _connectedNodeName = null;
  }

  @override
  void dispose() {
    _stateSubscription?.cancel();
    super.dispose();
  }
}
