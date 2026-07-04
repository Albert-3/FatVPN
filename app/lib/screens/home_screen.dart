import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import 'choose_location_screen.dart';
import 'settings_screen.dart';

class _Server {
  const _Server(this.flag, this.country, this.city);

  final String flag;
  final String country;
  final String city;
}

const _bestServers = [
  _Server('🇩🇪', 'Germany', 'Frankfurt'),
  _Server('🇳🇱', 'Netherlands', 'Amsterdam'),
  _Server('🇯🇵', 'Japan', 'Tokyo'),
];

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _connected = false;
  _Server _selectedServer = _bestServers.first;
  Timer? _timer;
  Duration _sessionTime = Duration.zero;

  void _toggleConnection() {
    setState(() {
      _connected = !_connected;
      if (_connected) {
        _sessionTime = Duration.zero;
        _timer = Timer.periodic(const Duration(seconds: 1), (_) {
          setState(() => _sessionTime += const Duration(seconds: 1));
        });
      } else {
        _timer?.cancel();
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
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
              _buildLocationSelector(),
              const Spacer(),
              _buildPowerButton(),
              const SizedBox(height: 20),
              _buildStatus(),
              const Spacer(),
              _buildBestServers(),
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
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
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

  Widget _buildLocationSelector() {
    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const ChooseLocationScreen()),
      ),
      child: _locationCard(),
    );
  }

  Widget _locationCard() {
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
                  _connected ? 'Connected to' : 'LOCATION',
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _connected
                      ? '${_selectedServer.country} · ${_selectedServer.city}'
                      : 'Best server',
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
      onTap: _toggleConnection,
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

  Widget _buildStatus() {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.circle,
              size: 10,
              color: _connected ? AppColors.accent : AppColors.textSecondary,
            ),
            const SizedBox(width: 8),
            Text(
              _connected ? 'Connected' : 'Disconnected',
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
          const Text(
            'SESSION TIME',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 11),
          ),
        ] else
          const Text(
            'Your connection is not protected',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
          ),
      ],
    );
  }

  Widget _buildBestServers() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Best servers',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            TextButton(
              onPressed: () {},
              child: const Text(
                'See all',
                style: TextStyle(color: AppColors.accent),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: _bestServers.map((server) {
            final isSelected = _connected && server == _selectedServer;
            return Expanded(
              child: GestureDetector(
                onTap: () => setState(() => _selectedServer = server),
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
                      Text(server.flag, style: const TextStyle(fontSize: 24)),
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
