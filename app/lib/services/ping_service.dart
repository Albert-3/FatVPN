import 'dart:io';

import 'package:singbox_mm/singbox_mm_platform_interface.dart';

import 'app_logger.dart';

/// Measures round-trip latency to a node by timing a raw TCP connect to its
/// VPN port. There's no ICMP ping API available cross-platform on mobile
/// without native code/root, and Remnawave doesn't report client-perceived
/// latency, so a TCP handshake to the real node address is the closest
/// realistic proxy for "ping" available from the app.
///
/// Where that handshake is issued from matters. Both platforms carry this app's
/// own traffic in the tunnel — Android deliberately so, see
/// VpnTunBuilderConfigurator — which makes a plain connect measure "device →
/// current server → candidate": every alternative inflated by the live tunnel's
/// round-trip, and every one of them unreachable the moment that tunnel stops
/// passing traffic, which is precisely when a replacement has to be found. So
/// the measurement goes through [SignboxVpnPlatform.pingServerOutsideTunnel],
/// which steps around the tunnel (the packet-tunnel extension on iOS,
/// `VpnService.protect()` on Android).
class PingService {
  /// [measureOutsideProcess] overrides the platform decision; tests set it
  /// because the host VM is neither of the two platforms this class is about.
  PingService({SignboxVpnPlatform? platform, bool? measureOutsideProcess})
      : _plugin = platform ?? SignboxVpnPlatform.instance,
        _measureOutsideTunnel =
            measureOutsideProcess ?? (Platform.isIOS || Platform.isAndroid);

  final SignboxVpnPlatform _plugin;
  final bool _measureOutsideTunnel;

  Future<int?> pingMs(String address, int port) async {
    if (_measureOutsideTunnel) {
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
      log.w('Out-of-tunnel ping unavailable, measuring in-app instead: $e');
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
