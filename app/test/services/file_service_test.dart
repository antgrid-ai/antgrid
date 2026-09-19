import 'dart:async';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/models/preferences_models.dart';
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

/// Seeds the tree the way production does: the root's own depth-1 listing,
/// carried on `file:tree:children`. Takes the `tree`/`seq` shape the
/// superseded `file:tree:snapshot` seed used so a fixture reads the same.
void _emitRootTree(FakeAgentTransport t, Map<String, dynamic> payload) {
  final root = payload['tree'] as Map<String, dynamic>;
  t.emit('file:tree:children', {
    if (payload['checkoutId'] != null) 'checkoutId': payload['checkoutId'],
    'listings': [
      {
        'path': '',
        'children': root['children'] ?? const <Map<String, dynamic>>[],
        if (root['truncated'] == true) 'truncated': true,
      },
    ],
    'seq': payload['seq'],
  });
}

List<Map<String, dynamic>> _treeRequests(FakeAgentTransport t) =>
    t.sent.where((m) => m['type'] == 'file:tree:root:request').toList();

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
    'activation alone does not request a tree; owners share demand',
    () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = session.fileService;
      svc.activate();
      await Future<void>.delayed(Duration.zero);
      List<Map<String, dynamic>> requests() => t.sent
          .where((m) => m['type'] == 'file:tree:root:request')
          .toList();
      expect(requests(), isEmpty);
      svc.setTreeInterest('files', true);
      svc.setTreeInterest('mentions', true);
      svc.setTreeInterest('files', true);
      await Future<void>.delayed(Duration.zero);
      expect(requests(), hasLength(1));
      svc.setTreeInterest('files', false);
      t.redriveHydrators();
      await Future<void>.delayed(Duration.zero);
      expect(requests(), hasLength(2));
      svc.setTreeInterest('mentions', false);
      t.redriveHydrators();
      await Future<void>.delayed(Duration.zero);
      expect(requests(), hasLength(2));
      await session.close();
    },
  );

  test(
    'tree demand survives checkout deactivation and foreground resume',
    () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = session.fileService;
      svc.activate();
      svc.setTreeInterest('picker', true);
      await Future<void>.delayed(Duration.zero);
      svc.deactivate();
      session.setLifecyclePaused(true);
      await Future<void>.delayed(Duration.zero);
      t.clearSent();
      session.setLifecyclePaused(false);
      await Future<void>.delayed(Duration.zero);
      expect(
        t.sent.where((m) => m['type'] == 'file:tree:root:request'),
        hasLength(1),
      );
      svc.setTreeInterest('picker', false);
      session.setLifecyclePaused(true);
      await Future<void>.delayed(Duration.zero);
      t.clearSent();
      session.setLifecyclePaused(false);
      await Future<void>.delayed(Duration.zero);
      expect(
        t.sent.where((m) => m['type'] == 'file:tree:root:request'),
        isEmpty,
      );
      await session.close();
    },
  );

  test(
    'hidden sequence gaps require a full tree when demand returns',
    () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = session.fileService;
      _emitRootTree(t, {'tree': _rootNode(), 'seq': 5});
      await Future<void>.delayed(Duration.zero);
      t.emit('tree:update', {
        'projectId': 'p',
        'seq': 9,
        'added': [_file('new', 'new')],
        'modified': [],
        'removed': [],
      });
      await Future<void>.delayed(Duration.zero);
      expect(
        t.sent.where((m) => m['type'] == 'file:tree:root:request'),
        isEmpty,
      );
      t.emit('file:tree:unchanged', {'seq': 5});
      await Future<void>.delayed(Duration.zero);
      svc.setTreeInterest('picker', true);
      await Future<void>.delayed(Duration.zero);
      final request = t.sent.lastWhere(
        (m) => m['type'] == 'file:tree:root:request',
      );
      expect(request.containsKey('sinceSeq'), isFalse);
      await session.close();
    },
  );

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

  // Superseded by file:tree:root/children — the bridge still force-resends
  // tree:full on watcher overflow (paired with file:tree:invalidated, which
  // this app reacts to instead), so it must land as a pure no-op rather than
  // reviving the whole-tree push. See _handleTreeFull's TODO(wave-6).
  test('tree:full is ignored', () async {
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

    expect(svc.currentState.root, isNull);

    await svc.dispose();
    await session.close();
  });

  test('stale tree:update (seq <= snapshot seq) is dropped', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = FileService.fromSession(session);

    _emitRootTree(t, {
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

  // A truncated directory's `children` is an ordered PREFIX, not the whole
  // of it — a local insert cannot know whether the added node belongs inside
  // that prefix or past the cut the bridge already made, so a delta into one
  // must force a re-list instead of repairing the tree in place.
  test(
    'a tree:update into a truncated directory triggers a re-list, not a local insert',
    () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      // The re-list this test asserts on fires from `_applyTreeUpdate`
      // unconditionally (it isn't gated on tree interest, matching the old
      // merge behaviour) — a second, independently-constructed FileService
      // on the same session would react to the same broadcast frames and
      // double the send. Drive the session's own instance instead.
      final svc = session.fileService;

      _emitRootTree(t, {
        'tree': {
          ..._rootNode(
            children: [
              {
                'name': 'big',
                'path': 'big',
                'type': 'directory',
                'children': [_file('a.txt', 'big/a.txt')],
                'truncated': true,
              },
            ],
          ),
        },
        'seq': 5,
      });
      await Future<void>.delayed(Duration.zero);

      expect(svc.currentState.root!.children[0].truncated, isTrue);
      t.clearSent();

      t.emitJson({
        'id': 'u-cut',
        'timestamp': 0,
        'type': 'tree:update',
        'projectId': 'p',
        'seq': 6,
        'added': [_file('b.txt', 'big/b.txt')],
        'modified': const <Map<String, dynamic>>[],
        'removed': const <String>[],
      });
      await Future<void>.delayed(Duration.zero);

      final big = svc.currentState.root!.children.firstWhere(
        (c) => c.path == 'big',
      );
      expect(big.children.map((c) => c.path), isNot(contains('big/b.txt')));
      expect(big.truncated, isTrue);

      final relist = t.sent.where(
        (m) =>
            m['type'] == 'file:tree:children:request' &&
            (m['paths'] as List).contains('big'),
      );
      expect(relist, hasLength(1));

      await session.close();
    },
  );

  // A directory this app has never fetched has nothing on the spine to
  // insert into — the delta is dropped rather than fabricating a listing
  // out of a single added/modified node.
  test('a tree:update into an unloaded directory is dropped', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = FileService.fromSession(session);

    _emitRootTree(t, {
      'tree': {
        ..._rootNode(
          children: [
            {'name': 'dirA', 'path': 'dirA', 'type': 'directory'},
          ],
        ),
      },
      'seq': 5,
    });
    await Future<void>.delayed(Duration.zero);

    expect(svc.currentState.root!.children[0].childrenLoaded, isFalse);

    t.emitJson({
      'id': 'u-unloaded',
      'timestamp': 0,
      'type': 'tree:update',
      'projectId': 'p',
      'seq': 6,
      'added': [_file('x.txt', 'dirA/x.txt')],
      'modified': const <Map<String, dynamic>>[],
      'removed': const <String>[],
    });
    await Future<void>.delayed(Duration.zero);

    final dirA = svc.currentState.root!.children.firstWhere(
      (c) => c.path == 'dirA',
    );
    expect(dirA.children, isEmpty);

    await svc.dispose();
    await session.close();
  });

  // The spine copy behind both file:tree:children and tree:update must reuse
  // every subtree it did not touch BY REFERENCE — the whole point of
  // replacing the old whole-tree clone (a 6 Hz deep copy on the UI thread).
  test(
    '_updateAt leaves an untouched sibling subtree identical by reference',
    () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = FileService.fromSession(session)
        ..activate()
        ..setTreeInterest('files-test', true);
      await Future<void>.delayed(Duration.zero);

      t.emit('file:tree:children', {
        'listings': [
          {
            'path': '',
            'children': [
              {'name': 'dirA', 'path': 'dirA', 'type': 'directory'},
              {'name': 'dirB', 'path': 'dirB', 'type': 'directory'},
            ],
          },
        ],
        'seq': 1,
      });
      await Future<void>.delayed(Duration.zero);

      final dirBBefore = svc.currentState.root!.children.firstWhere(
        (c) => c.path == 'dirB',
      );

      unawaited(svc.toggleExpanded('dirA'));
      await Future<void>.delayed(Duration.zero);
      t.emit('file:tree:children', {
        'listings': [
          {
            'path': 'dirA',
            'children': [_file('a.txt', 'dirA/a.txt')],
          },
        ],
        'seq': 2,
      });
      await Future<void>.delayed(Duration.zero);

      final dirBAfter = svc.currentState.root!.children.firstWhere(
        (c) => c.path == 'dirB',
      );
      expect(identical(dirBBefore, dirBAfter), isTrue);

      await svc.dispose();
      await session.close();
    },
  );

  group('lazy expansion', () {
    test('collapse then expand always issues a fresh request', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = FileService.fromSession(session);

      t.emit('file:tree:children', {
        'listings': [
          {
            'path': '',
            'children': [
              {'name': 'dirA', 'path': 'dirA', 'type': 'directory'},
            ],
          },
        ],
        'seq': 1,
      });
      await Future<void>.delayed(Duration.zero);

      await svc.toggleExpanded('dirA');
      t.emit('file:tree:children', {
        'listings': [
          {
            'path': 'dirA',
            'children': [_file('a.txt', 'dirA/a.txt')],
          },
        ],
        'seq': 2,
      });
      await Future<void>.delayed(Duration.zero);
      expect(
        svc.currentState.root!.children.first.childrenLoaded,
        isTrue,
      );

      await svc.toggleExpanded('dirA'); // collapse
      t.clearSent();
      await svc.toggleExpanded('dirA'); // re-expand — no cache-hit branch

      final requests = t.sent.where(
        (m) =>
            m['type'] == 'file:tree:children:request' &&
            (m['paths'] as List).contains('dirA'),
      );
      expect(requests, hasLength(1));

      await svc.dispose();
      await session.close();
    });

    test(
      'a stale out-of-order reply for the same path is discarded',
      () async {
        final t = FakeAgentTransport();
        final session = await _newSession(t);
        final svc = FileService.fromSession(session);

        t.emit('file:tree:children', {
          'listings': [
            {
              'path': '',
              'children': [
                {'name': 'dirA', 'path': 'dirA', 'type': 'directory'},
              ],
            },
          ],
          'seq': 1,
        });
        await Future<void>.delayed(Duration.zero);

        // Two overlapping requests for the same path: expand (request A),
        // collapse, expand again (request B) — D2 sends a fresh request on
        // every expand, so this is the realistic shape of "the user tapped
        // twice before the first reply landed".
        unawaited(svc.toggleExpanded('dirA'));
        await Future<void>.delayed(Duration.zero);
        unawaited(svc.toggleExpanded('dirA'));
        await Future<void>.delayed(Duration.zero);
        unawaited(svc.toggleExpanded('dirA'));
        await Future<void>.delayed(Duration.zero);

        // B's reply (the newer request) lands first, A's (older) second.
        t.emit('file:tree:children', {
          'listings': [
            {
              'path': 'dirA',
              'children': [_file('b.txt', 'dirA/b.txt')],
            },
          ],
          'seq': 10,
        });
        await Future<void>.delayed(Duration.zero);
        t.emit('file:tree:children', {
          'listings': [
            {
              'path': 'dirA',
              'children': [_file('a.txt', 'dirA/a.txt')],
            },
          ],
          'seq': 5,
        });
        await Future<void>.delayed(Duration.zero);

        final dirA = svc.currentState.root!.children.firstWhere(
          (c) => c.path == 'dirA',
        );
        expect(dirA.children.map((c) => c.path), ['dirA/b.txt']);

        await svc.dispose();
        await session.close();
      },
    );

    // The bridge's revision counter is per-agent-PROCESS and restarts at
    // zero, while this service outlives the restart. Judging the new
    // process's listings against the dead one's watermark drops every one of
    // them, and the tree on screen never moves again.
    test('a restarted agent\'s lower-seq listings are still applied', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = FileService.fromSession(session)
        ..activate()
        ..setTreeInterest('files-test', true);
      await Future<void>.delayed(Duration.zero);

      _emitRootTree(t, {
        'tree': _rootNode(
          children: [
            {'name': 'dirA', 'path': 'dirA', 'type': 'directory'},
          ],
        ),
        'seq': 900,
      });
      await Future<void>.delayed(Duration.zero);
      await svc.toggleExpanded('dirA');
      t.emit('file:tree:children', {
        'listings': [
          {
            'path': 'dirA',
            'children': [_file('old.txt', 'dirA/old.txt')],
          },
        ],
        'seq': 901,
      });
      await Future<void>.delayed(Duration.zero);

      // The agent process restarts; the app reconnects on a new epoch and
      // the replacement counts from zero.
      t.redriveHydrators();
      await Future<void>.delayed(Duration.zero);
      expect(_treeRequests(t).last.containsKey('sinceSeq'), isFalse);

      t.emit('file:tree:children', {
        'listings': [
          {
            'path': '',
            'children': [
              {'name': 'dirA', 'path': 'dirA', 'type': 'directory'},
              {'name': 'dirB', 'path': 'dirB', 'type': 'directory'},
            ],
          },
        ],
        'seq': 3,
      });
      t.emit('file:tree:children', {
        'listings': [
          {
            'path': 'dirA',
            'children': [_file('new.txt', 'dirA/new.txt')],
          },
        ],
        'seq': 4,
      });
      await Future<void>.delayed(Duration.zero);

      final root = svc.currentState.root!;
      expect(root.children.map((c) => c.path), ['dirA', 'dirB']);
      final dirA = root.children.firstWhere((c) => c.path == 'dirA');
      expect(dirA.children.map((c) => c.path), ['dirA/new.txt']);
      expect(dirA.childrenLoading, isFalse);
      // The dead process's claim must not survive either, or the bridge
      // answers `file:tree:unchanged` once the new one counts back up to it.
      expect(_treeRequests(t).last.containsKey('sinceSeq'), isFalse);
      t.redriveHydrators();
      await Future<void>.delayed(Duration.zero);
      expect(_treeRequests(t).last.containsKey('sinceSeq'), isFalse);

      await svc.dispose();
      await session.close();
    });

    // A depth-1 listing names a subdirectory without recursing into it, so
    // installing the wire node bare would discard everything already loaded
    // beneath it — and nothing re-asks: the row stays expanded, empty and
    // without a spinner, indistinguishable from a genuinely empty folder.
    test('re-listing a parent keeps an expanded descendant loaded', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = FileService.fromSession(session);

      t.emit('file:tree:children', {
        'listings': [
          {
            'path': '',
            'children': [
              {'name': 'dirA', 'path': 'dirA', 'type': 'directory'},
            ],
          },
        ],
        'seq': 1,
      });
      await Future<void>.delayed(Duration.zero);
      await svc.toggleExpanded('dirA');
      t.emit('file:tree:children', {
        'listings': [
          {
            'path': 'dirA',
            'children': [
              {'name': 'sub', 'path': 'dirA/sub', 'type': 'directory'},
            ],
          },
        ],
        'seq': 2,
      });
      await Future<void>.delayed(Duration.zero);
      await svc.toggleExpanded('dirA/sub');
      t.emit('file:tree:children', {
        'listings': [
          {
            'path': 'dirA/sub',
            'children': [_file('deep.txt', 'dirA/sub/deep.txt')],
          },
        ],
        'seq': 3,
      });
      await Future<void>.delayed(Duration.zero);

      // The refresh gesture: collapse dirA and re-expand it.
      await svc.toggleExpanded('dirA');
      await svc.toggleExpanded('dirA');
      t.emit('file:tree:children', {
        'listings': [
          {
            'path': 'dirA',
            'children': [
              {'name': 'sub', 'path': 'dirA/sub', 'type': 'directory'},
            ],
          },
        ],
        'seq': 4,
      });
      await Future<void>.delayed(Duration.zero);

      final sub = svc.currentState.root!.children
          .firstWhere((c) => c.path == 'dirA')
          .children
          .firstWhere((c) => c.path == 'dirA/sub');
      expect(sub.childrenLoaded, isTrue);
      expect(sub.children.map((c) => c.path), ['dirA/sub/deep.txt']);

      // And the same for a root pull, which rebuilds the whole top level.
      t.emit('file:tree:children', {
        'listings': [
          {
            'path': '',
            'children': [
              {'name': 'dirA', 'path': 'dirA', 'type': 'directory'},
            ],
          },
        ],
        'seq': 5,
      });
      await Future<void>.delayed(Duration.zero);
      final subAfterRootPull = svc.currentState.root!.children
          .firstWhere((c) => c.path == 'dirA')
          .children
          .firstWhere((c) => c.path == 'dirA/sub');
      expect(subAfterRootPull.children, hasLength(1));

      await svc.dispose();
      await session.close();
    });

    // A listing can only be placed under a parent already on the spine, so
    // one frame carrying both must be applied parents-first whatever order
    // it arrived in.
    test('listings are applied shallowest-first within a frame', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = FileService.fromSession(session);

      t.emit('file:tree:children', {
        'listings': [
          {
            'path': 'dirA/sub',
            'children': [_file('deep.txt', 'dirA/sub/deep.txt')],
          },
          {
            'path': 'dirA',
            'children': [
              {'name': 'sub', 'path': 'dirA/sub', 'type': 'directory'},
            ],
          },
          {
            'path': '',
            'children': [
              {'name': 'dirA', 'path': 'dirA', 'type': 'directory'},
            ],
          },
        ],
        'seq': 7,
      });
      await Future<void>.delayed(Duration.zero);

      final sub = svc.currentState.root!.children
          .firstWhere((c) => c.path == 'dirA')
          .children
          .firstWhere((c) => c.path == 'dirA/sub');
      expect(sub.children.map((c) => c.path), ['dirA/sub/deep.txt']);

      await svc.dispose();
      await session.close();
    });

    // `missing` on a subdirectory folds into an empty, loaded listing so a
    // deleted folder stops spinning. At the ROOT the same frame means the
    // bridge could not answer at all — the FileWatcher is not up yet — and
    // applying it would erase the tree with nothing left to retry from.
    test('a missing root listing leaves the tree standing', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = FileService.fromSession(session)
        ..activate()
        ..setTreeInterest('files-test', true);
      await Future<void>.delayed(Duration.zero);

      // The first pull of a session, where no seq gate stands behind this.
      t.emit('file:tree:children', {
        'listings': [
          {'path': '', 'children': <Map<String, dynamic>>[], 'missing': true},
        ],
        'seq': 0,
      });
      await Future<void>.delayed(Duration.zero);
      expect(svc.currentState.root, isNull);

      _emitRootTree(t, {
        'tree': _rootNode(children: [_file('a.txt', 'a.txt')]),
        'seq': 5,
      });
      await Future<void>.delayed(Duration.zero);
      expect(svc.currentState.root!.children, hasLength(1));

      t.emit('file:tree:children', {
        'listings': [
          {'path': '', 'children': <Map<String, dynamic>>[], 'missing': true},
        ],
        'seq': 6,
      });
      await Future<void>.delayed(Duration.zero);
      expect(svc.currentState.root!.children, hasLength(1));
      // The non-answer must not move the claim either.
      expect(_treeRequests(t).last['sinceSeq'], isNot(6));

      await svc.dispose();
      await session.close();
    });

    // The watcher emits `children: []` for a directory event without ever
    // reading the directory, and on Windows and macOS a file write raises
    // one for the parent — so trusting it as a listing blanks whatever is
    // expanded there.
    test('a tree:update directory entry does not blank a loaded folder', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = FileService.fromSession(session);

      t.emit('file:tree:children', {
        'listings': [
          {
            'path': '',
            'children': [
              {'name': 'src', 'path': 'src', 'type': 'directory'},
            ],
          },
        ],
        'seq': 1,
      });
      await Future<void>.delayed(Duration.zero);
      await svc.toggleExpanded('src');
      t.emit('file:tree:children', {
        'listings': [
          {
            'path': 'src',
            'children': [
              _file('one.ts', 'src/one.ts'),
              _file('two.ts', 'src/two.ts'),
            ],
          },
        ],
        'seq': 2,
      });
      await Future<void>.delayed(Duration.zero);

      t.emitJson({
        'id': 'u-dir',
        'timestamp': 0,
        'type': 'tree:update',
        'projectId': 'p',
        'seq': 3,
        'added': [
          {
            'name': 'src',
            'path': 'src',
            'type': 'directory',
            'children': <Map<String, dynamic>>[],
          },
          _file('foo.ts', 'src/foo.ts'),
        ],
        'modified': const <Map<String, dynamic>>[],
        'removed': const <String>[],
      });
      await Future<void>.delayed(Duration.zero);

      final src = svc.currentState.root!.children.firstWhere(
        (c) => c.path == 'src',
      );
      expect(src.childrenLoaded, isTrue);
      expect(src.children.map((c) => c.path), [
        'src/foo.ts',
        'src/one.ts',
        'src/two.ts',
      ]);

      await svc.dispose();
      await session.close();
    });

    // The loading row is the only thing that tells an unlisted directory
    // apart from an empty one, and the restore path is where a user is most
    // likely to be staring at one.
    test('every fetch path marks its directories pending', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = FileService.fromSession(session)
        ..activate()
        ..setTreeInterest('files-test', true);
      await Future<void>.delayed(Duration.zero);

      t.emit('file:tree:children', {
        'listings': [
          {
            'path': '',
            'children': [
              {'name': 'dirA', 'path': 'dirA', 'type': 'directory'},
            ],
          },
        ],
        'seq': 1,
      });
      await Future<void>.delayed(Duration.zero);

      svc.applyPreferences(
        ProjectPreferences(expandedPaths: <String>{'dirA'}),
      );
      await Future<void>.delayed(Duration.zero);

      expect(
        svc.currentState.root!.children.single.childrenLoading,
        isTrue,
      );

      await svc.dispose();
      await session.close();
    });

    test('restoring 100 expanded paths issues 2 requests, not 100', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = FileService.fromSession(session)
        ..activate()
        ..setTreeInterest('files-test', true);
      await Future<void>.delayed(Duration.zero);
      t.clearSent();

      final hundred = List.generate(100, (i) => 'dir$i');
      svc.applyPreferences(ProjectPreferences(expandedPaths: hundred.toSet()));
      await Future<void>.delayed(Duration.zero);

      final requests = t.sent.where(
        (m) => m['type'] == 'file:tree:children:request',
      );
      expect(requests, hasLength(2));

      await svc.dispose();
      await session.close();
    });
  });

  test('fresh tree:update applied after snapshot', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = FileService.fromSession(session);

    _emitRootTree(t, {
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

    _emitRootTree(t, {
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

  // Neither result asks for the list back: the agent follows every pop and
  // drop with a fresh `git:stash-list-result` on BOTH outcomes, so a request
  // from here is a second round trip for a list already on the wire.
  test(
    'git:stash-pop-result failure surfaces gitOpFeedback without re-asking',
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
      expect(t.sent.where((m) => m['type'] == 'git:stash-list'), isEmpty);

      await svc.dispose();
      await session.close();
    },
  );

  test(
    'git:stash-drop-result success stays silent and re-asks nothing',
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
      expect(t.sent.where((m) => m['type'] == 'git:stash-list'), isEmpty);

      await svc.dispose();
      await session.close();
    },
  );

  // A one-way claim spent by a build whose send never runs hides the banner for
  // the service's whole life, so `loadStashes` also registers a hydrator: the
  // list has to survive a reconnect, and nothing else ever re-reads it.
  test('loadStashes re-asks on every re-establish', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = FileService.fromSession(session);

    svc.loadStashes();
    await Future<void>.delayed(Duration.zero);
    expect(t.sent.where((m) => m['type'] == 'git:stash-list'), hasLength(1));

    t.redriveHydrators();
    await Future<void>.delayed(Duration.zero);
    expect(
      t.sent.where((m) => m['type'] == 'git:stash-list').length,
      greaterThan(1),
    );

    await svc.dispose();
    await session.close();
  });

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

  test(
    'selectFile expands every ancestor so the tree reveals the file',
    () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = FileService.fromSession(session);

      svc.selectFile('src/widgets/deep/nested_file.dart');

      expect(
        svc.currentState.expandedPaths,
        containsAll(<String>['src', 'src/widgets', 'src/widgets/deep']),
      );
      expect(
        svc.currentState.expandedPaths,
        isNot(contains('src/widgets/deep/nested_file.dart')),
      );

      await svc.dispose();
      await session.close();
    },
  );

  test('selectFile on a top-level file expands nothing', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = FileService.fromSession(session);

    svc.selectFile('README.md');

    expect(svc.currentState.expandedPaths, isEmpty);

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
    // before the session list that makes the app build the bundle. The push
    // itself is now ignored (see _handleTreeFull's TODO), so a bundle built
    // afterward has to pull its own tree rather than rely on it.
    test('a bundle built after the push pulls its own tree', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      t.emit('tree:full', {
        'projectId': 'p',
        'checkoutId': 'wt-1',
        'root': _rootNode(children: [_file('a.txt', 'a.txt')]),
      });
      await Future<void>.delayed(Duration.zero);

      final svc = FileService.fromSession(session, checkoutId: 'wt-1')
        ..activate()
        ..setTreeInterest('files-test', true);
      await Future<void>.delayed(Duration.zero);
      final request = t.sent.lastWhere(
        (m) => m['type'] == 'file:tree:root:request',
      );
      expect(request['checkoutId'], 'wt-1');

      _emitRootTree(t, {
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
      final svc = FileService.fromSession(session, checkoutId: 'wt-1')
        ..activate()
        ..setTreeInterest('files-test', true);
      await Future<void>.delayed(Duration.zero);

      t.redriveHydrators();
      await Future<void>.delayed(Duration.zero);
      var requests = t.sent.where(
        (m) =>
            m['type'] == 'file:tree:root:request' &&
            m['checkoutId'] == 'wt-1',
      );
      expect(requests, hasLength(2));

      await svc.dispose();
      t.redriveHydrators();
      await Future<void>.delayed(Duration.zero);
      requests = t.sent.where(
        (m) =>
            m['type'] == 'file:tree:root:request' &&
            m['checkoutId'] == 'wt-1',
      );
      expect(requests, hasLength(2));

      await session.close();
    });
  });

  // Backgrounding declares focus for EVERY open project, and every checkout of
  // each re-pulls on the resume edge — so on an idle project the answer used to
  // be a byte-identical tree per checkout, per app switch.
  group('focus-resume re-pull names the revision it holds', () {
    Future<void> resume(ProjectSession session) async {
      session.setLifecyclePaused(true);
      await Future<void>.delayed(Duration.zero);
      session.setLifecyclePaused(false);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
    }

    test(
      'a resume claims the snapshot seq; a hydrator run claims none',
      () async {
        final t = FakeAgentTransport();
        final session = await _newSession(t);
        final svc = FileService.fromSession(session)
          ..activate()
          ..setTreeInterest('files-test', true);
        await Future<void>.delayed(Duration.zero);
        expect(_treeRequests(t).last.containsKey('sinceSeq'), isFalse);

        _emitRootTree(t, {
          'tree': _rootNode(children: [_file('a.txt', 'a.txt')]),
          'seq': 5,
        });
        await Future<void>.delayed(Duration.zero);

        await resume(session);
        expect(_treeRequests(t).last['sinceSeq'], 5);

        // A hydrator run means the transport re-established, and the agent behind
        // it may be a new process counting from zero — a claim there could be
        // confirmed by coincidence against a tree this app no longer holds.
        t.redriveHydrators();
        await Future<void>.delayed(Duration.zero);
        expect(_treeRequests(t).last.containsKey('sinceSeq'), isFalse);

        await svc.dispose();
        await session.close();
      },
    );

    // Activation follows the focused checkout, so a user moving between two
    // sessions in one project deactivates and re-activates these bundles
    // constantly. The transport never dropped, so the agent is the same one
    // that issued the seq and the claim still holds — without this every switch
    // bought a full tree.
    test('re-activating on the same establishment claims the seq', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = FileService.fromSession(session)
        ..activate()
        ..setTreeInterest('files-test', true);
      await Future<void>.delayed(Duration.zero);

      _emitRootTree(t, {
        'tree': _rootNode(children: [_file('a.txt', 'a.txt')]),
        'seq': 5,
      });
      await Future<void>.delayed(Duration.zero);

      svc.setTreeInterest('files-test', false);
      svc.deactivate();
      svc.activate();
      svc.setTreeInterest('files-test', true);
      await Future<void>.delayed(Duration.zero);
      expect(_treeRequests(t).last['sinceSeq'], 5);

      await svc.dispose();
      await session.close();
    });

    // The other half: a checkout that was off screen through a reconnect has no
    // comparable claim, because the agent it would be claiming against may be a
    // different process counting from zero.
    test('re-activating after a reconnect claims nothing', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = FileService.fromSession(session)
        ..activate()
        ..setTreeInterest('files-test', true);
      await Future<void>.delayed(Duration.zero);

      _emitRootTree(t, {
        'tree': _rootNode(children: [_file('a.txt', 'a.txt')]),
        'seq': 5,
      });
      await Future<void>.delayed(Duration.zero);

      svc.setTreeInterest('files-test', false);
      svc.deactivate();
      t.redriveHydrators();
      await Future<void>.delayed(Duration.zero);
      svc.activate();
      svc.setTreeInterest('files-test', true);
      await Future<void>.delayed(Duration.zero);
      expect(_treeRequests(t).last.containsKey('sinceSeq'), isFalse);

      await svc.dispose();
      await session.close();
    });

    // Pull-to-refresh is the user saying the tree on screen is wrong. Answering
    // `file:tree:unchanged` would make that gesture do visibly nothing.
    test('requestFullTree claims nothing', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = FileService.fromSession(session)
        ..activate()
        ..setTreeInterest('files-test', true);
      await Future<void>.delayed(Duration.zero);

      _emitRootTree(t, {
        'tree': _rootNode(children: [_file('a.txt', 'a.txt')]),
        'seq': 5,
      });
      await Future<void>.delayed(Duration.zero);

      svc.requestFullTree();
      await Future<void>.delayed(Duration.zero);
      expect(_treeRequests(t).last.containsKey('sinceSeq'), isFalse);

      await svc.dispose();
      await session.close();
    });

    test('file:tree:unchanged keeps both the tree and the claim', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = FileService.fromSession(session)
        ..activate()
        ..setTreeInterest('files-test', true);

      _emitRootTree(t, {
        'tree': _rootNode(children: [_file('a.txt', 'a.txt')]),
        'seq': 5,
      });
      await Future<void>.delayed(Duration.zero);

      await resume(session);
      t.emit('file:tree:unchanged', {'seq': 5});
      await Future<void>.delayed(Duration.zero);

      expect(svc.currentState.root!.children.single.path, 'a.txt');
      await resume(session);
      expect(_treeRequests(t).last['sinceSeq'], 5);

      await svc.dispose();
      await session.close();
    });

    test('only a contiguous tree:update advances the claim', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = FileService.fromSession(session)
        ..activate()
        ..setTreeInterest('files-test', true);

      _emitRootTree(t, {
        'tree': _rootNode(children: [_file('a.txt', 'a.txt')]),
        'seq': 5,
      });
      await Future<void>.delayed(Duration.zero);

      void update(int seq, String name) => t.emitJson({
        'id': 'u$seq',
        'timestamp': 0,
        'type': 'tree:update',
        'projectId': 'p',
        'seq': seq,
        'added': [_file(name, name)],
        'modified': const <Map<String, dynamic>>[],
        'removed': const <String>[],
      });

      update(6, 'b.txt');
      await Future<void>.delayed(Duration.zero);
      await resume(session);
      expect(_treeRequests(t).last['sinceSeq'], 6);

      // A gap is the agent having suppressed and DROPPED updates while this app
      // was backgrounded: the tree here is missing whatever those carried, so
      // the claim must stay behind and buy a full tree on the next resume.
      update(9, 'c.txt');
      await Future<void>.delayed(Duration.zero);
      await resume(session);
      expect(_treeRequests(t).last['sinceSeq'], isNull);

      await svc.dispose();
      await session.close();
    });

    test(
      'a forced tree:full push moves neither the tree nor the claim',
      () async {
        final t = FakeAgentTransport();
        final session = await _newSession(t);
        final svc = FileService.fromSession(session)
          ..activate()
          ..setTreeInterest('files-test', true);

        _emitRootTree(t, {
          'tree': _rootNode(children: [_file('a.txt', 'a.txt')]),
          'seq': 5,
        });
        await Future<void>.delayed(Duration.zero);

        t.emit('tree:full', {
          'projectId': 'p',
          'seq': 11,
          'root': _rootNode(children: [_file('b.txt', 'b.txt')]),
        });
        await Future<void>.delayed(Duration.zero);

        expect(
          svc.currentState.root!.children.any((c) => c.path == 'b.txt'),
          isFalse,
        );

        await resume(session);
        expect(_treeRequests(t).last['sinceSeq'], 5);

        await svc.dispose();
        await session.close();
      },
    );
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
      expect(svc.currentState.git.history.commits.map((c) => c.subject), [
        'first',
        'second',
      ]);
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
            {'path': 'a.txt', 'status': 'M', 'additions': 3, 'deletions': 1},
          ],
        });
        await Future<void>.delayed(Duration.zero);
        expect(svc.currentState.git.history.filesBySha['sha1'], hasLength(1));

        // Collapse, then re-expand: the cache means no second fetch.
        svc.toggleCommitExpanded('sha1');
        expect(svc.currentState.git.history.expandedShas, isEmpty);
        svc.toggleCommitExpanded('sha1');
        expect(svc.currentState.git.history.expandedShas, {'sha1'});
        expect(
          t.sent.where((m) => m['type'] == 'git:commit-files'),
          hasLength(1),
        );

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
