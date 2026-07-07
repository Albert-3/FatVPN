import 'dart:async';

import 'package:flutter/material.dart';
import 'package:singbox_mm/singbox_mm.dart';

import '../l10n/app_localizations.dart';
import '../l10n/strings.dart';
import '../models/server_country.dart';
import '../services/api_client.dart';
import '../services/auth_controller.dart';
import '../services/connection_settings_controller.dart';
import '../services/ping_service.dart';
import '../services/vpn_controller.dart';
import '../theme/app_colors.dart';
import '../utils/country_flag.dart';
import 'choose_location_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.auth,
    required this.connectionSettings,
  });

  final AuthController auth;
  final ConnectionSettingsController connectionSettings;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _apiClient = ApiClient();
  late final _vpn = VpnController(
    connectionSettings: widget.connectionSettings,
  );
  final _pingService = PingService();

  Timer? _timer;
  Timer? _connSettingsDebounce;
  Duration _sessionTime = Duration.zero;

  List<ServerCountry> _servers = [];
  ServerCountry? _selectedServer;
  bool _serverExplicitlySelected = false;
  bool _loadingServers = true;
  String? _serversError;

  final Map<String, int?> _bestPingByCountry = {};
  bool _measuringPings = false;

  bool get _connected => _vpn.isConnected;

  @override
  void initState() {
    super.initState();
    _vpn.addListener(_handleVpnChange);
    widget.connectionSettings.addListener(_onConnSettingsChanged);
    _loadServers();
  }

  /// Re-applies connection settings (DNS / network stack / split-tunnel) on the
  /// fly: when they change while the tunnel is up, reconnect so the new
  /// featureSettings take effect without a manual off/on. Debounced so rapid
  /// split-tunnel edits coalesce into a single reconnect.
  void _onConnSettingsChanged() {
    if (!_isActive) return;
    _connSettingsDebounce?.cancel();
    _connSettingsDebounce = Timer(const Duration(milliseconds: 1500), () async {
      if (!mounted || !_isActive) return;
      await _switchOff();
      if (!mounted) return;
      await _connectCurrentSelection();
    });
  }

  void _handleVpnChange() {
    if (_vpn.isConnected && _timer == null) {
      _sessionTime = Duration.zero;
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        setState(() => _sessionTime += const Duration(seconds: 1));
      });
    } else if (!_vpn.isConnected && _timer != null) {
      _timer?.cancel();
      _timer = null;
    }
    if (mounted) setState(() {});
  }

  Future<void> _loadServers() async {
    setState(() {
      _loadingServers = true;
      _serversError = null;
    });
    try {
      final servers = await _apiClient.getUsableServers(widget.auth.session!.accessToken);
      setState(() {
        _servers = servers;
        _loadingServers = false;
      });
      unawaited(_measureBestPings(servers));
      // Right after a trial grant, bring the tunnel up automatically so the
      // user reaches Telegram (to buy a key) without a manual tap.
      if (widget.auth.consumeAutoConnect()) {
        unawaited(_autoConnect());
      }
    } on ApiException catch (e) {
      setState(() {
        _serversError = e.message;
        _loadingServers = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _serversError = S.of(context).couldNotReachServer;
        _loadingServers = false;
      });
    }
  }

  /// Ranks countries by real latency (fastest node per country) instead of
  /// just showing whatever order `/servers` returned them in.
  Future<void> _measureBestPings(List<ServerCountry> servers) async {
    setState(() {
      _measuringPings = true;
      _bestPingByCountry.clear();
    });
    await Future.wait(servers.map((country) async {
      final pings = await Future.wait(
        country.nodes.map((n) => _pingService.pingMs(n.address, n.port)),
      );
      final reachable = pings.whereType<int>();
      final best = reachable.isEmpty ? null : reachable.reduce((a, b) => a < b ? a : b);
      if (!mounted) return;
      setState(() => _bestPingByCountry[country.country] = best);
    }));
    if (!mounted) return;
    setState(() => _measuringPings = false);
  }

  List<ServerCountry> get _rankedServers {
    final ranked = [..._servers];
    ranked.sort((a, b) {
      final pa = _bestPingByCountry[a.country];
      final pb = _bestPingByCountry[b.country];
      if (pa == null && pb == null) return 0;
      if (pa == null) return 1;
      if (pb == null) return -1;
      return pa.compareTo(pb);
    });
    return ranked;
  }

  /// Opens the location picker and applies the choice: a specific country, or
  /// "best server" (auto) — which clears the explicit selection so Connect goes
  /// back to picking the fastest node overall.
  Future<void> _openLocationPicker() async {
    final choice = await Navigator.of(context).push<LocationSelection>(
      MaterialPageRoute(
        builder: (_) => ChooseLocationScreen(
          initialServers: _servers,
          accessToken: widget.auth.session!.accessToken,
          selectedCountry:
              _serverExplicitlySelected ? _selectedServer?.country : null,
        ),
      ),
    );
    if (choice == null || !mounted) return;
    final wasActive = _isActive;
    setState(() {
      if (choice.isBest) {
        _serverExplicitlySelected = false;
        _selectedServer = null;
      } else {
        _selectedServer = choice.country;
        _serverExplicitlySelected = true;
      }
    });
    // Apply the new location immediately: if the tunnel is up, tear it down and
    // reconnect to the new choice (otherwise the change only took effect after a
    // manual off/on).
    if (wasActive) {
      await _switchOff();
      if (!mounted) return;
      await _connectCurrentSelection();
    }
  }

  /// Tapping a "Best servers" shortcut selects that country and connects to it
  /// right away (reconnecting if a tunnel is already up), so it works as a
  /// one-tap quick-connect rather than just highlighting the tile.
  Future<void> _selectAndConnect(ServerCountry country) async {
    final wasActive = _isActive;
    setState(() {
      _selectedServer = country;
      _serverExplicitlySelected = true;
    });
    if (wasActive) {
      await _switchOff();
      if (!mounted) return;
    }
    await _connectCurrentSelection();
  }

  bool get _isActive =>
      _vpn.isConnected ||
      _vpn.state == VpnConnectionState.connecting ||
      _vpn.state == VpnConnectionState.preparing;

  /// Stops the tunnel and waits until it's actually down. A follow-up connect
  /// issued while the previous session is still tearing down gets dropped by
  /// the plugin (symptom: you pick a new country but stay on the old node), so
  /// we block until the state machine reports disconnected.
  Future<void> _switchOff() async {
    await _vpn.disconnect();
    final deadline = DateTime.now().add(const Duration(seconds: 4));
    while (_vpn.state != VpnConnectionState.disconnected &&
        _vpn.state != VpnConnectionState.error &&
        DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 150));
    }
  }

  /// One-off auto-connect to the fastest node overall (used after a trial
  /// grant). Mirrors the "best overall" branch of the power button.
  Future<void> _autoConnect() async {
    final session = widget.auth.session;
    if (session == null || _servers.isEmpty) return;
    try {
      final picked = await _vpn.connectToBestOverall(_servers, session.accessToken);
      if (picked != null && mounted) {
        setState(() => _selectedServer = picked);
      }
    } catch (_) {
      // Surfaced via _vpn.errorMessage in the status section.
    }
  }

  Future<void> _onPowerButtonTap() async {
    if (_vpn.isConnected || _vpn.state == VpnConnectionState.connecting) {
      await _vpn.disconnect();
      return;
    }
    await _connectCurrentSelection();
  }

  /// Connects to the current selection: the explicitly chosen country, or the
  /// fastest node overall in "best server" mode.
  Future<void> _connectCurrentSelection() async {
    final session = widget.auth.session;
    if (session == null || _servers.isEmpty) return;
    try {
      if (_serverExplicitlySelected && _selectedServer != null) {
        await _vpn.connectToBestNode(_selectedServer!, session.accessToken);
      } else {
        final picked = await _vpn.connectToBestOverall(_servers, session.accessToken);
        if (picked != null && mounted) {
          setState(() => _selectedServer = picked);
        }
      }
    } catch (_) {
      // Error is surfaced via _vpn.errorMessage in the status section.
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _connSettingsDebounce?.cancel();
    widget.connectionSettings.removeListener(_onConnSettingsChanged);
    _vpn.removeListener(_handleVpnChange);
    _vpn.dispose();
    super.dispose();
  }

  String get _sessionLabel {
    final h = _sessionTime.inHours.toString().padLeft(2, '0');
    final m = (_sessionTime.inMinutes % 60).toString().padLeft(2, '0');
    final s = (_sessionTime.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            children: [
              const SizedBox(height: 8),
              _buildHeader(),
              const SizedBox(height: 20),
              _buildLocationSelector(s),
              const Spacer(),
              _buildPowerButton(),
              const SizedBox(height: 20),
              _buildStatus(s),
              const Spacer(),
              _buildBestServers(s),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return SizedBox(
      height: 48,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Image.asset('assets/images/logo.png', height: 26),
              const SizedBox(width: 8),
              const Text(
                'FatVPN',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => SettingsScreen(
                    auth: widget.auth,
                    connectionSettings: widget.connectionSettings,
                  ),
                ),
              ),
              icon: const Icon(
                Icons.settings,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLocationSelector(Strings s) {
    return GestureDetector(
      onTap: _openLocationPicker,
      child: _locationCard(s),
    );
  }

  Widget _locationCard(Strings s) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(
            _connected ? Icons.public : Icons.public_outlined,
            color: _connected ? AppColors.accent : AppColors.textSecondary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _connected ? s.connectedTo : s.location,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  (_connected || _serverExplicitlySelected) && _selectedServer != null
                      ? _selectedServer!.country
                      : s.bestServer,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          Icon(
            Icons.signal_cellular_alt,
            size: 18,
            color: _connected ? AppColors.accent : AppColors.textSecondary,
          ),
          const SizedBox(width: 8),
          const Icon(Icons.chevron_right, color: AppColors.textSecondary),
        ],
      ),
    );
  }

  Widget _buildPowerButton() {
    return GestureDetector(
      onTap: _onPowerButtonTap,
      child: Container(
        width: 160,
        height: 160,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _connected ? AppColors.accent : AppColors.card,
          boxShadow: _connected
              ? [
                  BoxShadow(
                    color: AppColors.accent.withValues(alpha: 0.45),
                    blurRadius: 40,
                    spreadRadius: 4,
                  ),
                ]
              : [],
        ),
        child: Icon(
          Icons.power_settings_new,
          size: 64,
          color: _connected ? const Color(0xFF0B1622) : AppColors.textSecondary,
        ),
      ),
    );
  }

  Widget _buildStatus(Strings s) {
    final connecting = _vpn.state == VpnConnectionState.connecting;
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (connecting)
              const SizedBox(
                width: 10,
                height: 10,
                child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accent),
              )
            else
              Icon(
                Icons.circle,
                size: 10,
                color: _connected ? AppColors.accent : AppColors.textSecondary,
              ),
            const SizedBox(width: 8),
            Text(
              connecting ? s.connecting : (_connected ? s.connected : s.disconnected),
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (_connected) ...[
          Text(
            _sessionLabel,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            s.sessionTime,
            style: const TextStyle(color: AppColors.textSecondary, fontSize: 11),
          ),
        ] else if (_vpn.errorMessage != null)
          Text(
            _vpn.errorMessage!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.redAccent, fontSize: 12),
          )
        else
          Text(
            s.connectionNotProtected,
            style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
          ),
      ],
    );
  }

  Widget _buildBestServers(Strings s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              s.bestServers,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            TextButton(
              onPressed: _openLocationPicker,
              child: Text(
                s.seeAll,
                style: const TextStyle(color: AppColors.accent),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_loadingServers)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: CircularProgressIndicator(color: AppColors.accent),
            ),
          )
        else if (_serversError != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _serversError!,
                    style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                  ),
                ),
                TextButton(onPressed: _loadServers, child: Text(s.retry)),
              ],
            ),
          )
        else
          Row(
            children: _rankedServers.take(3).map((server) {
              final isSelected = _serverExplicitlySelected &&
                  server.country == _selectedServer?.country;
              final ping = _bestPingByCountry[server.country];
              final pingKnown = _bestPingByCountry.containsKey(server.country);
              return Expanded(
                child: GestureDetector(
                  onTap: () => _selectAndConnect(server),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    decoration: BoxDecoration(
                      color: AppColors.card,
                      borderRadius: BorderRadius.circular(14),
                      border: isSelected
                          ? Border.all(color: AppColors.accent, width: 1.5)
                          : null,
                    ),
                    child: Column(
                      children: [
                        Text(
                          countryCodeToFlagEmoji(server.flag),
                          style: const TextStyle(fontSize: 24),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          server.country,
                          style: TextStyle(
                            color: isSelected
                                ? AppColors.accent
                                : AppColors.textPrimary,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        if (_measuringPings && !pingKnown)
                          const SizedBox(
                            width: 10,
                            height: 10,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.5,
                              color: AppColors.textSecondary,
                            ),
                          )
                        else
                          Text(
                            ping != null ? '${ping}ms' : s.unreachable,
                            style: TextStyle(
                              color: ping != null ? AppColors.accent : Colors.redAccent,
                              fontSize: 10,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
      ],
    );
  }
}
