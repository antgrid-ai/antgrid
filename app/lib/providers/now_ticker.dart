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
