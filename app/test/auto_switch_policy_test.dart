import 'package:flutter_test/flutter_test.dart';
import 'package:fatvpn_app/models/server_country.dart';
import 'package:fatvpn_app/services/auto_switch_policy.dart';

ServerNode _node(String id) => ServerNode(
      id: id,
      name: id,
      address: '$id.example.com',
      port: 443,
      usersOnline: null,
    );

void main() {
  final current = _node('current');
  final rival = _node('rival');
  final other = _node('other');
  final pool = [current, rival, other];

  AutoSwitchPolicy policy() => AutoSwitchPolicy();

  ServerNode? evaluate(
    AutoSwitchPolicy p,
    Map<String, int> pings, {
    Map<String, int> users = const {},
    bool tunnelIsDead = false,
  }) =>
      p.evaluate(
        current: current,
        pool: pool,
        pingsByNodeId: pings,
        usersByNodeId: users,
        tunnelIsDead: tunnelIsDead,
      );

  group('latency', () {
    test('stays put when nothing is meaningfully faster', () {
      final p = policy();
      final pings = {'current': 100, 'rival': 95, 'other': 120};
      expect(evaluate(p, pings), isNull);
      expect(evaluate(p, pings), isNull);
      expect(p.strikes, 0);
    });

    test('stays put when the gain is large absolutely but not relatively', () {
      // 80ms saved, yet only 20% of a 400ms link — not worth dropping every
      // live connection for.
      final p = policy();
      final pings = {'current': 400, 'rival': 320};
      expect(evaluate(p, pings), isNull);
      expect(evaluate(p, pings), isNull);
    });

    test('stays put when the gain is large relatively but tiny absolutely', () {
      // 50% faster, but that is 30ms nobody will notice.
      final p = policy();
      final pings = {'current': 60, 'rival': 30};
      expect(evaluate(p, pings), isNull);
      expect(evaluate(p, pings), isNull);
    });

    test('switches only after the gain holds for two consecutive rounds', () {
      final p = policy();
      final pings = {'current': 300, 'rival': 90, 'other': 280};
      expect(evaluate(p, pings), isNull, reason: 'first round is only evidence');
      expect(p.strikes, 1);
      expect(evaluate(p, pings), same(rival));
      expect(p.strikes, 0, reason: 'strikes reset once acted on');
    });

    test('a single good round decays instead of accumulating', () {
      final p = policy();
      expect(evaluate(p, {'current': 300, 'rival': 90}), isNull);
      expect(evaluate(p, {'current': 300, 'rival': 290}), isNull);
      expect(p.strikes, 0);
      // The spike is forgotten, so this good round counts from scratch.
      expect(evaluate(p, {'current': 300, 'rival': 90}), isNull);
      expect(evaluate(p, {'current': 300, 'rival': 90}), same(rival));
    });

    test('picks the fastest alternative, not merely a qualifying one', () {
      final p = policy();
      final pings = {'current': 300, 'rival': 120, 'other': 60};
      expect(evaluate(p, pings), isNull);
      expect(evaluate(p, pings), same(other));
    });
  });

  group('failure', () {
    test('switches immediately when the tunnel carries no traffic', () {
      final p = policy();
      // The rival is slower and still wins: a working slow server beats a fast
      // one that passes nothing.
      expect(
        evaluate(p, {'current': 50, 'rival': 200}, tunnelIsDead: true),
        same(rival),
      );
    });

    test('switches immediately when the current node stopped answering', () {
      final p = policy();
      expect(evaluate(p, {'rival': 200, 'other': 300}), same(rival));
    });

    test('stays put when nothing is reachable at all', () {
      // Every ping failed — that is the user's own connectivity, and no server
      // change fixes it.
      final p = policy();
      expect(evaluate(p, const {}), isNull);
      expect(evaluate(p, const {}, tunnelIsDead: true), isNull);
    });

    test('never proposes the node the session is already on', () {
      final p = policy();
      expect(evaluate(p, {'current': 500}, tunnelIsDead: true), isNull);
    });

    test('takes a crowded node rather than staying on a dead tunnel', () {
      final p = policy();
      expect(
        evaluate(
          p,
          {'current': 50, 'rival': 60},
          users: {'current': 5, 'rival': 400},
          tunnelIsDead: true,
        ),
        same(rival),
        reason: 'a busy server still carries traffic; a dead one does not',
      );
    });

    test('prefers the uncrowded node when the tunnel is dead', () {
      final p = policy();
      expect(
        evaluate(
          p,
          {'current': 50, 'rival': 60, 'other': 200},
          users: {'current': 5, 'rival': 400, 'other': 3},
          tunnelIsDead: true,
        ),
        same(other),
      );
    });
  });

  group('load', () {
    test('refuses a faster node that is much more crowded', () {
      final p = policy();
      final pings = {'current': 300, 'rival': 60};
      final users = {'current': 10, 'rival': 400};
      expect(evaluate(p, pings, users: users), isNull);
      expect(evaluate(p, pings, users: users), isNull);
      expect(p.strikes, 0);
    });

    test('still takes a faster node whose crowd is comparable', () {
      final p = policy();
      final pings = {'current': 300, 'rival': 60};
      final users = {'current': 100, 'rival': 120};
      expect(evaluate(p, pings, users: users), isNull);
      expect(evaluate(p, pings, users: users), same(rival));
    });

    test('does not veto on small counts where the ratio is noise', () {
      // 3 vs 1 is twice as crowded and means nothing.
      final p = policy();
      final pings = {'current': 300, 'rival': 60};
      final users = {'current': 1, 'rival': 3};
      expect(evaluate(p, pings, users: users), isNull);
      expect(evaluate(p, pings, users: users), same(rival));
    });

    test('falls back to the next-fastest node when the fastest is packed', () {
      final p = policy();
      final pings = {'current': 300, 'rival': 60, 'other': 100};
      final users = {'current': 10, 'rival': 400, 'other': 12};
      expect(evaluate(p, pings, users: users), isNull);
      expect(evaluate(p, pings, users: users), same(other));
    });

    test('moves off a crowded node even when latency says stay', () {
      // The case latency alone cannot see: handshakes stay fast on a saturated
      // server, so only the client count reveals it.
      final p = policy();
      final pings = {'current': 100, 'rival': 110};
      final users = {'current': 200, 'rival': 20};
      expect(evaluate(p, pings, users: users), isNull);
      expect(evaluate(p, pings, users: users), same(rival));
    });

    test('will not pay real latency to escape a crowd', () {
      final p = policy();
      final pings = {'current': 100, 'rival': 400};
      final users = {'current': 200, 'rival': 2};
      expect(evaluate(p, pings, users: users), isNull);
      expect(evaluate(p, pings, users: users), isNull);
    });

    test('picks the emptiest node when relieving a crowd', () {
      final p = policy();
      final pings = {'current': 100, 'rival': 105, 'other': 110};
      final users = {'current': 200, 'rival': 40, 'other': 5};
      expect(evaluate(p, pings, users: users), isNull);
      expect(evaluate(p, pings, users: users), same(other));
    });

    test('ignores a big ratio over a handful of clients', () {
      // Three times as crowded, and the whole difference is four people.
      final p = policy();
      final pings = {'current': 100, 'rival': 105};
      final users = {'current': 6, 'rival': 2};
      expect(evaluate(p, pings, users: users), isNull);
      expect(evaluate(p, pings, users: users), isNull);
    });

    test('the same ratios decide the same way at any panel size', () {
      // Nothing in the crowding rules assumes a deployment size, so a panel
      // with thousands of clients per node behaves like one with dozens.
      for (final scale in [1, 10, 100]) {
        final p = policy();
        final pings = {'current': 100, 'rival': 110};
        final users = {'current': 200 * scale, 'rival': 20 * scale};
        expect(evaluate(p, pings, users: users), isNull);
        expect(evaluate(p, pings, users: users), same(rival),
            reason: 'crowded node at scale $scale');
      }
      for (final scale in [1, 10, 100]) {
        final p = policy();
        final pings = {'current': 100, 'rival': 110};
        final users = {'current': 110 * scale, 'rival': 100 * scale};
        expect(evaluate(p, pings, users: users), isNull);
        expect(evaluate(p, pings, users: users), isNull,
            reason: 'comparable load at scale $scale');
      }
    });

    test('an unknown count never reads as an empty server', () {
      // The rival is a Hysteria2 host the panel reports nothing for. It must
      // not win the crowding argument on a number nobody published.
      final p = policy();
      final pings = {'current': 100, 'rival': 105};
      final users = {'current': 200};
      expect(evaluate(p, pings, users: users), isNull);
      expect(evaluate(p, pings, users: users), isNull);
    });

    test('an unknown count does not block a decisively faster node', () {
      final p = policy();
      final pings = {'current': 300, 'rival': 60};
      final users = {'current': 10};
      expect(evaluate(p, pings, users: users), isNull);
      expect(evaluate(p, pings, users: users), same(rival));
    });

    test('with no load data at all, behaves exactly as latency-only', () {
      final p = policy();
      final pings = {'current': 300, 'rival': 90};
      expect(evaluate(p, pings, users: const {}), isNull);
      expect(evaluate(p, pings, users: const {}), same(rival));
    });
  });

  test('reset() drops evidence gathered about the previous node', () {
    final p = policy();
    final pings = {'current': 300, 'rival': 90};
    expect(evaluate(p, pings), isNull);
    p.reset();
    expect(evaluate(p, pings), isNull, reason: 'strike count started over');
    expect(evaluate(p, pings), same(rival));
  });
}
