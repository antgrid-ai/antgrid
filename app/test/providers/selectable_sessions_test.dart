// A deleting session stays visible in the drawer but must never be the
// selection target: the advance has to fire when the bridge's flag ARRIVES,
// not 3-15s later when the row finally leaves the list.
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

SessionEntry _entry(String id, {bool deleting = false, int lastUsedAt = 0}) =>
    SessionEntry(
      id: id,
      name: id,
      createdAt: 0,
      lastUsedAt: lastUsedAt,
      archived: false,
      running: false,
      deleting: deleting,
    );

/// Mounts [reconcileActiveSession] against [selectableSessionsProvider], the
/// way WorkspaceShell wires it.
Future<void> _pumpReconciler(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: Consumer(
        builder: (context, ref, _) {
          // Listened, not watched — mirroring WorkspaceShell, and because a
          // provider write during build is illegal.
          ref.listen<List<SessionEntry>>(
            selectableSessionsProvider,
            (_, next) => reconcileActiveSession(ref, next),
          );
          return const SizedBox.shrink();
        },
      ),
    ),
  );
}

void main() {
  test('deleting entries are dropped from selectable but kept in active', () {
    final sessions = [_entry('a'), _entry('b', deleting: true)];
    final container = ProviderContainer(
      overrides: [activeSessionsProvider.overrideWithValue(sessions)],
    );
    addTearDown(container.dispose);

    expect(container.read(activeSessionsProvider).map((s) => s.id), ['a', 'b']);
    expect(container.read(selectableSessionsProvider).map((s) => s.id), ['a']);
  });

  testWidgets('the selection steps off a session the moment it flags', (
    tester,
  ) async {
    var sessions = [_entry('a'), _entry('b')];
    final container = ProviderContainer(
      overrides: [activeSessionsProvider.overrideWith((_) => sessions)],
    );
    addTearDown(container.dispose);
    container.read(activeSessionIdProvider.notifier).set('a');

    await _pumpReconciler(tester, container);
    expect(container.read(activeSessionIdProvider), 'a');

    // List membership is unchanged — only the flag moved.
    sessions = [_entry('a', deleting: true), _entry('b')];
    container.invalidate(activeSessionsProvider);
    await tester.pump();

    expect(container.read(activeSessionIdProvider), 'b');
  });

  testWidgets('the last session flagging clears the selection', (tester) async {
    var sessions = [_entry('a')];
    final container = ProviderContainer(
      overrides: [activeSessionsProvider.overrideWith((_) => sessions)],
    );
    addTearDown(container.dispose);
    container.read(activeSessionIdProvider.notifier).set('a');

    await _pumpReconciler(tester, container);
    sessions = [_entry('a', deleting: true)];
    container.invalidate(activeSessionsProvider);
    await tester.pump();

    expect(container.read(activeSessionIdProvider), isNull);
  });

  // The bridge only sets the flag past its preflight, so a refused delete never
  // reaches this provider at all — which is what stops a ladder the user is
  // still answering from navigating out from under them.
  testWidgets('a refused delete leaves the selection alone', (tester) async {
    final sessions = [_entry('a'), _entry('b')];
    final container = ProviderContainer(
      overrides: [activeSessionsProvider.overrideWithValue(sessions)],
    );
    addTearDown(container.dispose);
    container.read(activeSessionIdProvider.notifier).set('a');

    await _pumpReconciler(tester, container);
    await tester.pump();

    expect(container.read(activeSessionIdProvider), 'a');
  });

  // A project switch delivers its list in stages — the persisted cache the
  // instant the SessionsService constructs, the wire seconds later on a relay.
  // The cross-project tap that started the switch queued the session it wants;
  // `first` from the early stage is a different session rendered in full and
  // then visibly switched away from.
  group('a queued cross-project pick', () {
    testWidgets('is selected from the first list that carries it', (
      tester,
    ) async {
      var sessions = <SessionEntry>[];
      final container = ProviderContainer(
        overrides: [activeSessionsProvider.overrideWith((_) => sessions)],
      );
      addTearDown(container.dispose);
      container.read(pendingActiveSessionIdProvider.notifier).set('b');

      await _pumpReconciler(tester, container);
      // `a` outranks `b` on activity, which is what `first` would answer.
      sessions = [_entry('a', lastUsedAt: 2), _entry('b', lastUsedAt: 1)];
      container.invalidate(activeSessionsProvider);
      await tester.pump();

      expect(container.read(activeSessionIdProvider), 'b');
      // Still the bootstrap's to consume — it owns the start + focus that
      // follow, and reports a refused start for a session the user named.
      expect(container.read(pendingActiveSessionIdProvider), 'b');
    });

    testWidgets('holds the selection empty while no list carries it', (
      tester,
    ) async {
      var sessions = <SessionEntry>[];
      final container = ProviderContainer(
        overrides: [activeSessionsProvider.overrideWith((_) => sessions)],
      );
      addTearDown(container.dispose);
      container.read(pendingActiveSessionIdProvider.notifier).set('c');

      await _pumpReconciler(tester, container);
      sessions = [_entry('a'), _entry('b')];
      container.invalidate(activeSessionsProvider);
      await tester.pump();

      expect(container.read(activeSessionIdProvider), isNull);
    });

    testWidgets('outranks a selection the switch left behind', (tester) async {
      var sessions = <SessionEntry>[];
      final container = ProviderContainer(
        overrides: [activeSessionsProvider.overrideWith((_) => sessions)],
      );
      addTearDown(container.dispose);
      // The previous project's session — the listener that would have cleared
      // it on the empty list was unmounted through the switch.
      container.read(activeSessionIdProvider.notifier).set('old');
      container.read(pendingActiveSessionIdProvider.notifier).set('b');

      await _pumpReconciler(tester, container);
      sessions = [_entry('a', lastUsedAt: 2), _entry('b', lastUsedAt: 1)];
      container.invalidate(activeSessionsProvider);
      await tester.pump();

      expect(container.read(activeSessionIdProvider), 'b');
    });

    testWidgets('once consumed, the default pick is back', (tester) async {
      var sessions = <SessionEntry>[];
      final container = ProviderContainer(
        overrides: [activeSessionsProvider.overrideWith((_) => sessions)],
      );
      addTearDown(container.dispose);
      container.read(pendingActiveSessionIdProvider.notifier).set('c');

      await _pumpReconciler(tester, container);
      container.read(pendingActiveSessionIdProvider.notifier).set(null);
      sessions = [_entry('a', lastUsedAt: 2), _entry('b', lastUsedAt: 1)];
      container.invalidate(activeSessionsProvider);
      await tester.pump();

      expect(container.read(activeSessionIdProvider), 'a');
    });
  });
}
