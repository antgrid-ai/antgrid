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
    expect(svc.currentState.gitFileEntries.length, 2);

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
    // Omitted, not false: an older bridge reads the absence as the narrower
    // worktree-only discard, which is what an unflagged call asked for.
    expect(msg.containsKey('includeStaged'), isFalse);

    await svc.dispose();
    await session.close();
  });

  test('discard(includeStaged: true) flags the revert-to-HEAD form', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = FileService.fromSession(session);

    svc.discard(['a.dart'], includeStaged: true);
    await Future<void>.delayed(Duration.zero);

    final msg = t.sent.firstWhere((m) => m['type'] == 'git:discard');
    expect(msg['files'], ['a.dart']);
    expect(msg['includeStaged'], isTrue);

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

  test('commit sends git:commit with message, no file list', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = FileService.fromSession(session);

    svc.commit('msg');
    await Future<void>.delayed(Duration.zero);

    final msg = t.sent.firstWhere((m) => m['type'] == 'git:commit');
    expect(msg['projectId'], 'p');
    expect(msg['message'], 'msg');
    expect(msg.containsKey('files'), isFalse);

    await svc.dispose();
    await session.close();
  });

  test('stageFiles sends git:stage with files', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = FileService.fromSession(session);

    svc.stageFiles(['a.dart']);
    await Future<void>.delayed(Duration.zero);

    final msg = t.sent.firstWhere((m) => m['type'] == 'git:stage');
    expect(msg['projectId'], 'p');
    expect(msg['files'], ['a.dart']);

    await svc.dispose();
    await session.close();
  });

  test('unstageFiles sends git:unstage with files', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = FileService.fromSession(session);

    svc.unstageFiles(['a.dart']);
    await Future<void>.delayed(Duration.zero);

    final msg = t.sent.firstWhere((m) => m['type'] == 'git:unstage');
    expect(msg['projectId'], 'p');
    expect(msg['files'], ['a.dart']);

    await svc.dispose();
    await session.close();
  });

  test('loadStashes sends git:stash-list with seeded projectId', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = FileService.fromSession(session);

    svc.loadStashes();
    await Future<void>.delayed(Duration.zero);

    final msg = t.sent.firstWhere((m) => m['type'] == 'git:stash-list');
    expect(msg['projectId'], 'p');

    await svc.dispose();
    await session.close();
  });

  test('git:stash-list-result populates git.stashes', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = FileService.fromSession(session);

    t.emit('git:stash-list-result', {
      'projectId': 'p',
      'stashes': [
        {
          'ref': 'stash@{0}',
          'branch': 'main',
          'message': 'Before switching to dev',
          'createdAt': 1700000000,
        },
      ],
    });
    await Future<void>.delayed(Duration.zero);

    expect(svc.currentState.git.stashes, hasLength(1));
    expect(svc.currentState.git.stashes.single.ref, 'stash@{0}');
    expect(svc.currentState.git.stashes.single.branch, 'main');

    await svc.dispose();
    await session.close();
  });

  test('restoreStash sends git:stash-pop with ref', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = FileService.fromSession(session);

    svc.restoreStash('stash@{0}');
    await Future<void>.delayed(Duration.zero);

    final msg = t.sent.firstWhere((m) => m['type'] == 'git:stash-pop');
    expect(msg['projectId'], 'p');
    expect(msg['ref'], 'stash@{0}');

    await svc.dispose();
    await session.close();
  });

  test('dropStash sends git:stash-drop with ref', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = FileService.fromSession(session);

    svc.dropStash('stash@{0}');
    await Future<void>.delayed(Duration.zero);

    final msg = t.sent.firstWhere((m) => m['type'] == 'git:stash-drop');
    expect(msg['projectId'], 'p');
    expect(msg['ref'], 'stash@{0}');

    await svc.dispose();
    await session.close();
  });

  test(
    'git:stash-pop-result failure surfaces gitOpFeedback and reloads the list',
    () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = FileService.fromSession(session);

      t.emit('git:stash-pop-result', {
        'projectId': 'p',
        'ref': 'stash@{0}',
        'success': false,
        'error': 'conflict',
      });
      await Future<void>.delayed(Duration.zero);

      expect(svc.currentState.gitOpFeedback, 'conflict');
      // Either outcome re-reads the list — see [FileService.restoreStash].
      expect(t.sent.where((m) => m['type'] == 'git:stash-list'), isNotEmpty);

      await svc.dispose();
      await session.close();
    },
  );

  test(
    'git:stash-drop-result success stays silent but reloads the list',
    () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = FileService.fromSession(session);

      t.emit('git:stash-drop-result', {
        'projectId': 'p',
        'ref': 'stash@{0}',
        'success': true,
      });
      await Future<void>.delayed(Duration.zero);

      expect(svc.currentState.gitOpFeedback, isNull);
      expect(t.sent.where((m) => m['type'] == 'git:stash-list'), isNotEmpty);

      await svc.dispose();
      await session.close();
    },
  );

  test('git:stage-result failure surfaces gitOpFeedback', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = FileService.fromSession(session);

    t.emit('git:stage-result', {
      'projectId': 'p',
      'success': false,
      'files': ['a.dart'],
      'error': 'boom',
    });
    await Future<void>.delayed(Duration.zero);
    expect(svc.currentState.gitOpFeedback, 'boom');

    await svc.dispose();
    await session.close();
  });

  test('git:stage-result success stays silent (no toast)', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = FileService.fromSession(session);

    t.emit('git:stage-result', {
      'projectId': 'p',
      'success': true,
      'files': ['a.dart'],
    });
    await Future<void>.delayed(Duration.zero);
    expect(svc.currentState.gitOpFeedback, isNull);

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

  group('attachment preview', () {
    // The preview is a THIRD file:content consumer beside the Files and Git
    // panes. It shares the verb and the viewers, but not the slot — routing it
    // through the Files pane would evict the file the user has open there.
    test('openPreview reads without disturbing the Files pane', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = FileService.fromSession(session);

      svc.selectFile('src/main.dart');
      await Future<void>.delayed(Duration.zero);
      svc.openPreview('.antgrid/uploads/u1-shot.png', displayName: 'shot.png');
      await Future<void>.delayed(Duration.zero);

      expect(
        t.sent.where(
          (m) =>
              m['type'] == 'file:read' &&
              m['path'] == '.antgrid/uploads/u1-shot.png',
        ),
        hasLength(1),
      );
      expect(svc.currentState.files.selectedFilePath, 'src/main.dart');
      expect(svc.currentState.preview.isLoading, isTrue);
      expect(svc.currentState.preview.displayName, 'shot.png');

      await svc.dispose();
      await session.close();
    });

    test('file:content routes by path — neither slot sees the other', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = FileService.fromSession(session);

      svc.selectFile('src/main.dart');
      svc.openPreview('.antgrid/uploads/u1-shot.png');
      await Future<void>.delayed(Duration.zero);

      t.emit('file:content', {
        'projectId': 'p',
        'path': '.antgrid/uploads/u1-shot.png',
        'content': 'AAAA',
        'size': 3,
        'encoding': 'base64',
        'mimeType': 'image/png',
      });
      await Future<void>.delayed(Duration.zero);

      expect(svc.currentState.preview.content?.mimeType, 'image/png');
      expect(svc.currentState.preview.isLoading, isFalse);
      // The staged upload must not have landed in the Files pane, which is
      // still waiting on its own read.
      expect(svc.currentState.files.viewingFile, isNull);
      expect(svc.currentState.files.isLoading, isTrue);

      t.emit('file:content', {
        'projectId': 'p',
        'path': 'src/main.dart',
        'content': 'void main() {}',
        'size': 14,
        'encoding': 'utf8',
      });
      await Future<void>.delayed(Duration.zero);

      expect(svc.currentState.files.viewingFile?.content, 'void main() {}');
      expect(svc.currentState.preview.content?.mimeType, 'image/png');

      await svc.dispose();
      await session.close();
    });

    test('a read landing after close cannot reopen the overlay', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = FileService.fromSession(session);

      svc.openPreview('.antgrid/uploads/u1-shot.png');
      await Future<void>.delayed(Duration.zero);
      svc.closePreview();
      expect(svc.currentState.preview.isOpen, isFalse);

      // The in-flight read still answers; with the slot cleared its path
      // matches nothing, which is what keeps a dismissed dialog dismissed.
      t.emit('file:content', {
        'projectId': 'p',
        'path': '.antgrid/uploads/u1-shot.png',
        'content': 'AAAA',
        'size': 3,
        'encoding': 'base64',
        'mimeType': 'image/png',
      });
      await Future<void>.delayed(Duration.zero);

      expect(svc.currentState.preview.isOpen, isFalse);
      expect(svc.currentState.preview.content, isNull);

      await svc.dispose();
      await session.close();
    });
  });

  test('double-dispose is idempotent', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = FileService.fromSession(session);

    await svc.dispose();
    await svc.dispose(); // Should not throw.

    await session.close();
  });

  group('tree hydration', () {
    // A managed checkout's tree:full is pushed while its runtime is prepared —
    // before the session list that makes the app build the bundle — so a bundle
    // that waited for the push showed an empty tree for the whole session.
    test('a bundle built after the push pulls its own tree', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      t.emit('tree:full', {
        'projectId': 'p',
        'checkoutId': 'wt-1',
        'root': _rootNode(children: [_file('a.txt', 'a.txt')]),
      });
      await Future<void>.delayed(Duration.zero);

      final svc = FileService.fromSession(session, checkoutId: 'wt-1');
      await Future<void>.delayed(Duration.zero);
      final request = t.sent.lastWhere(
        (m) => m['type'] == 'file:tree:snapshot:request',
      );
      expect(request['checkoutId'], 'wt-1');

      t.emit('file:tree:snapshot', {
        'checkoutId': 'wt-1',
        'seq': 1,
        'tree': _rootNode(children: [_file('a.txt', 'a.txt')]),
      });
      await Future<void>.delayed(Duration.zero);
      expect(svc.currentState.root!.children, hasLength(1));

      await svc.dispose();
      await session.close();
    });

    test('re-pulls on reconnect and stops after dispose', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = FileService.fromSession(session, checkoutId: 'wt-1');
      await Future<void>.delayed(Duration.zero);

      t.redriveHydrators();
      await Future<void>.delayed(Duration.zero);
      var requests = t.sent.where(
        (m) =>
            m['type'] == 'file:tree:snapshot:request' &&
            m['checkoutId'] == 'wt-1',
      );
      expect(requests, hasLength(2));

      await svc.dispose();
      t.redriveHydrators();
      await Future<void>.delayed(Duration.zero);
      requests = t.sent.where(
        (m) =>
            m['type'] == 'file:tree:snapshot:request' &&
            m['checkoutId'] == 'wt-1',
      );
      expect(requests, hasLength(2));

      await session.close();
    });
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

  group('History tab', () {
    test('loadHistory replaces the list; loadMoreHistory appends', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = FileService.fromSession(session);

      svc.loadHistory();
      expect(svc.currentState.git.history.initialLoad, isTrue);
      expect(t.sent.last['type'], 'git:log');
      expect(t.sent.last['skip'], 0);

      t.emit('git:log-result', {
        'projectId': 'p',
        'commits': [
          {
            'sha': 'a' * 40,
            'shortSha': 'aaaaaaa',
            'subject': 'first',
            'authorName': 'Ada',
            'authorEmail': 'ada@example.com',
            'authorDate': '2026-01-01T00:00:00Z',
          },
        ],
        'skip': 0,
        'hasMore': true,
      });
      await Future<void>.delayed(Duration.zero);
      expect(svc.currentState.git.history.commits, hasLength(1));
      expect(svc.currentState.git.history.initialLoad, isFalse);
      expect(svc.currentState.git.history.hasMore, isTrue);

      svc.loadMoreHistory();
      expect(t.sent.last['type'], 'git:log');
      expect(t.sent.last['skip'], 1);

      t.emit('git:log-result', {
        'projectId': 'p',
        'commits': [
          {
            'sha': 'b' * 40,
            'shortSha': 'bbbbbbb',
            'subject': 'second',
            'authorName': 'Ada',
            'authorEmail': 'ada@example.com',
            'authorDate': '2025-12-31T00:00:00Z',
          },
        ],
        'skip': 1,
        'hasMore': false,
      });
      await Future<void>.delayed(Duration.zero);
      expect(
        svc.currentState.git.history.commits.map((c) => c.subject),
        ['first', 'second'],
      );
      expect(svc.currentState.git.history.hasMore, isFalse);

      // No more pages and nothing loading — a scroll-triggered call must not
      // fire a third request.
      svc.loadMoreHistory();
      expect(t.sent.where((m) => m['type'] == 'git:log'), hasLength(2));

      await svc.dispose();
      await session.close();
    });

    test('a dropped git:log leaves an error after the timeout', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = FileService.fromSession(
        session,
        gitActionTimeout: const Duration(milliseconds: 40),
      );

      svc.loadHistory();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(svc.currentState.git.history.loadingMore, isFalse);
      expect(svc.currentState.git.history.error, isNotNull);

      await svc.dispose();
      await session.close();
    });

    test(
      'toggleCommitExpanded fetches a commit\'s files once and caches them',
      () async {
        final t = FakeAgentTransport();
        final session = await _newSession(t);
        final svc = FileService.fromSession(session);

        svc.toggleCommitExpanded('sha1');
        expect(svc.currentState.git.history.expandedShas, {'sha1'});
        expect(t.sent.last['type'], 'git:commit-files');
        expect(t.sent.last['sha'], 'sha1');

        t.emit('git:commit-files-result', {
          'projectId': 'p',
          'sha': 'sha1',
          'files': [
            {
              'path': 'a.txt',
              'status': 'M',
              'additions': 3,
              'deletions': 1,
            },
          ],
        });
        await Future<void>.delayed(Duration.zero);
        expect(svc.currentState.git.history.filesBySha['sha1'], hasLength(1));

        // Collapse, then re-expand: the cache means no second fetch.
        svc.toggleCommitExpanded('sha1');
        expect(svc.currentState.git.history.expandedShas, isEmpty);
        svc.toggleCommitExpanded('sha1');
        expect(svc.currentState.git.history.expandedShas, {'sha1'});
        expect(t.sent.where((m) => m['type'] == 'git:commit-files'), hasLength(1));

        await svc.dispose();
        await session.close();
      },
    );

    test('requestCommitDiff opens a commit-scoped diff distinct from a '
        'working-tree diff for the same path', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = FileService.fromSession(session);

      svc.requestCommitDiff('sha1', 'a.txt');
      expect(svc.currentState.git.diffLoading, isTrue);
      expect(svc.currentState.git.diffCommitSha, 'sha1');
      expect(t.sent.last['type'], 'git:commit-diff');
      expect(t.sent.last['sha'], 'sha1');
      expect(t.sent.last['path'], 'a.txt');

      // A working-tree diff-content reply for the SAME path must not
      // overwrite the commit-scoped one that's in flight.
      t.emit('git:diff-content', {
        'projectId': 'p',
        'path': 'a.txt',
        'diff': 'stale working-tree diff',
        'additions': 9,
        'deletions': 9,
      });
      await Future<void>.delayed(Duration.zero);
      expect(svc.currentState.git.diffLoading, isTrue);
      expect(svc.currentState.git.diffContent, isNull);

      t.emit('git:commit-diff-content', {
        'projectId': 'p',
        'sha': 'sha1',
        'path': 'a.txt',
        'diff': '@@ -1 +1 @@',
        'additions': 1,
        'deletions': 0,
      });
      await Future<void>.delayed(Duration.zero);
      expect(svc.currentState.git.diffLoading, isFalse);
      expect(svc.currentState.git.diffContent, '@@ -1 +1 @@');
      expect(svc.currentState.git.diffCommitSha, 'sha1');

      // Switching to the working-tree diff for a different path clears the
      // commit scope.
      svc.requestDiff('b.txt');
      expect(svc.currentState.git.diffCommitSha, isNull);

      await svc.dispose();
      await session.close();
    });
  });
}
