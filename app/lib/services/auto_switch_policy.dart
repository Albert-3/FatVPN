import '../models/server_country.dart';

/// Decides whether a *live* session should be moved to a different node.
///
/// The node is picked once, at connect time, from whatever latency the app
/// measured then. Nothing about that measurement stays true for an hours-long
/// session: the chosen server fills up, the user's network changes, a closer
/// node comes back online. This policy is what lets the session follow those
/// changes instead of being stuck with a decision made at minute zero.
///
/// It reads two signals, and deliberately does not blend them into one score:
///
/// * **Latency** is primary, because it is measured from this device and is
///   what the user actually feels.
/// * **Client count** is secondary, because it catches what latency cannot. A
///   saturated server still completes a TCP handshake instantly — the crowd
///   costs throughput, not round-trip — so a node can be busy to the point of
///   being unusable while every ping stays flat. It is only a proxy, though:
///   the panel counts *connections*, not the traffic behind them, so it never
///   overrules a latency verdict. It vetoes moves onto crowded nodes, and it
///   can justify a move the latency thresholds alone wouldn't.
///
/// Crowding is always judged as a **ratio between two nodes**, never against a
/// fixed "this many clients is a lot". Nobody knows what a busy node looks like
/// on this panel today, and whatever the answer is it changes as the service
/// grows — so a hard-coded population would be a number that silently stops
/// meaning anything. "Several times emptier than where I am now" survives the
/// panel going from ten users to ten thousand without a code change.
///
/// Either way the job is restraint. A switch is not free — the tunnel goes down
/// and every live TCP connection dies with it, which for the user is a stall in
/// whatever they were doing. So a few milliseconds is never worth acting on: a
/// candidate must be *much* faster ([minGainMs] **and** [minGainRatio], so
/// neither a big absolute gap on an already-slow link nor a large ratio on a
/// tiny one is enough alone), and any verdict must hold for [strikesRequired]
/// consecutive rounds. One noisy measurement — a Wi-Fi hiccup, a momentary
/// spike — decays back to zero instead of costing the user their connections.
///
/// The exception is a node that has stopped working: when the current server no
/// longer answers at all, or the tunnel through it carries no traffic, staying
/// is strictly worse than any reachable alternative, so the thresholds and the
/// strike count are skipped entirely.
class AutoSwitchPolicy {
  AutoSwitchPolicy({
    this.minGainMs = 60,
    this.minGainRatio = 0.35,
    this.strikesRequired = 2,
    this.crowdedRatio = 2.0,
    this.crowdTolerance = 1.5,
    this.minUsersDelta = 5,
    this.slowerToleranceMs = 30,
  });

  /// Absolute latency a candidate must save to be worth a reconnect.
  final int minGainMs;

  /// Share of the current latency a candidate must save, on top of
  /// [minGainMs] — 0.35 means "at least 35% faster".
  final double minGainRatio;

  /// Consecutive evaluation rounds a verdict must hold before acting.
  final int strikesRequired;

  /// How many times more crowded than the candidate the current node must be
  /// for crowding alone to justify a move.
  final double crowdedRatio;

  /// How much more crowded than the current node a candidate may be before it
  /// is refused as a destination. A faster server that is packed will not stay
  /// fast once the user lands on it.
  final double crowdTolerance;

  /// Smallest client difference worth acting on at all, in either direction.
  ///
  /// Purely a noise guard, and deliberately the *only* absolute number in the
  /// crowding rules: everything else is a ratio, so nothing here has to be
  /// re-tuned when the panel grows. Five clients is not worth a reconnect
  /// whether the busiest node carries ten or ten thousand, which is exactly
  /// what makes it safe to hard-code — unlike a "this counts as crowded"
  /// threshold, which would be a guess about a deployment size we don't know
  /// and which changes over time.
  final int minUsersDelta;

  /// Latency a move made purely to escape a crowd may cost. Trading round-trip
  /// for a quieter server is a bad deal, so it has to be near-free.
  final int slowerToleranceMs;

  int _strikes = 0;

  /// How many consecutive rounds a switch has looked warranted. Exposed for
  /// logging and tests.
  int get strikes => _strikes;

  /// Forgets accumulated strikes — called whenever the session's node changes,
  /// so evidence gathered about one server never carries over to the next.
  void reset() => _strikes = 0;

