import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/models/search_models.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/services/search_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import '../helpers/fake_agent_transport.dart';
import '../helpers/parse_probe.dart';
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

    Map<String, dynamic> hit(
      String path,
      int line, {
      int column = 0,
      String lineContent = 'foo',
      List<String> contextBefore = const [],
      List<String> contextAfter = const [],
    }) => {
      'path': path,
      'line': line,
      'column': column,
      'lineContent': lineContent,
      'contextBefore': contextBefore,
      'contextAfter': contextAfter,
    };

    Future<void> emitResult(
      FakeAgentTransport t,
      String? reqId,
      List<Map<String, dynamic>> matches,
    ) async {
      t.emit('file:search-result', {
        'projectId': 'p',
        'requestId': reqId,
        'matches': matches,
      });
      await Future<void>.delayed(Duration.zero);
    }

    List<String> shape(SearchService svc) => [
      for (final g in svc.currentState.results)
        '${g.path}:${g.matches.map((m) => m.line).join(',')}',
    ];

    test('a batch that interleaves files keeps first-seen file order and each '
        "file's arrival order", () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = SearchService.fromSession(session);

      svc.search('foo');
      await Future<void>.delayed(Duration.zero);
      final reqId = svc.currentState.currentRequestId;

      await emitResult(t, reqId, [
        hit('a', 1),
        hit('b', 1),
        hit('a', 2),
        hit('c', 1),
        hit('b', 2),
      ]);
      expect(shape(svc), ['a:1,2', 'b:1,2', 'c:1']);

      await emitResult(t, reqId, [hit('c', 2), hit('a', 3), hit('d', 1)]);
      expect(shape(svc), ['a:1,2,3', 'b:1,2', 'c:1,2', 'd:1']);

      await svc.dispose();
      await session.close();
    });

    test('a file the batch did not touch keeps the same group object',
        () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = SearchService.fromSession(session);

      svc.search('foo');
      await Future<void>.delayed(Duration.zero);
      final reqId = svc.currentState.currentRequestId;

      await emitResult(t, reqId, [hit('a', 1), hit('b', 1)]);
      final aGroup = svc.currentState.results[0];
      await emitResult(t, reqId, [hit('b', 2)]);

      expect(identical(svc.currentState.results[0], aGroup), isTrue);
      expect(svc.currentState.results[1].matches.map((m) => m.line), [1, 2]);

      await svc.dispose();
      await session.close();
    });

    test('merged matches keep line, column, content and context', () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = SearchService.fromSession(session);

      svc.search('foo');
      await Future<void>.delayed(Duration.zero);
      final reqId = svc.currentState.currentRequestId;

      await emitResult(t, reqId, [
        hit(
          'a.txt',
          1,
          column: 4,
          lineContent: 'x foo',
          contextBefore: ['b1'],
          contextAfter: ['a1'],
        ),
        hit(
          'a.txt',
          2,
          column: 2,
          lineContent: 'foo y',
          contextBefore: ['b2'],
          contextAfter: ['a2'],
        ),
      ]);

      final matches = svc.currentState.results[0].matches;
      expect(matches, hasLength(2));
      expect(matches[0].line, 1);
      expect(matches[0].column, 4);
      expect(matches[0].lineContent, 'x foo');
      expect(matches[0].contextBefore, ['b1']);
      expect(matches[0].contextAfter, ['a1']);
      expect(matches[1].line, 2);
      expect(matches[1].column, 2);
      expect(matches[1].lineContent, 'foo y');
      expect(matches[1].contextBefore, ['b2']);
      expect(matches[1].contextAfter, ['a2']);

      await svc.dispose();
      await session.close();
    });

    test('a new search groups its results from scratch', () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = SearchService.fromSession(session);

      svc.search('foo');
      await Future<void>.delayed(Duration.zero);
      await emitResult(t, svc.currentState.currentRequestId, [hit('a', 1)]);

      svc.search('bar');
      await Future<void>.delayed(Duration.zero);
      await emitResult(t, svc.currentState.currentRequestId, [hit('a', 5)]);

      expect(shape(svc), ['a:5']);

      await svc.dispose();
      await session.close();
    });

    test('a batch for a superseded search is dropped', () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = SearchService.fromSession(session);

      svc.search('foo');
      final first = svc.currentState.currentRequestId;
      svc.search('bar');
      final second = svc.currentState.currentRequestId;
      await Future<void>.delayed(Duration.zero);

      await emitResult(t, first, [hit('a', 1)]);

      expect(svc.currentState.results, isEmpty);
      expect(svc.currentState.currentRequestId, second);

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

  group('frame type pre-check', () {
    test('SearchService hands search results and completion to the parser',
        () async {
      final probe = await ParseProbe.open();
      final svc = probe.build(() => SearchService.fromSession(probe.session));
      addTearDown(svc.dispose);

      await probe.expectParsed([
        heavyProbe('file:search-result'),
        heavyProbe('file:search-done'),
      ]);
    });

    test('SearchService never parses a frame type it does not act on',
        () async {
      final probe = await ParseProbe.open();
      final svc = probe.build(() => SearchService.fromSession(probe.session));
      addTearDown(svc.dispose);

      await probe.expectNeverParsed([
        heavyProbe('file:tree:children'),
        heavyProbe('agent:item-delta'),
        heavyProbe('file:content'),
      ]);
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

    test('an empty result batch still keeps a live search alive', () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = SearchService.fromSession(
        session,
        searchIdleTimeout: const Duration(milliseconds: 80),
      );

      svc.search('foo');
      final reqId = svc.currentState.currentRequestId;

      await Future<void>.delayed(const Duration(milliseconds: 50));
      t.emit('file:search-result', {
        'projectId': 'p',
        'requestId': reqId,
        'matches': <Map<String, dynamic>>[],
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(svc.currentState.isSearching, isTrue);
      expect(svc.currentState.error, isNull);

      await svc.dispose();
      await session.close();
    });

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
