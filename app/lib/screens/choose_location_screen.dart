import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../l10n/strings.dart';
import '../models/server_country.dart';
import '../services/api_client.dart';
import '../services/ping_service.dart';
import '../theme/app_colors.dart';
import '../utils/country_flag.dart';

/// Result of picking a location: either the automatic "best server" mode, or a
/// specific [country]. Returned via `Navigator.pop`; a plain `null` still means
/// the user backed out without choosing.
class LocationSelection {
  const LocationSelection.best() : country = null;
  const LocationSelection.country(ServerCountry this.country);

  final ServerCountry? country;
  bool get isBest => country == null;
}

class ChooseLocationScreen extends StatefulWidget {
  const ChooseLocationScreen({
    super.key,
    required this.accessToken,
    this.initialServers = const [],
    this.selectedCountry,
  });

  final String accessToken;
  final List<ServerCountry> initialServers;

  /// Country code currently active, or null when "best server" (auto) is active
  /// — used to highlight the current choice.
  final String? selectedCountry;

  @override
  State<ChooseLocationScreen> createState() => _ChooseLocationScreenState();
}

class _ChooseLocationScreenState extends State<ChooseLocationScreen> {
  final _apiClient = ApiClient();
  final _pingService = PingService();

  late List<ServerCountry> _servers = widget.initialServers;
  bool _loading = false;
  String? _error;

  String? _expandedCountry;
  final Map<String, int?> _pingByNodeId = {};

  @override
  void initState() {
    super.initState();
    if (_servers.isEmpty) {
      _loadServers();
    }
  }

  Future<void> _loadServers() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final servers = await _apiClient.getUsableServers(widget.accessToken);
      setState(() {
        _servers = servers;
        _loading = false;
      });
    } on ApiException catch (e) {
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = S.of(context).couldNotReachServer;
        _loading = false;
      });
    }
  }

  void _toggleExpanded(ServerCountry country) {
    final isExpanding = _expandedCountry != country.country;
    setState(() => _expandedCountry = isExpanding ? country.country : null);
    if (isExpanding) {
      _measurePings(country);
    }
  }

  Future<void> _measurePings(ServerCountry country) async {
    for (final node in country.nodes) {
      if (_pingByNodeId.containsKey(node.id)) continue;
      final ms = await _pingService.pingMs(node.address, node.port);
      if (!mounted) return;
      setState(() => _pingByNodeId[node.id] = ms);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(context, s),
            Expanded(child: _buildBody(s)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(Strings s) {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.accent),
      );
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: const TextStyle(color: Colors.redAccent)),
            const SizedBox(height: 12),
            TextButton(onPressed: _loadServers, child: Text(s.retry)),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      children: [
        const SizedBox(height: 4),
        _buildBestTile(s),
        const SizedBox(height: 16),
        Text(
          s.allLocations,
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 12,
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: 8),
        for (final country in _servers) _buildCountryTile(s, country),
        const SizedBox(height: 20),
      ],
    );
  }

  /// Selectable "best server" (automatic) entry — lets the user return to auto
  /// mode after having picked a specific country.
  Widget _buildBestTile(Strings s) {
    final isActive = widget.selectedCountry == null;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => Navigator.of(context).pop(const LocationSelection.best()),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(16),
          border: isActive ? Border.all(color: AppColors.accent, width: 1.5) : null,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            const Icon(Icons.bolt, color: AppColors.accent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.bestServer,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    s.bestServerAuto,
                    style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
                  ),
                ],
              ),
            ),
            if (isActive)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.accent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  s.activeBadge,
                  style: const TextStyle(
                    color: Colors.black,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              )
            else
              Text(s.select, style: const TextStyle(color: AppColors.accent)),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, Strings s) {
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
              s.chooseLocation,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          IconButton(
            onPressed: _loadServers,
            icon: const Icon(Icons.refresh, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _buildCountryTile(Strings s, ServerCountry country) {
    final isExpanded = _expandedCountry == country.country;
    final isSelected = widget.selectedCountry == country.country;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(16),
        border: isSelected ? Border.all(color: AppColors.accent, width: 1.5) : null,
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: country.nodes.isEmpty ? null : () => _toggleExpanded(country),
            onLongPress: () =>
                Navigator.of(context).pop(LocationSelection.country(country)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Text(
                    countryCodeToFlagEmoji(country.flag),
                    style: const TextStyle(fontSize: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          country.country,
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          s.serversCount(country.nodeCount),
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () =>
                        Navigator.of(context).pop(LocationSelection.country(country)),
                    child: Text(s.select, style: const TextStyle(color: AppColors.accent)),
                  ),
                  if (country.nodes.isNotEmpty)
                    Icon(
                      isExpanded ? Icons.expand_less : Icons.expand_more,
                      color: AppColors.textSecondary,
                    ),
                ],
              ),
            ),
          ),
          if (isExpanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Column(
                children: [
                  for (final node in country.nodes) _buildNodeRow(s, node),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildNodeRow(Strings s, ServerNode node) {
    final ping = _pingByNodeId[node.id];
    final measured = _pingByNodeId.containsKey(node.id);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          const SizedBox(width: 34),
          Expanded(
            child: Text(
              node.name,
              style: const TextStyle(color: AppColors.textPrimary, fontSize: 13),
            ),
          ),
          if (!measured)
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.textSecondary),
            )
          else
            Text(
              ping != null ? '${ping}ms' : s.unreachable,
              style: TextStyle(
                color: ping != null ? AppColors.accent : Colors.redAccent,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
        ],
      ),
    );
  }
}
