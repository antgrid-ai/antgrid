// `reconcileActiveSession` only fires when the selectable LIST changes, so it
// cannot see an id written straight into the provider — a Back press replaying
// nav history, a deep link, the handler screen's in-session escalation. The
// guard therefore lives on the WRITE, and this pins it there.
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/services/sessions_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

SessionEntry _entry(String id, {bool deleting = false}) => SessionEntry(
  id: id,
  name: id,
  createdAt: 0,
  lastUsedAt: 0,
  archived: false,
  running: false,
  deleting: deleting,
);

ProviderContainer _container(List<SessionEntry> sessions) {
  final container = ProviderContainer(
    overrides: [
      freshSessionsStateProvider.overrideWithValue(
        SessionsState(projectId: 'p1', sessions: sessions),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('a deleting session cannot be selected', () {
    final container = _container([_entry('a'), _entry('b', deleting: true)]);
    container.read(activeSessionIdProvider.notifier).set('a');

    container.read(activeSessionIdProvider.notifier).set('b');

    expect(container.read(activeSessionIdProvider), 'a');
  });

  test('an ordinary session is selected normally', () {
    final container = _container([_entry('a'), _entry('b')]);
    container.read(activeSessionIdProvider.notifier).set('b');
    expect(container.read(activeSessionIdProvider), 'b');
  });

  // Bootstrap: the id is chosen before the project's session list has landed,
  // so a guard demanding presence would drop every one of those writes.
  test('an id the app has never seen is written through', () {
    final container = _container([_entry('a')]);
    container.read(activeSessionIdProvider.notifier).set('unknown');
    expect(container.read(activeSessionIdProvider), 'unknown');
  });

  test('clearing the selection is never refused', () {
    final container = _container([_entry('a', deleting: true)]);
    container.read(activeSessionIdProvider.notifier).set(null);
    expect(container.read(activeSessionIdProvider), isNull);
  });

  // No session list at all (no focused project yet, or the stream is
  // re-subscribing after a switch) must not become a blanket refusal.
  test('a null session list refuses nothing', () {
    final container = ProviderContainer(
      overrides: [freshSessionsStateProvider.overrideWithValue(null)],
    );
    addTearDown(container.dispose);
    container.read(activeSessionIdProvider.notifier).set('a');
    expect(container.read(activeSessionIdProvider), 'a');
  });
}
