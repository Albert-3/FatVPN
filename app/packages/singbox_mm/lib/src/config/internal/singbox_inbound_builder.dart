import '../../models/singbox_feature_settings.dart';
import '../../models/traffic_throttle_policy.dart';

class SingboxInboundBuilder {
  const SingboxInboundBuilder();

  List<Object?> build({
    required SingboxFeatureSettings settings,
    required String tunInterfaceName,
    required String tunInet4Address,
    TrafficThrottlePolicy throttlePolicy = const TrafficThrottlePolicy(),
  }) {
    final List<Object?> inbounds = <Object?>[];
    final bool shareLan = settings.inbound.shareVpnInLocalNetwork;

    if (settings.inbound.serviceMode == SingboxServiceMode.vpn) {
      final List<String> includePackages = _dedupeStrings(
        settings.inbound.includePackages,
      );
      final List<String> excludePackages = _dedupeStrings(
        settings.inbound.excludePackages,
      );
      final bool splitTunnelingEnabled =
          settings.inbound.splitTunnelingEnabled ??
          (includePackages.isNotEmpty || excludePackages.isNotEmpty);
      // The inet6 address is what makes the config's `::/0 → block` rule
      // reachable at all: without an address of that family the OS routes no
      // IPv6 into the tunnel, so the rule never sees a packet and every v6
      // connection leaves around the VPN. See [defaultTunInet6Address].
      final String? tunInet6Address = defaultTunInet6Address;
      final Map<String, Object?> tunInbound = <String, Object?>{
        'type': 'tun',
        'tag': 'tun-in',
        'interface_name': tunInterfaceName,
        'address': <String>[tunInet4Address, ?tunInet6Address],
        'auto_route': true,
        'strict_route': settings.inbound.strictRoute,
        'stack': _toTunStack(settings.inbound.tunImplementation),
        // One MTU, three places it can come from, in the order of how much the
        // caller knows.
        //
        // The throttle policy wins because it is the only one that changes at
        // runtime: the auto-MTU probe measures a failing path and steps this
        // number down (`_effectiveThrottlePolicyForProfile`,
        // `_maybeStepDownMtu`). While the builder hardcoded 1100 that whole
        // mechanism was decoration — it measured, decided, rewrote the config,
        // and emitted the same MTU as before, so a path-MTU problem could not
        // be fixed by the code written to fix it.
        'mtu':
            throttlePolicy.tunMtu ?? settings.inbound.mtu ?? defaultTunMtu,
      };
      if (splitTunnelingEnabled && includePackages.isNotEmpty) {
        tunInbound['include_package'] = includePackages;
      }
      if (splitTunnelingEnabled && excludePackages.isNotEmpty) {
        tunInbound['exclude_package'] = excludePackages;
      }

      inbounds.add(tunInbound);
    }

    final int? mixedPort = settings.inbound.mixedPort;
    if (mixedPort != null ||
        settings.inbound.serviceMode == SingboxServiceMode.proxyOnly) {
      inbounds.add(<String, Object?>{
        'type': 'mixed',
        'tag': 'mixed-in',
        'listen': shareLan ? '0.0.0.0' : '127.0.0.1',
        'listen_port': mixedPort ?? 10808,
      });
    }

    final int? transparentProxyPort = settings.inbound.transparentProxyPort;
    if (transparentProxyPort != null) {
      inbounds.add(<String, Object?>{
        'type': 'redirect',
        'tag': 'redirect-in',
        'listen': shareLan ? '0.0.0.0' : '127.0.0.1',
        'listen_port': transparentProxyPort,
      });
    }

    return inbounds;
  }

  /// Maps the chosen stack onto sing-box's `tun.stack`.
  ///
  /// Both values used to return `'gvisor'`, so the "network stack" setting in
  /// the UI did nothing at all: a user who picked the system stack — the whole
  /// point of the option, and the cheaper one — silently got the other.
  String _toTunStack(SingboxTunImplementation implementation) {
    switch (implementation) {
      case SingboxTunImplementation.system:
        return 'system';
      case SingboxTunImplementation.gvisor:
        return 'gvisor';
    }
  }

  List<String> _dedupeStrings(List<String> input) {
    final Set<String> output = <String>{};
    for (final String raw in input) {
      final String value = raw.trim();
      if (value.isNotEmpty) {
        output.add(value);
      }
    }
    return output.toList(growable: false);
  }
}