  /// The node worth moving to, or null to stay put.
  ///
  /// [pingsByNodeId] holds only nodes that answered; an unreachable node is
  /// simply absent. [usersByNodeId] likewise holds only nodes the panel reports
  /// a client count for — an absent entry means unknown, and every crowding
  /// rule below abstains rather than guesses when either side of a comparison
  /// is missing. [tunnelIsDead] reports that the tunnel is established but a
  /// probe through it reached nothing (see
  /// `VpnController._verifyTunnelCarriesTraffic`).
  ServerNode? evaluate({
    required ServerNode current,
    required List<ServerNode> pool,
    required Map<String, int> pingsByNodeId,
    Map<String, int> usersByNodeId = const {},
    bool tunnelIsDead = false,
  }) {
    final reachable = pool
        .where((n) => n.id != current.id && pingsByNodeId.containsKey(n.id))
        .toList();

    final currentPing = pingsByNodeId[current.id];
    final currentUsers = usersByNodeId[current.id];

    if (tunnelIsDead || currentPing == null) {
      _strikes = 0;
      // The current node is useless, so anything that answers beats it. Prefer
      // an uncrowded destination, but never stay offline for the sake of that
      // preference — a busy server still carries traffic, a dead one doesn't.
      final roomy = reachable.where(
        (n) => !_tooCrowded(n, currentUsers, usersByNodeId),
      );
      return _fastest(roomy, pingsByNodeId) ??
          _fastest(reachable, pingsByNodeId);
    }

    // Nowhere acceptable to go. Note this also covers "the user has no internet
    // at all", where every ping fails: the right move then is to stay, because
    // the problem isn't the server and switching would fix nothing.
    final candidates = reachable
        .where((n) => !_tooCrowded(n, currentUsers, usersByNodeId))
        .toList();
    if (candidates.isEmpty) {
      _strikes = 0;
      return null;
    }

    final target = _pickTarget(
      candidates: candidates,
      currentPing: currentPing,
      currentUsers: currentUsers,
      pingsByNodeId: pingsByNodeId,
      usersByNodeId: usersByNodeId,
    );
    if (target == null) {
      _strikes = 0;
      return null;
    }

    _strikes++;
    if (_strikes < strikesRequired) return null;
    _strikes = 0;
    return target;
  }

  /// Applies the two signals in priority order: a decisively faster node wins
  /// outright, and only when no such node exists does crowding get to move the
  /// session on its own.
  ServerNode? _pickTarget({
    required List<ServerNode> candidates,
    required int currentPing,
    required int? currentUsers,
    required Map<String, int> pingsByNodeId,
    required Map<String, int> usersByNodeId,
  }) {
    final fastest = _fastest(candidates, pingsByNodeId);
    if (fastest != null) {
      final gain = currentPing - pingsByNodeId[fastest.id]!;
      if (gain >= minGainMs && gain >= currentPing * minGainRatio) {
        return fastest;
      }
    }

    // Latency says stay. Crowding may still say otherwise — but only towards a
    // node that costs essentially nothing in round-trip, because the congestion
    // it escapes is a proxy we can't measure directly while the latency we'd be
    // giving up is not.
    if (currentUsers == null) return null;
    final relief = _leastCrowded(
      candidates.where((n) =>
          pingsByNodeId[n.id]! <= currentPing + slowerToleranceMs &&
          usersByNodeId.containsKey(n.id)),
      usersByNodeId,
    );
    if (relief == null) return null;
    // Judged only against the node we'd be leaving — "several times emptier
    // than where I am" holds its meaning at any deployment size, where "busy"
    // as an absolute number does not.
    final theirs = usersByNodeId[relief.id]!;
    final relieves = currentUsers >= theirs * crowdedRatio &&
        currentUsers - theirs >= minUsersDelta;
    return relieves ? relief : null;
  }

  /// True when moving to [node] would trade a crowd for a bigger one. Abstains
  /// whenever either count is unknown — refusing a destination over a number we
  /// don't have would push sessions onto whichever nodes the panel happens to
  /// report on.
  bool _tooCrowded(
    ServerNode node,
    int? currentUsers,
    Map<String, int> usersByNodeId,
  ) {
    final theirs = usersByNodeId[node.id];
    if (theirs == null || currentUsers == null) return false;
    return theirs >= currentUsers + minUsersDelta &&
        theirs > currentUsers * crowdTolerance;
  }

  ServerNode? _fastest(Iterable<ServerNode> nodes, Map<String, int> pings) {
    ServerNode? best;
    int? bestPing;
    for (final node in nodes) {
      final ms = pings[node.id]!;
      if (bestPing == null || ms < bestPing) {
        best = node;
        bestPing = ms;
      }
    }
    return best;
  }

  ServerNode? _leastCrowded(Iterable<ServerNode> nodes, Map<String, int> users) {
    ServerNode? best;
    int? bestUsers;
    for (final node in nodes) {
      final count = users[node.id]!;
      if (bestUsers == null || count < bestUsers) {
        best = node;
        bestUsers = count;
      }
    }
    return best;
  }
}
