import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/models/ab_message.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import '../helpers/prefs_test_mock.dart';

void main() {
  group('ProjectSession', () {
    setUp(() {
      useInMemoryPrefs();
    });

    test('exposes status + heavyStream wired to transport', () async {
      final t = FakeAgentTransport();
      final cache = await CachedSessionsStore.open();
      final session = ProjectSession(
        projectId: 'p1',
        transport: t,
        mode: ProjectSessionMode.relay,
        cachedSessionsStore: cache,
        onClose: () async {
          await t.dispose();
        },
      );

      // Status-tier (agent:hello) updates the status notifier.
      t.emit('agent:hello', {'version': '1.0.0', 'flags': <String>[]});
      await Future<void>.delayed(Duration.zero);
      expect(session.status.value.agentHello, isNotNull);

      // FileService subscribes to heavyStream in the ctor, so one
      // client:focus-state {paused: false} is already sent.
      await Future<void>.delayed(Duration.zero);
      expect(
        t.sent.where(
          (m) => m['type'] == 'client:focus-state' && m['paused'] == false,
        ),
        hasLength(1),
      );

      // An additional subscriber doesn't re-send focus-state (broadcast stream).
      final sub = session.heavyStream.listen((_) {});
      await Future<void>.delayed(Duration.zero);
      expect(
        t.sent.where(
          (m) => m['type'] == 'client:focus-state' && m['paused'] == false,
        ),
        hasLength(1), // still only 1
      );

      await sub.cancel();
      await Future<void>.delayed(Duration.zero);
      // Cancelling the extra sub doesn't trigger paused:true because FileService
      // still holds its subscription.
      expect(
        t.sent.where(
          (m) => m['type'] == 'client:focus-state' && m['paused'] == true,
        ),
        isEmpty,
      );

      await session.close();
    });

    test('statusStream forwards status-tier messages', () async {
      final t = FakeAgentTransport();
      final cache = await CachedSessionsStore.open();
      final session = ProjectSession(
        projectId: 'p',
        transport: t,
        mode: ProjectSessionMode.local,
        cachedSessionsStore: cache,
        onClose: () async {
          await t.dispose();
        },
      );

      final received = <Map<String, dynamic>>[];
      final sub = session.statusStream.listen(received.add);

      // 'agent:status' is status-tier per project_message_classification.dart
      t.emit('agent:status', {'state': 'idle'});
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(1));
      expect(received.first['type'], 'agent:status');

      await sub.cancel();
      await session.close();
    });

    test('relay send rewrites compound projectId to bare local id', () async {
      // The relay focus id (and thus session.projectId) is the compound
      // `<deviceUuid>.<projectId>` registrationId, but the bridge keys its
      // file/git/search/command handlers by the BARE local projectId. Outbound
      // payloads must carry the bare id or the bridge drops them as "unknown
      // projectId" (file tree still shows via snapshot replay, but file:read,
      // git:diff, file:search, command:run all silently fail).
      final t = FakeAgentTransport();
      final cache = await CachedSessionsStore.open();
      final session = ProjectSession(
        projectId: '6f05eb01-3b2b-4ffc-8a49-cd58d15c57ac.eec94f238a31d009',
        transport: t,
        mode: ProjectSessionMode.relay,
        cachedSessionsStore: cache,
        onClose: () async {
          await t.dispose();
        },
      );

      await session.send(
        createAbMessage('file:read', {
          'projectId': session.projectId,
          'path': 'README.md',
        }),
      );

      final read = t.sent.firstWhere((m) => m['type'] == 'file:read');
      expect(read['projectId'], 'eec94f238a31d009');
      // The path (and other fields) pass through untouched.
      expect(read['path'], 'README.md');

      await session.close();
    });

    test('local send leaves the (already-bare) projectId untouched', () async {
      final t = FakeAgentTransport();
      final cache = await CachedSessionsStore.open();
      final session = ProjectSession(
        projectId: 'eec94f238a31d009',
        transport: t,
        mode: ProjectSessionMode.local,
        cachedSessionsStore: cache,
        onClose: () async {
          await t.dispose();
        },
      );

      await session.send(
        createAbMessage('file:read', {
          'projectId': session.projectId,
          'path': 'README.md',
        }),
      );

      final read = t.sent.firstWhere((m) => m['type'] == 'file:read');
      expect(read['projectId'], 'eec94f238a31d009');

      await session.close();
    });

    test(
      'checkout streams isolate late frames and default legacy frames to main',
      () async {
        final t = FakeAgentTransport();
        final cache = await CachedSessionsStore.open();
        final session = ProjectSession(
          projectId: 'p',
          transport: t,
          mode: ProjectSessionMode.local,
          cachedSessionsStore: cache,
          onClose: t.dispose,
        );
        final main = <Map<String, dynamic>>[];
        final isolated = <Map<String, dynamic>>[];
        final mainSub = session.checkoutHeavyStream('main').listen(main.add);
        final isolatedSub = session
            .checkoutHeavyStream('checkout-1')
            .listen(isolated.add);

        t.emit('tree:update', {
          'projectId': 'p',
          'added': [],
          'modified': [],
          'removed': [],
        });
        t.emit('tree:update', {
          'projectId': 'p',
          'checkoutId': 'checkout-1',
          'added': [],
          'modified': [],
          'removed': [],
        });
        await Future<void>.delayed(Duration.zero);

        expect(main, hasLength(1));
        expect(isolated, hasLength(1));
        expect(isolated.single['checkoutId'], 'checkout-1');
        await mainSub.cancel();
        await isolatedSub.cancel();
        await session.close();
      },
    );

    test(
      'checkout bundles are stable and stamp only checkout-variable sends',
      () async {
        final t = FakeAgentTransport();
        final cache = await CachedSessionsStore.open();
        final session = ProjectSession(
          projectId: 'p',
          transport: t,
          mode: ProjectSessionMode.local,
          cachedSessionsStore: cache,
          onClose: t.dispose,
        );
        final added = <CheckoutServices>[];
        final sub = session.checkoutServiceBundleStream.listen(added.add);
        final first = session.servicesForCheckout('checkout-1');
        final second = session.servicesForCheckout('checkout-1');
        await session.sendForCheckout(
          'checkout-1',
          createAbMessage('file:read', {'projectId': 'p', 'path': 'a.txt'}),
        );
        await session.sendForCheckout(
          'checkout-1',
          createAbMessage('ping', {}),
        );
        await Future<void>.delayed(Duration.zero);

        expect(identical(first, second), isTrue);
        expect(first.checkoutId, 'checkout-1');
        expect(added, [first]);
        expect(
          t.sent.firstWhere((m) => m['type'] == 'file:read')['checkoutId'],
          'checkout-1',
        );
        expect(
          t.sent
              .firstWhere((m) => m['type'] == 'ping')
              .containsKey('checkoutId'),
          isFalse,
        );
        await sub.cancel();
        await session.close();
      },
    );

    // The project's status is MAIN's slice of the status tier, never the whole
    // tier. An isolated session's worktree runs its own copy of antgrid.yaml —
    // same service names, its own ports, its own config validity — and folding
    // any of that in here shows, caches and persists the worktree's answer as
    // the project's own. Scoped at the stream rather than inside the notifier,
    // so it stays a plain reducer and matches every other per-checkout
    // consumer; a frame carrying no checkoutId still lands here, which is what
    // keeps `agent:hello` (about the agent, not a tree) flowing.
    test('status folds main only, and an unstamped frame counts as main', () async {
      final t = FakeAgentTransport();
      final cache = await CachedSessionsStore.open();
      final session = ProjectSession(
        projectId: 'p1',
        transport: t,
        mode: ProjectSessionMode.relay,
        cachedSessionsStore: cache,
        onClose: () async {
          await t.dispose();
        },
      );

      t.emit('agent:status', {
        'projectId': 'p1',
        'checkoutId': 'wt-abc123',
        'terminals': <Map<String, dynamic>>[],
        'services': [
          {'id': 'dev', 'name': 'dev', 'running': true, 'command': 'x'},
        ],
      });
      await Future<void>.delayed(Duration.zero);
      expect(session.status.value.services, isEmpty);

      // No checkoutId at all: the agent describes itself, not a working tree.
      t.emit('agent:hello', {'version': '1.0.0', 'flags': <String>[]});
      await Future<void>.delayed(Duration.zero);
      expect(session.status.value.agentHello, isNotNull);

      t.emit('agent:status', {
        'projectId': 'p1',
        'checkoutId': 'main',
        'terminals': <Map<String, dynamic>>[],
        'services': [
          {'id': 'dev', 'name': 'dev', 'running': true, 'command': 'x'},
        ],
      });
      await Future<void>.delayed(Duration.zero);
      expect(session.status.value.services, hasLength(1));

      await session.close();
    });

    test('close invokes onClose exactly once (idempotent)', () async {
      var closeCount = 0;
      final t = FakeAgentTransport();
      final cache = await CachedSessionsStore.open();
      final session = ProjectSession(
        projectId: 'p1',
        transport: t,
        mode: ProjectSessionMode.local,
        cachedSessionsStore: cache,
        onClose: () async {
          closeCount++;
          await t.dispose();
        },
      );
      await session.close();
      await session.close();
      expect(closeCount, 1);
      expect(session.mode, ProjectSessionMode.local);
    });
  });
}
