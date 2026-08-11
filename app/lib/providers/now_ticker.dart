import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Emits the wall clock now, then again on each following minute boundary, so
/// relative-time labels ("2 mins ago") refresh while their view stays mounted
/// instead of freezing at the value computed when the widget first built.
///
/// Minute resolution is deliberate: `relativeTime` never renders finer than
/// minutes, so a per-second tick would rebuild watchers 60× for no visible
/// change. autoDispose tears the periodic timer down as soon as the last
/// watcher goes away (e.g. the New Session canvas closes).
final nowMinuteProvider = StreamProvider.autoDispose<DateTime>((ref) async* {
  yield DateTime.now();
  yield* Stream<DateTime>.periodic(
    const Duration(minutes: 1),
    (_) => DateTime.now(),
  );
});

/// Re-poll heartbeat for background fetches whose watcher stays mounted for a
/// whole session — the account-device poll behind the sidebar setup checklist
/// and, after it retires, the remote-access nudge.
///
/// Not a clock: the value is a bare counter because nothing renders it. That is
/// the whole reason it is separate from [nowMinuteProvider] — a poll interval
/// should be tuned against network cost, and a label's refresh rate against
/// what the user can see, and the two stop agreeing the moment a watcher is no
/// longer a short-lived view.
final slowPollTickProvider = StreamProvider.autoDispose<int>((ref) async* {
  yield 0;
  yield* Stream<int>.periodic(const Duration(minutes: 5), (i) => i + 1);
});
