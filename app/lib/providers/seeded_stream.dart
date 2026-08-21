import 'dart:async';

/// Emits [current]'s snapshot followed by every event from [source], with NO
/// gap between the seed and the subscription.
///
/// [source] is a broadcast stream with no replay (the per-project service
/// `stateStream`s). The naive `yield current(); yield* source` seed reads the
/// snapshot and only THEN subscribes, so any event broadcast in the microtask
/// gap between the two is lost — e.g. the `agent:status` / `terminal:started`
/// that creates the agent tab for a just-started session, which stranded the
/// terminal on "waiting for agent" until a project switch forced a re-subscribe.
/// Subscribing BEFORE reading the snapshot closes the gap; a duplicate same-value
/// emit (if an event lands between listen and seed) is harmless to consumers,
/// which compare state by value.
Stream<T> seededStream<T>(T Function() current, Stream<T> source) =>
    seededStreamAll(() => [current()], source);

/// [seededStream] for a seed of zero or more values — a replay cache rather
/// than a single current-state snapshot. Seeds in iteration order.
///
/// The returned stream is SINGLE-SUBSCRIPTION even when [source] is broadcast,
/// and deliberately so: the seed is produced per listener, which a broadcast
/// controller cannot do (its `onListen` fires only for the first). Call the
/// producing getter once per consumer rather than sharing one returned stream.
Stream<T> seededStreamAll<T>(Iterable<T> Function() seed, Stream<T> source) {
  late final StreamController<T> controller;
  StreamSubscription<T>? sub;
  controller = StreamController<T>(
    onListen: () {
      // Subscribe first, THEN seed, so an event that lands the instant we
      // subscribe is delivered rather than dropped into the seed gap.
      sub = source.listen(
        controller.add,
        onError: controller.addError,
        onDone: controller.close,
      );
      for (final value in seed()) {
        controller.add(value);
      }
    },
    onCancel: () async {
      await sub?.cancel();
      sub = null;
    },
  );
  return controller.stream;
}
