part of '../singbox_mm_client.dart';

TrafficThrottlePolicy _effectiveThrottlePolicyForProfileInternal(
  SignboxVpn client, {
  required VpnProfile profile,
  required TrafficThrottlePolicy base,
}) {
  final bool enforceUdpFragment = _shouldForceUdpFragmentForProfileInternal(
    profile,
  );
  final List<int> mtuCandidates = _resolveMtuCandidatesInternal(base);
  if (!profile.tls.enabled ||
      !base.enableAutoMtuProbe ||
      mtuCandidates.isEmpty) {
    if (enforceUdpFragment && !base.udpFragment) {
      return base.copyWith(udpFragment: true);
    }
    return base;
  }

  final int? probeCursor = client._endpointMtuProbeCursorByTag[profile.tag];
  if (probeCursor == null && base.tunMtu == null) {
    // Nobody has asked for a particular MTU and nothing has probed yet, so
    // there is nothing to tune: pinning the highest candidate here would
    // override the platform default ([defaultTunMtu]) on every ordinary
    // connect, which is not the probe's job — it exists to step *down* from a
    // baseline once a path proves it cannot carry one.
    if (enforceUdpFragment && !base.udpFragment) {
      return base.copyWith(udpFragment: true);
    }
    return base;
  }

  final int configuredMtuIndex = max(
    0,
    mtuCandidates.indexOf(base.tunMtu ?? -1),
  );
  final int cursor = probeCursor ?? configuredMtuIndex;
  final int safeIndex = max(0, min(cursor, mtuCandidates.length - 1));
  final int tunedMtu = mtuCandidates[safeIndex];
  final bool tunedUdpFragment = enforceUdpFragment ? true : base.udpFragment;
  return base.copyWith(tunMtu: tunedMtu, udpFragment: tunedUdpFragment);
}

List<int> _resolveMtuCandidatesInternal(TrafficThrottlePolicy policy) {
  final Set<int> values = <int>{
    ?policy.tunMtu,
    ...policy.mtuProbeCandidates,
  }..removeWhere((int value) => value < 1280);
  final List<int> sorted = values.toList(growable: false)
    ..sort((int a, int b) => b.compareTo(a));
  return sorted;
}

/// Where the MTU probe starts for [policy], or null when there is nothing to
/// start from.
///
/// Null is not "start at zero". Index 0 is the *largest* candidate, so seeding
/// it for a policy that never named an MTU would pin 1400 on every ordinary
/// connect and silently override the platform default ([defaultTunMtu]) — and
/// it would do so past the guard in [_effectiveThrottlePolicyForProfileInternal],
/// which can only tell "nothing configured" from "probed" by the *absence* of a
/// cursor. Leaving it unseeded is what keeps the two paths (pool and manual
/// connect) agreeing about what an unconfigured MTU means.
int? _resolveInitialMtuProbeCursorInternal(TrafficThrottlePolicy policy) {
  final int? configured = policy.tunMtu;
  if (configured == null) {
    return null;
  }
  final List<int> candidates = _resolveMtuCandidatesInternal(policy);
  if (candidates.isEmpty) {
    return 0;
  }
  return max(0, candidates.indexOf(configured));
}

bool _shouldForceUdpFragmentForProfileInternal(VpnProfile profile) {
  if (!profile.tls.enabled) {
    return false;
  }
  switch (profile.protocol) {
    case VpnProtocol.vless:
    case VpnProtocol.vmess:
    case VpnProtocol.trojan:
      return true;
    case VpnProtocol.shadowsocks:
    case VpnProtocol.hysteria2:
    case VpnProtocol.tuic:
    case VpnProtocol.wireguard:
    case VpnProtocol.ssh:
      return false;
  }
}

void _markEndpointSuccessInternal(SignboxVpn client, int index) {
  if (index < 0 || index >= client._endpointHealthStates.length) {
    return;
  }
  final _EndpointHealthState state = client._endpointHealthStates[index];
  client._endpointHealthStates[index] = state.copyWith(
    score: min(
      100,
      state.score + client._endpointPoolOptions.healthCheck.successBonus,
    ),
    consecutiveFailures: 0,
    lastSuccessAt: DateTime.now().toUtc(),
  );
}

void _markEndpointFailureInternal(SignboxVpn client, int index) {
  if (index < 0 || index >= client._endpointHealthStates.length) {
    return;
  }
  final _EndpointHealthState state = client._endpointHealthStates[index];
  client._endpointHealthStates[index] = state.copyWith(
    score: max(
      0,
      state.score - client._endpointPoolOptions.healthCheck.failurePenalty,
    ),
    consecutiveFailures: state.consecutiveFailures + 1,
    lastFailureAt: DateTime.now().toUtc(),
  );
}

void _markEndpointProgressInternal(
  SignboxVpn client,
  int index,
  DateTime timestamp,
) {
  if (index < 0 || index >= client._endpointHealthStates.length) {
    return;
  }
  final _EndpointHealthState state = client._endpointHealthStates[index];
  client._endpointHealthStates[index] = state.copyWith(
    lastProgressAt: timestamp,
  );
}

int _bestPingResultIndexInternal(List<VpnPingResult> results) {
  final int tcpPreferred = _bestPingResultIndexByMethodInternal(
    results,
    VpnPingResult.methodTcpConnect,
  );
  if (tcpPreferred >= 0) {
    return tcpPreferred;
  }
  return _bestPingResultIndexByMethodInternal(results, null);
}

int _bestPingResultIndexByMethodInternal(
  List<VpnPingResult> results,
  String? method,
) {
  int bestIndex = -1;
  int bestLatencyMs = 1 << 30;

  for (int index = 0; index < results.length; index++) {
    final VpnPingResult result = results[index];
    if (method != null && result.checkMethod != method) {
      continue;
    }
    final int? latency = result.latencyMs;
    if (!result.success || latency == null) {
      continue;
    }
    if (latency < bestLatencyMs) {
      bestLatencyMs = latency;
      bestIndex = index;
    }
  }
  return bestIndex;
}

void _resetTrafficTrackingInternal(SignboxVpn client) {
  client._lastTotalBytes = null;
  client._lastTrafficProgressAt = DateTime.now().toUtc();
  client._hasSeenTraffic = false;
  client._consecutiveSilentPacketLossSignals = 0;
}
