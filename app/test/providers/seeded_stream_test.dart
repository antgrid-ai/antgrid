import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/providers/seeded_stream.dart';

void main() {
  group('seededStream', () {
    test('emits the current snapshot first, then follows the source', () async {
      final source = StreamController<int>.broadcast();
      var current = 10;
      final received = <int>[];
      final sub = seededStream(
        () => current,
        source.stream,
      ).listen(received.add);
      await pumpEventQueue();
      source.add(11);
      source.add(12);
      await pumpEventQueue();

      expect(received, [10, 11, 12]);

      await sub.cancel();
      await source.close();
    });

    test(
      'delivers an event that lands in the gap right after subscription',
      () async {
        // Reproduces the "waiting for agent" bug: the service updates its
        // currentState and broadcasts a new state in the same turn the provider
        // first subscribes. seededStream subscribes BEFORE reading the snapshot,
        // so — unlike the naive `yield currentState; yield* stream` seed — the
        // event survives.
        final source = StreamController<int>.broadcast();
        var current = 0;
        final received = <int>[];
        final sub = seededStream(
          () => current,
          source.stream,
        ).listen(received.add);
        current = 1;
        source.add(1);
        await pumpEventQueue();

        expect(received, contains(1));

        await sub.cancel();
        await source.close();
      },
    );

    test('closes when the source closes', () async {
      final source = StreamController<int>.broadcast();
      var done = false;
      final sub = seededStream(
        () => 0,
        source.stream,
      ).listen((_) {}, onDone: () => done = true);
      await source.close();
      await pumpEventQueue();

      expect(done, isTrue);

      await sub.cancel();
    });

    test('subscribes to the source synchronously on listen (no seed gap)', () {
      // This is the property that fixes the bug. seededStream subscribes to the
      // broadcast source inside onListen — synchronously, before any microtask —
      // so an event broadcast the instant the provider subscribes is delivered.
      // The naive `yield currentState; yield* stream` seed only subscribes once
      // the async* generator advances past the seed (asynchronously), leaving a
      // gap where broadcast events are dropped.
      final source = StreamController<int>.broadcast();
      final sub = seededStream(() => 0, source.stream).listen((_) {});

      expect(source.hasListener, isTrue);

      sub.cancel();
      source.close();
    });

    test('cancels the source subscription when the consumer cancels', () async {
      final source = StreamController<int>.broadcast();
      final sub = seededStream(() => 0, source.stream).listen((_) {});
      await pumpEventQueue();
      expect(source.hasListener, isTrue);

      await sub.cancel();
      await pumpEventQueue();
      expect(source.hasListener, isFalse);

      await source.close();
    });
  });
}
