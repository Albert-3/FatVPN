import 'dart:async';

/// Default ceiling on simultaneous latency probes.
///
/// Everything this file is used for opens a TCP connection per item, and the
/// lists are cartesian: every node of every country. Firing forty handshakes at
/// once on a mobile radio makes the measurements compete with each other — the
/// numbers come back worse than the servers are — and looks enough like a port
/// scan to upset some carrier NATs.
const _defaultConcurrency = 6;

/// Runs [task] over [items] with at most [concurrency] of them in flight,
/// returning the results in the original order.
///
/// A drop-in replacement for `Future.wait(items.map(task))` where the work is
/// I/O the network can't absorb all at once.
Future<List<R>> mapConcurrently<T, R>(
  Iterable<T> items,
  Future<R> Function(T item) task, {
  int concurrency = _defaultConcurrency,
}) async {
  final list = items.toList(growable: false);
  final results = List<R?>.filled(list.length, null);
  var next = 0;

  Future<void> worker() async {
    while (true) {
      final index = next++;
      if (index >= list.length) return;
      results[index] = await task(list[index]);
    }
  }

  final workers = <Future<void>>[
    for (var i = 0; i < concurrency && i < list.length; i++) worker(),
  ];
  await Future.wait(workers);
  return results.cast<R>();
}
