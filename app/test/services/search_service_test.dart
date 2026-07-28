import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/models/search_models.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/services/search_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import '../helpers/prefs_test_mock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    useInMemoryPrefs();
  });

  Future<ProjectSession> newSession(
    FakeAgentTransport t, {
    String projectId = 'p',
  }) async {
    final cache = await CachedSessionsStore.open();
    return ProjectSession(
      projectId: projectId,
      transport: t,
      mode: ProjectSessionMode.local,
      cachedSessionsStore: cache,
      onClose: () async => await t.dispose(),
    );
  }

  group('SearchState', () {
    test('default state has empty values', () {
      const state = SearchState();
      expect(state.query, '');
      expect(state.caseSensitive, false);
      expect(state.regex, false);
      expect(state.wholeWord, false);
      expect(state.isSearching, false);
      expect(state.results, isEmpty);
      expect(state.totalMatches, 0);
    });

    test('copyWith updates specified fields', () {
      const state = SearchState();
      final updated = state.copyWith(
        query: 'hello',
        caseSensitive: true,
        isSearching: true,
      );
      expect(updated.query, 'hello');
      expect(updated.caseSensitive, true);
      expect(updated.isSearching, true);
      expect(updated.regex, false); // unchanged
    });

    test('copyWith with clear flags nullifies fields', () {
      final state = const SearchState().copyWith(
        currentRequestId: 'req-1',
        duration: 100,
        engine: 'ripgrep',
        error: 'test',
      );
      final cleared = state.copyWith(
        clearCurrentRequestId: true,
        clearDuration: true,
        clearEngine: true,
        clearError: true,
      );
      expect(cleared.currentRequestId, isNull);
      expect(cleared.duration, isNull);
      expect(cleared.engine, isNull);
      expect(cleared.error, isNull);
    });
  });

  group('SearchFileGroup', () {
    test('addMatches appends to existing matches', () {
      const group = SearchFileGroup(
        path: 'test.dart',
        matches: [
          SearchMatch(
            line: 1,
            column: 1,
            lineContent: 'hello',
            contextBefore: [],
            contextAfter: [],
          ),
        ],
      );
      final updated = group.addMatches([
        const SearchMatch(
          line: 5,
          column: 1,
          lineContent: 'hello again',
          contextBefore: [],
          contextAfter: [],
        ),
      ]);
      expect(updated.matches.length, 2);
      expect(updated.matches[1].line, 5);
    });
  });

  group('SearchService.fromSession', () {
    test('search() sends file:search with seeded projectId', () async {
      final t = FakeAgentTransport();
      final session = await newSession(t, projectId: 'proj-s');
      final svc = SearchService.fromSession(session);

      svc.search('foo');
      await Future<void>.delayed(Duration.zero);

      final sent = t.sent.firstWhere((m) => m['type'] == 'file:search');
      expect(sent['projectId'], 'proj-s');
      expect(sent['query'], 'foo');
      expect(sent['requestId'], isNotNull);

      await svc.dispose();
      await session.close();
    });

    test('file:search-result updates state', () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = SearchService.fromSession(session);

      svc.search('foo');
      await Future<void>.delayed(Duration.zero);
      final reqId = svc.currentState.currentRequestId;
      expect(reqId, isNotNull);

      t.emit('file:search-result', {
        'projectId': 'p',
        'requestId': reqId,
        'matches': [
          {
            'path': 'a.txt',
            'line': 1,
            'column': 0,
            'lineContent': 'foo',
            'contextBefore': <String>[],
            'contextAfter': <String>[],
          },
        ],
      });
      await Future<void>.delayed(Duration.zero);

      expect(svc.currentState.results, hasLength(1));
      expect(svc.currentState.results.first.path, 'a.txt');

      await svc.dispose();
      await session.close();
    });

    test('file:search-done flips isSearching off', () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = SearchService.fromSession(session);

      svc.search('foo');
      await Future<void>.delayed(Duration.zero);
      final reqId = svc.currentState.currentRequestId;

      t.emit('file:search-done', {
        'projectId': 'p',
        'requestId': reqId,
        'totalMatches': 2,
        'totalFiles': 1,
        'duration': 42,
        'engine': 'ripgrep',
      });
      await Future<void>.delayed(Duration.zero);

      expect(svc.currentState.isSearching, isFalse);
      expect(svc.currentState.totalMatches, 2);
      expect(svc.currentState.engine, 'ripgrep');

      await svc.dispose();
      await session.close();
    });

    test('dispose is idempotent', () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = SearchService.fromSession(session);

      await svc.dispose();
      await svc.dispose(); // idempotent

      await session.close();
    });
  });

  group('SearchService idle-timeout (tier-2 streaming action)', () {
    test('a search whose reply never arrives clears isSearching after the idle '
        'window', () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = SearchService.fromSession(
        session,
        searchIdleTimeout: const Duration(milliseconds: 40),
      );

      svc.search('foo');
      expect(svc.currentState.isSearching, isTrue);

      // No result and no file:search-done: the strand. The idle guard must
      // settle the spinner instead of leaving it spinning forever.
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(svc.currentState.isSearching, isFalse);
      expect(svc.currentState.error, isNotNull);
      expect(svc.currentState.currentRequestId, isNull);

      await svc.dispose();
      await session.close();
    });

    test(
      'a streaming result resets the idle clock so a live search survives',
      () async {
        final t = FakeAgentTransport();
        final session = await newSession(t);
        final svc = SearchService.fromSession(
          session,
          searchIdleTimeout: const Duration(milliseconds: 80),
        );

        svc.search('foo');
        final reqId = svc.currentState.currentRequestId;

        // A result lands before the idle window elapses, resetting it.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        t.emit('file:search-result', {
          'projectId': 'p',
          'requestId': reqId,
          'matches': [
            {
              'path': 'a.txt',
              'line': 1,
              'column': 0,
              'lineContent': 'foo',
              'contextBefore': <String>[],
              'contextAfter': <String>[],
            },
          ],
        });
        await Future<void>.delayed(const Duration(milliseconds: 50));

        // 100ms total > 80ms idle, but the result at 50ms reset it — still alive.
        expect(svc.currentState.isSearching, isTrue);

        await svc.dispose();
        await session.close();
      },
    );

    test(
      'file:search-done cancels the idle guard — no late stall error',
      () async {
        final t = FakeAgentTransport();
        final session = await newSession(t);
        final svc = SearchService.fromSession(
          session,
          searchIdleTimeout: const Duration(milliseconds: 40),
        );

        svc.search('foo');
        final reqId = svc.currentState.currentRequestId;
        t.emit('file:search-done', {
          'projectId': 'p',
          'requestId': reqId,
          'totalMatches': 0,
          'totalFiles': 0,
          'duration': 1,
          'engine': 'ripgrep',
        });
        await Future<void>.delayed(Duration.zero);
        expect(svc.currentState.isSearching, isFalse);

        // Past the idle window: a settled guard must not fire a spurious error.
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(svc.currentState.error, isNull);

        await svc.dispose();
        await session.close();
      },
    );
  });
}
