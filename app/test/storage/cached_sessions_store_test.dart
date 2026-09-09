import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import '../helpers/prefs_test_mock.dart';

void main() {
  setUp(() {
    useInMemoryPrefs();
  });

  SessionEntry s(String id, {bool running = false, bool archived = false}) =>
      SessionEntry(
        id: id,
        name: 'Session $id',
        createdAt: 1,
        lastUsedAt: 2,
        archived: archived,
        running: running,
      );

  test('get returns empty list for unknown entry', () async {
    final store = await CachedSessionsStore.open();
    expect(store.get('p1'), isEmpty);
  });

  test('put + reopen round-trips entries (running stripped on disk)', () async {
    final store = await CachedSessionsStore.open();
    await store.put('p1', [s('a'), s('b', running: true)]);
    // In-memory cache keeps `running` for the lifetime of this process so
    // warm cross-project switches still show accurate status.
    expect(store.get('p1')[1].running, isTrue);
    await store.flushNow();

    final reopened = await CachedSessionsStore.open();
    final list = reopened.get('p1');
    expect(list, hasLength(2));
    expect(list[0].id, 'a');
    // `running` is process-lifetime state — a fresh launch must never
    // resurrect a stale "running" flag before the agent reports status.
    expect(list[1].running, isFalse);
  });

  test('changes emits the entryId that was written', () async {
    final store = await CachedSessionsStore.open();
    addTearDown(store.close);
    final ids = <String>[];
    final sub = store.changes.listen(ids.add);

    await store.put('p1', [s('a')]);
    await store.put('p2', [s('b')]);
    await store.flushNow();
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();

    expect(ids, ['p1', 'p2']);
  });

  test('put is no-op when encoded list is unchanged', () async {
    final store = await CachedSessionsStore.open();
    addTearDown(store.close);
    await store.put('p1', [s('a')]);
    await store.flushNow();

    final ids = <String>[];
    final sub = store.changes.listen(ids.add);
    await store.put('p1', [s('a')]);
    await store.flushNow();
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();

    expect(ids, isEmpty);
  });

  test('removeKey drops the entry and emits', () async {
    final store = await CachedSessionsStore.open();
    addTearDown(store.close);
    await store.put('p1', [s('a')]);
    await store.flushNow();

    final ids = <String>[];
    final sub = store.changes.listen(ids.add);
    await store.removeKey('p1');
    await store.flushNow();
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();

    expect(ids, ['p1']);
    expect(store.get('p1'), isEmpty);
  });

  test('corrupt blob reads as empty without throwing', () async {
    useInMemoryPrefs({'antgrid.session_cache.v1': '{not json'});
    final store = await CachedSessionsStore.open();
    expect(store.get('p1'), isEmpty);
  });

  test(
    'labels persisted under the legacy embedded field (pre-split-key) are still loaded',
    () async {
      useInMemoryPrefs({
        'antgrid.session_cache.v1':
            '{"version":1,"entries":{},"labels":{"uuid.proj1":"My Project"}}',
      });
      final store = await CachedSessionsStore.open();
      expect(store.label('uuid.proj1'), 'My Project');
    },
  );

  // The cache is what every surface falls back to once the live stream stops
  // matching an entry, and nothing here is subscribed to the push that clears
  // the flag. A connection lost inside the 3-15s delete window would otherwise
  // leave the row inert — unopenable and undeletable — for the rest of the run.
  test(
    'deleting is dropped entering the cache, not just on the way to disk',
    () async {
      final store = await CachedSessionsStore.open();
      await store.put('p1', [s('a').copyWith(deleting: true)]);
      expect(store.get('p1').single.deleting, isFalse);
      await store.flushNow();

      final blob = await SharedPreferencesAsync().getString(
        'antgrid.session_cache.v1',
      );
      expect(blob, isNotNull);
      expect(blob, isNot(contains('deleting')));

      final reopened = await CachedSessionsStore.open();
      expect(reopened.get('p1').single.deleting, isFalse);
    },
  );

  // The `running` precedent: the write stripping a field is not durable across
  // builds, so the read forces it too.
  test(
    'a deleting flag persisted by another build is forced false on load',
    () async {
      await SharedPreferencesAsync().setString(
        'antgrid.session_cache.v1',
        jsonEncode({
          'version': 1,
          'entries': {
            'p1': [
              {...s('a').toJson(), 'deleting': true, 'running': true},
            ],
          },
        }),
      );

      final store = await CachedSessionsStore.open();
      expect(store.get('p1').single.deleting, isFalse);
      expect(store.get('p1').single.running, isFalse);
    },
  );
}
