import 'dart:io';

/// Measures round-trip latency to a node by timing a raw TCP connect to its
/// VPN port. There's no ICMP ping API available cross-platform on mobile
/// without native code/root, and Remnawave doesn't report client-perceived
/// latency, so a TCP handshake to the real node address is the closest
/// realistic proxy for "ping" available from the app.
class PingService {
  Future<int?> pingMs(String address, int port) async {
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
