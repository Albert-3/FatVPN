import 'dart:io';

import 'package:singbox_mm/singbox_mm_platform_interface.dart';

import 'app_logger.dart';

/// Measures round-trip latency to a node by timing a raw TCP connect to its
/// VPN port. There's no ICMP ping API available cross-platform on mobile
/// without native code/root, and Remnawave doesn't report client-perceived
/// latency, so a TCP handshake to the real node address is the closest
/// realistic proxy for "ping" available from the app.
///
/// Where that handshake is issued from matters, and the two platforms differ:
///
/// * **Android** — the tunnel service deliberately keeps this app's sockets out
///   of the tun device (see VpnTunBuilderConfigurator), so a connect from here
///   already travels the real underlay whether or not the VPN is up.
/// * **iOS** — the container app's traffic *is* carried by the packet tunnel.
///   Measuring from here while connected gives "device → current server →
///   candidate": every alternative inflated by the live tunnel's round-trip,
///   and every one of them unreachable the moment that tunnel stops passing
///   traffic — which is precisely when a replacement has to be found. So the
///   measurement is delegated to the tunnel's own extension, whose sockets
///   bypass the tunnel it provides.
class PingService {
  /// [measureOutsideProcess] overrides the platform decision; tests set it
  /// because the host VM is neither of the two platforms this class is about.
  PingService({SignboxVpnPlatform? platform, bool? measureOutsideProcess})
      : _plugin = platform ?? SignboxVpnPlatform.instance,
        // Only iOS captures the app's own traffic; asking anywhere else would
        // cross a platform channel to answer what a plain socket answers.
        _needsExtensionMeasurement = measureOutsideProcess ?? Platform.isIOS;

  final SignboxVpnPlatform _plugin;
  final bool _needsExtensionMeasurement;

  Future<int?> pingMs(String address, int port) async {
    if (_needsExtensionMeasurement) {
      final (:answered, :latencyMs) = await _pingViaExtension(address, port);
      // An answer is a verdict about the node — including "unreachable", which
      // means the extension tried and the handshake didn't complete. Only the
      // absence of an answer falls through.
      if (answered) return latencyMs;
      // We never got one, so measure here instead: a number inflated by the
      // tunnel's own round-trip beats no number at all, and since every
      // candidate is measured the same way, comparisons between them survive
      // even where the absolute values don't.
    }
    return _pingDirectly(address, port);
  }

  Future<({bool answered, int? latencyMs})> _pingViaExtension(
    String address,
    int port,
  ) async {
    try {
      final result = await _plugin.pingServerOutsideTunnel(
        host: address,
        port: port,
        timeout: const Duration(seconds: 3),
      );
      return (answered: true, latencyMs: result.success ? result.latencyMs : null);
    } catch (e) {
      // Plugin missing, extension unreachable, channel error — anything that
      // leaves us knowing nothing about the node itself.
      log.w('Extension-side ping unavailable, measuring in-app instead: $e');
      return (answered: false, latencyMs: null);
    }
  }

  Future<int?> _pingDirectly(String address, int port) async {
    final stopwatch = Stopwatch()..start();
    try {
      final socket = await Socket.connect(
        address,
        port,
        timeout: const Duration(seconds: 3),
      );
      stopwatch.stop();
      socket.destroy();
      return stopwatch.elapsedMilliseconds;
    } catch (_) {
      return null;
    }
  }
}
