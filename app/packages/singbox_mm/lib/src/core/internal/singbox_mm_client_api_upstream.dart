part of '../singbox_mm_client.dart';

/// Connecting through a proxy that already runs on this device.
///
/// Some nodes speak a transport this core has no implementation for — Xray's
/// XHTTP with its padding obfuscation is the case this exists for. Such a node
/// can still be reached by letting another engine terminate the protocol
/// locally and handing sing-box a plain SOCKS server to talk to.
///
/// The tunnel is built from the node's own profile, so routing, DNS and the
/// bypass rules stay exactly what they would have been on a direct connect —
/// only the proxy outbound is swapped for the local SOCKS endpoint.
extension SignboxVpnUpstreamProxyApi on SignboxVpn {
  /// Connects to [configLink] by running the bundled Xray core against it and
  /// pointing sing-box at the local SOCKS server that core offers.
  ///
  /// The Xray config travels to the tunnel process before [start] because the
  /// core has to come up there, inside the service whose sockets bypass the
  /// tun device — a core started in the app process would have its own traffic
  /// captured by the tunnel it is feeding.
  Future<ManualConnectResult> connectViaXrayCore({
    required VpnProfile profile,
    required String configLink,
    int socksPort = kXrayBridgeSocksPort,
    BypassPolicy bypassPolicy = const BypassPolicy(),
    TrafficThrottlePolicy throttlePolicy = const TrafficThrottlePolicy(),
    SingboxFeatureSettings? featureSettings,
    bool requestPermission = true,
  }) async {
    final Map<String, Object?> xrayConfig = buildXraySocksBridgeConfig(
      configLink: configLink,
      socksPort: socksPort,
    );
    await _guard(() => _platform.setXrayConfig(jsonEncode(xrayConfig)));
    return connectUpstreamSocks(
      profile: profile,
      socksPort: socksPort,
      bypassPolicy: bypassPolicy,
      throttlePolicy: throttlePolicy,
      featureSettings: featureSettings,
      requestPermission: requestPermission,
    );
  }

  Future<ManualConnectResult> connectUpstreamSocks({
    required VpnProfile profile,
    required int socksPort,
    String socksHost = '127.0.0.1',
    BypassPolicy bypassPolicy = const BypassPolicy(),
    TrafficThrottlePolicy throttlePolicy = const TrafficThrottlePolicy(),
    SingboxFeatureSettings? featureSettings,
    bool requestPermission = true,
  }) async {
    _activeGfwPresetMode = null;
    final SingboxFeatureSettings effectiveSettings =
        featureSettings ?? _featureSettings;
    // Built with the real profile on purpose: split tunnelling, DNS and the
    // bypass rules all key off the node, and a profile pointing at 127.0.0.1
    // would describe a different session than the one the user chose.
    //
    // Note what does *not* protect the local engine here: sing-box emits no
    // route rule for the node's own address, on either path. Keeping the
    // engine's traffic out of the tun it feeds is the platform's job — the
    // service protects its sockets on Android, and a Network Extension's own
    // sockets bypass its tunnel on iOS.
    final Map<String, Object?> config = await applyProfile(
      profile: profile,
      bypassPolicy: bypassPolicy,
      throttlePolicy: throttlePolicy,
      featureSettings: effectiveSettings,
    );
    final Map<String, Object?> patched = redirectProxyOutboundToSocks(
      config: config,
      tag: profile.tag,
      host: socksHost,
      port: socksPort,
    );
    await applyConfigDocument(SingboxConfigDocument.fromMap(patched));
    await _maybeRequestPermissionsInternal(
      this,
      requestPermission: requestPermission,
    );
    await start();
    return ManualConnectResult(profile: profile, appliedConfig: patched);
  }
}

/// Replaces the outbound tagged [tag] with a SOCKS5 outbound pointing at
/// [host]:[port], keeping the tag so every route rule that names it still
/// applies.
///
/// Deliberately a pure function on the config map: this is the whole of the
/// "use another engine" change on the sing-box side, and it stays testable
/// without a running tunnel.
Map<String, Object?> redirectProxyOutboundToSocks({
  required Map<String, Object?> config,
  required String tag,
  required String host,
  required int port,
}) {
  final Map<String, Object?> patched = jsonDecode(jsonEncode(config))
      as Map<String, Object?>;
  final Object? rawOutbounds = patched['outbounds'];
  if (rawOutbounds is! List) {
    throw const FormatException('Config has no outbounds to redirect.');
  }
  final List<Object?> outbounds = List<Object?>.from(rawOutbounds);
  int index = outbounds.indexWhere(
    (Object? item) => item is Map && item['tag'] == tag,
  );
  if (index < 0) {
    throw FormatException('No outbound tagged "$tag" to redirect.');
  }
  outbounds[index] = <String, Object?>{
    'type': 'socks',
    'tag': tag,
    'server': host,
    'server_port': port,
    'version': '5',
    // The local engine does its own multiplexing over the real transport, and
    // UDP is handled by it too, so nothing extra belongs on this hop.
    'udp_over_tcp': false,
  };
  patched['outbounds'] = outbounds;
  return patched;
}
