// The app-local in-flight mark. Subordinate to `SessionEntry.deleting` and
// rendering-only: it exists because a remote Recents delete goes over the
// control plane, whose session lists are polled peeks that never carry the
// bridge's flag.
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/providers/session_delete_pending.dart';
import 'package:antgrid/services/session_delete_policy.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

SessionEntry _session({bool deleting = false}) => SessionEntry(
  id: 's1',
  name: 'Session 1',
  createdAt: 0,
  lastUsedAt: 0,
  archived: false,
  running: false,
  deleting: deleting,
);

/// Mounts [sessionDeleteInFlight] so it can be read the way a row reads it.
Future<bool Function()> _mountProbe(
  WidgetTester tester,
  ProviderContainer container, {
  required String entryId,
  required SessionEntry Function() session,
}) async {
  var last = false;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: Consumer(
        builder: (context, ref, _) {
          last = sessionDeleteInFlight(ref, entryId, session());
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return () => last;
}

void main() {
  testWidgets('the wire flag and the local mark each suffice', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    var entry = _session();
    final read = await _mountProbe(
      tester,
      container,
      entryId: 'p1',
      session: () => entry,
    );
    expect(read(), isFalse);

    container
        .read(sessionDeleteRequestsProvider.notifier)
        .arm(sessionDeleteKey('p1', 's1'));
    await tester.pump();
    expect(read(), isTrue, reason: 'the local mark alone');

    entry = _session(deleting: true);
    await tester.pump();
    expect(read(), isTrue, reason: 'both');

    container
        .read(sessionDeleteRequestsProvider.notifier)
        .disarm(sessionDeleteKey('p1', 's1'));
    await tester.pump();
    expect(read(), isTrue, reason: 'the wire flag alone');
  });

  test(
    'keys are scoped by entry, so the same id under two projects differs',
    () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container
          .read(sessionDeleteRequestsProvider.notifier)
          .arm(sessionDeleteKey('p1', 's1'));

      final armed = container.read(sessionDeleteRequestsProvider);
      expect(armed, contains(sessionDeleteKey('p1', 's1')));
      expect(armed, isNot(contains(sessionDeleteKey('p2', 's1'))));
    },
  );

  // A row whose surface unmounts mid-delete has no disarm path left, and a key
  // that sticks makes the session permanently undeletable.
  test('an armed key expires on its own', () {
    fakeAsync((async) {
      final container = ProviderContainer();
      final key = sessionDeleteKey('p1', 's1');
      container.read(sessionDeleteRequestsProvider.notifier).arm(key);
      expect(container.read(sessionDeleteRequestsProvider), contains(key));

      async.elapse(kSessionDeleteAckTimeout * 2 + const Duration(seconds: 1));
      expect(container.read(sessionDeleteRequestsProvider), isEmpty);
      container.dispose();
    });
  });

  test('disposing the container leaves no timer behind', () {
    fakeAsync((async) {
      final container = ProviderContainer();
      container
          .read(sessionDeleteRequestsProvider.notifier)
          .arm(sessionDeleteKey('p1', 's1'));
      container.dispose();
      // FakeAsync asserts on leftover timers when the zone is torn down.
      async.flushTimers();
    });
  });
}
