import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/services/file_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import '../helpers/prefs_test_mock.dart';

Map<String, dynamic> _rootNode({
  String name = 'proj',
  String path = '',
  List<Map<String, dynamic>> children = const [],
}) => {'name': name, 'path': path, 'type': 'directory', 'children': children};

Map<String, dynamic> _file(String name, String path) => {
  'name': name,
  'path': path,
  'type': 'file',
};

Future<ProjectSession> _newSession(
  FakeAgentTransport t, {
  String projectId = 'p',
}) async {
  final cache = await CachedSessionsStore.open();
  return ProjectSession(
    projectId: projectId,
    transport: t,
    mode: ProjectSessionMode.local,
    cachedSessionsStore: cache,
    onClose: () async {
      await t.dispose();
    },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    useInMemoryPrefs();
  });

  test(
    'fromSession ctor seeds projectId and subscribes to heavy stream',
    () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = FileService.fromSession(session);

      await Future<void>.delayed(Duration.zero);
      expect(
        t.sent.where(
          (m) => m['type'] == 'client:focus-state' && m['paused'] == false,
        ),
        hasLength(1),
      );
      expect(svc.currentState.projectId, 'p');

      await svc.dispose();
      await session.close();
    },
  );

  test('tree:full updates state', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = FileService.fromSession(session);

    t.emitJson({
      'id': 'tf1',
      'timestamp': 0,
      'type': 'tree:full',
      'projectId': 'p',
      'root': _rootNode(children: [_file('a.txt', 'a.txt')]),
      'seq': 5,
    });
    await Future<void>.delayed(Duration.zero);

    expect(svc.currentState.root, isNotNull);
    expect(svc.currentState.root!.children, hasLength(1));
    expect(svc.currentState.root!.children[0].path, 'a.txt');

    await svc.dispose();
    await session.close();
  });

  test('stale tree:update (seq <= snapshot seq) is dropped', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = FileService.fromSession(session);

    t.emit('file:tree:snapshot', {
      'tree': _rootNode(children: [_file('a.txt', 'a.txt')]),
      'seq': 5,
    });
    await Future<void>.delayed(Duration.zero);

    t.emitJson({
      'id': 'u1',
      'timestamp': 0,
      'type': 'tree:update',
      'projectId': 'p',
      'seq': 4,
      'added': [_file('stale.txt', 'stale.txt')],
      'modified': const <Map<String, dynamic>>[],
      'removed': const <String>[],
    });
    await Future<void>.delayed(Duration.zero);

    expect(
      svc.currentState.root!.children.any((c) => c.path == 'stale.txt'),
      isFalse,
    );

    await svc.dispose();
    await session.close();
  });

  test('fresh tree:update applied after snapshot', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = FileService.fromSession(session);

    t.emit('file:tree:snapshot', {
      'tree': _rootNode(children: [_file('a.txt', 'a.txt')]),
      'seq': 5,
    });
    await Future<void>.delayed(Duration.zero);

    t.emitJson({
      'id': 'u2',
      'timestamp': 0,
      'type': 'tree:update',
      'projectId': 'p',
      'seq': 6,
      'added': [_file('fresh.txt', 'fresh.txt')],
      'modified': const <Map<String, dynamic>>[],
      'removed': const <String>[],
    });
    await Future<void>.delayed(Duration.zero);

    expect(
      svc.currentState.root!.children.any((c) => c.path == 'fresh.txt'),
      isTrue,
    );

    await svc.dispose();
    await session.close();
  });

  test('requestFileContent sends file:read with seeded projectId', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t, projectId: 'proj-x');
    final svc = FileService.fromSession(session);

    svc.requestFileContent('lib/main.dart');
    await Future<void>.delayed(Duration.zero);

    final readMsg = t.sent.firstWhere((m) => m['type'] == 'file:read');
    expect(readMsg['projectId'], 'proj-x');
    expect(readMsg['path'], 'lib/main.dart');

    await svc.dispose();
    await session.close();
  });

  test('dispose unsubscribes — no further state updates from heavy', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = FileService.fromSession(session);

    await svc.dispose();

    t.emit('file:tree:snapshot', {
      'tree': _rootNode(children: [_file('after.txt', 'after.txt')]),
      'seq': 99,
    });
    await Future<void>.delayed(Duration.zero);

    expect(svc.currentState.root, isNull);
    await session.close();
  });

  test('git:status routed via status tier updates gitFileStatuses', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = FileService.fromSession(session);

    t.emit('git:status', {
      'projectId': 'p',
      'files': [
        {'path': 'lib/main.dart', 'status': 'M'},
        {'path': 'lib/new.dart', 'status': 'A'},
      ],
    });
    await Future<void>.delayed(Duration.zero);

    expect(svc.currentState.gitFileStatuses['lib/main.dart'], 'M');
    expect(svc.currentState.gitFileStatuses['lib/new.dart'], 'A');

    await svc.dispose();
    await session.close();
  });

  test('git:diff-content routed via status tier updates diffContent', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = FileService.fromSession(session);

    // Select the diff path first so the handler accepts the reply.
    svc.requestDiff('lib/main.dart');
    await Future<void>.delayed(Duration.zero);

    t.emit('git:diff-content', {
      'projectId': 'p',
      'path': 'lib/main.dart',
      'diff': '@@ -1 +1 @@\n-old\n+new\n',
      'additions': 1,
      'deletions': 1,
    });
    await Future<void>.delayed(Duration.zero);

    expect(svc.currentState.git.diffContent, contains('+new'));
    expect(svc.currentState.git.diffAdditions, 1);
    expect(svc.currentState.git.diffDeletions, 1);
    expect(svc.currentState.git.diffLoading, isFalse);

    await svc.dispose();
    await session.close();
  });

  test(
    'repeat identical discard result advances the op seq (re-toast)',
    () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = FileService.fromSession(session);

      t.emit('git:discard-result', {
        'projectId': 'p',
        'success': true,
        'files': ['a.dart'],
      });
      await Future<void>.delayed(Duration.zero);
      expect(svc.currentState.gitOpFeedback, 'Discarded changes');
      final firstSeq = svc.currentState.gitOpFeedbackSeq;
      expect(firstSeq, greaterThan(0));

      // An identical result message must still register as a distinct event so
      // the toaster re-fires — the seq advances even though the text repeats.
      t.emit('git:discard-result', {
        'projectId': 'p',
        'success': true,
        'files': ['a.dart'],
      });
      await Future<void>.delayed(Duration.zero);
      expect(svc.currentState.gitOpFeedback, 'Discarded changes');
      expect(svc.currentState.gitOpFeedbackSeq, greaterThan(firstSeq));

      await svc.dispose();
      await session.close();
    },
  );

  test('discard sends git:discard with files', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = FileService.fromSession(session);

    svc.discard(['a.dart']);
    await Future<void>.delayed(Duration.zero);

    final msg = t.sent.firstWhere((m) => m['type'] == 'git:discard');
    expect(msg['projectId'], 'p');
    expect(msg['files'], ['a.dart']);

    await svc.dispose();
    await session.close();
  });

  test(
    'repeat identical commit result advances the op seq (re-toast)',
    () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = FileService.fromSession(session);

      t.emit('git:commit-result', {'projectId': 'p', 'success': true});
      await Future<void>.delayed(Duration.zero);
      expect(svc.currentState.gitOpFeedback, 'Committed');
      final firstSeq = svc.currentState.gitOpFeedbackSeq;
      expect(firstSeq, greaterThan(0));

      t.emit('git:commit-result', {'projectId': 'p', 'success': true});
      await Future<void>.delayed(Duration.zero);
      expect(svc.currentState.gitOpFeedback, 'Committed');
      expect(svc.currentState.gitOpFeedbackSeq, greaterThan(firstSeq));

      await svc.dispose();
      await session.close();
    },
  );

  test('commit sends git:commit with message and files', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = FileService.fromSession(session);

    svc.commit('msg', ['a.dart']);
    await Future<void>.delayed(Duration.zero);

    final msg = t.sent.firstWhere((m) => m['type'] == 'git:commit');
    expect(msg['projectId'], 'p');
    expect(msg['message'], 'msg');
    expect(msg['files'], ['a.dart']);

    await svc.dispose();
    await session.close();
  });

  test('handleFragmentFailure clears a stuck diff spinner', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = FileService.fromSession(session);

    svc.requestDiff('lib/main.dart');
    await Future<void>.delayed(Duration.zero);
    expect(svc.currentState.git.diffLoading, isTrue);

    // The diff transfer aborted (fragment timeout) and exhausted its retries.
    svc.handleFragmentFailure(
      const FragHint('git:diff-content', 'lib/main.dart'),
    );
    expect(svc.currentState.git.diffLoading, isFalse);

    await svc.dispose();
    await session.close();
  });

  test('handleFragmentFailure surfaces a file:content load error', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = FileService.fromSession(session);

    svc.selectFile('big.bin');
    await Future<void>.delayed(Duration.zero);
    expect(svc.currentState.files.isLoading, isTrue);

    svc.handleFragmentFailure(const FragHint('file:content', 'big.bin'));
    expect(svc.currentState.files.isLoading, isFalse);
    expect(svc.currentState.files.viewingFile?.error, isNotNull);

    await svc.dispose();
    await session.close();
  });

  test('double-dispose is idempotent', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = FileService.fromSession(session);

    await svc.dispose();
    await svc.dispose(); // Should not throw.

    await session.close();
  });

  group('git:diff bounded by tier-2 action', () {
    test('requestDiff whose content never arrives clears diffLoading after '
        'the timeout', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = FileService.fromSession(
        session,
        gitActionTimeout: const Duration(milliseconds: 40),
      );

      svc.requestDiff('a.txt');
      expect(svc.currentState.git.diffLoading, isTrue);

      // No git:diff-content and no frag abort — the send-dropped strand the
      // frag backstop can't see. The tier-2 action must clear the spinner.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(svc.currentState.git.diffLoading, isFalse);

      await svc.dispose();
      await session.close();
    });

    test(
      'git:diff-content cancels the action — no spurious re-clear',
      () async {
        final t = FakeAgentTransport();
        final session = await _newSession(t);
        final svc = FileService.fromSession(
          session,
          gitActionTimeout: const Duration(milliseconds: 40),
        );

        svc.requestDiff('a.txt');
        t.emit('git:diff-content', {
          'projectId': 'p',
          'path': 'a.txt',
          'diff': '@@ -1 +1 @@',
          'additions': 1,
          'deletions': 0,
        });
        await Future<void>.delayed(Duration.zero);
        expect(svc.currentState.git.diffLoading, isFalse);
        expect(svc.currentState.git.diffContent, '@@ -1 +1 @@');

        // Past the window: the settled action must not touch the diff state.
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(svc.currentState.git.diffContent, '@@ -1 +1 @@');

        await svc.dispose();
        await session.close();
      },
    );
  });
}
