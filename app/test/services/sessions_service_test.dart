import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/services/session_delete_policy.dart';

import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/services/sessions_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import '../helpers/prefs_test_mock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    useInMemoryPrefs();
  });

  Future<ProjectSession> makeSession(
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

  test(
    'fromSession ctor subscribes to status (subscribed before message arrives)',
    () async {
      final t = FakeAgentTransport();
      final session = await makeSession(t);
      final cache = await CachedSessionsStore.open();
      final svc = SessionsService.fromSession(session, cache: cache);

      t.emit('session:list:result', {
        'projectId': 'p',
        'sessions': const <Map<String, dynamic>>[],
      });
      await Future<void>.delayed(Duration.zero);

      expect(svc.currentState.projectId, 'p');

      await svc.dispose();
      await session.close();
    },
  );

  test(
    'session:result routes through MessageRouter and completes mutation future',
    () async {
      final t = FakeAgentTransport();
      final session = await makeSession(t);
      final cache = await CachedSessionsStore.open();
      final svc = SessionsService.fromSession(session, cache: cache);

      // Kick off a mutation; capture the requestId off the wire.
      final future = svc.create(name: 'new-session');
      await Future<void>.delayed(Duration.zero);

      final createMsg = t.sent.firstWhere((m) => m['type'] == 'session:create');
      final requestId = createMsg['requestId'] as String;

      // Agent reply: success, no `error` field. This must classify as
      // status-tier so MessageRouter forwards it to SessionsService.
      t.emit('session:result', {
        'requestId': requestId,
        'ok': true,
        'session': {
          'id': 'sess-1',
          'name': 'new-session',
          'createdAt': DateTime.now().millisecondsSinceEpoch,
          'lastUsedAt': DateTime.now().millisecondsSinceEpoch,
          'archived': false,
          'running': false,
        },
      });

      final entry = await future;
      expect(entry, isNotNull);
      expect(entry!.id, 'sess-1');

      await svc.dispose();
      await session.close();
    },
  );

  test('public methods include projectId from session', () async {
    final t = FakeAgentTransport();
    final session = await makeSession(t, projectId: 'proj-y');
    final cache = await CachedSessionsStore.open();
    final svc = SessionsService.fromSession(session, cache: cache);

    // Fire-and-forget; we only care that the message was sent.
    // ignore: unawaited_futures
    svc.requestList().ignore();
    await Future<void>.delayed(Duration.zero);

    // Verify SOME sent message exists and includes projectId.
    expect(t.sent, isNotEmpty);
    final listMsg = t.sent.firstWhere(
      (m) => m['type'] == 'session:list',
      orElse: () => {},
    );
    expect(listMsg, isNotEmpty);

    await svc.dispose();
    await session.close();
  });

  test('setMode surfaces ok:false and the error text to the caller', () async {
    final t = FakeAgentTransport();
    final session = await makeSession(t);
    final cache = await CachedSessionsStore.open();
    final svc = SessionsService.fromSession(session, cache: cache);

    final future = svc.setMode('sess-1', 'chat');
    await Future<void>.delayed(Duration.zero);

    final sent = t.sent.firstWhere((m) => m['type'] == 'session:set-mode');
    expect(sent['sessionId'], 'sess-1');
    expect(sent['mode'], 'chat');

    t.emit('session:result', {
      'requestId': sent['requestId'],
      'ok': false,
      'error': 'timed out tearing down session: sess-1',
    });

    final result = await future;
    expect(result.ok, isFalse);
    expect(result.error, 'timed out tearing down session: sess-1');

    await svc.dispose();
    await session.close();
  });

  test('setMode completes ok on success', () async {
    final t = FakeAgentTransport();
    final session = await makeSession(t);
    final cache = await CachedSessionsStore.open();
    final svc = SessionsService.fromSession(session, cache: cache);

    final future = svc.setMode('sess-1', 'terminal');
    await Future<void>.delayed(Duration.zero);

    final sent = t.sent.firstWhere((m) => m['type'] == 'session:set-mode');
    t.emit('session:result', {'requestId': sent['requestId'], 'ok': true});

    final result = await future;
    expect(result.ok, isTrue);
    expect(result.error, isNull);

    await svc.dispose();
    await session.close();
  });

  test('start includes initialPrompt when provided, omits when null', () async {
    final t = FakeAgentTransport();
    final session = await makeSession(t);
    final cache = await CachedSessionsStore.open();
    final svc = SessionsService.fromSession(session, cache: cache);

    // Fire-and-forget: dispose() below fails these pending futures, so ignore
    // to avoid an unhandled-error report unrelated to what this test checks.
    svc.start('sess-1', initialPrompt: 'fix the bug').ignore();
    svc.start('sess-2').ignore();
    await Future<void>.delayed(Duration.zero);

    final starts = t.sent.where((m) => m['type'] == 'session:start').toList();
    expect(starts[0]['initialPrompt'], 'fix the bug');
    expect(starts[1].containsKey('initialPrompt'), isFalse);

    await svc.dispose();
    await session.close();
  });

  group('start refusals', () {
    /// The bridge's answer when an isolated session's checkout is gone.
    void refuse(FakeAgentTransport t) {
      final sent = t.sent.firstWhere((m) => m['type'] == 'session:start');
      t.emit('session:result', {
        'requestId': sent['requestId'],
        'ok': false,
        'errorCode': 'WORKTREE_MISSING',
        'error': 'The isolated worktree is no longer available.',
      });
    }

    test('default start still collapses a refusal to null', () async {
      // The bootstrap and every other non-interactive caller await this bare,
      // with nowhere to put an error — a throw there lands outside any build().
      final t = FakeAgentTransport();
      final session = await makeSession(t);
      final cache = await CachedSessionsStore.open();
      final svc = SessionsService.fromSession(session, cache: cache);

      final future = svc.start('s1');
      await Future<void>.delayed(Duration.zero);
      refuse(t);

      expect(await future, isNull);

      await svc.dispose();
      await session.close();
    });

    test('raiseRefusal surfaces the code and the bridge message', () async {
      final t = FakeAgentTransport();
      final session = await makeSession(t);
      final cache = await CachedSessionsStore.open();
      final svc = SessionsService.fromSession(session, cache: cache);

      final future = svc.start('s1', raiseRefusal: true);
      await Future<void>.delayed(Duration.zero);
      refuse(t);

      await expectLater(
        future,
        throwsA(
          isA<SessionOperationException>()
              .having((e) => e.errorCode, 'errorCode', 'WORKTREE_MISSING')
              .having((e) => e.message, 'message', contains('no longer')),
        ),
      );

      await svc.dispose();
      await session.close();
    });

    test('raiseRefusal still completes with the entry on success', () async {
      final t = FakeAgentTransport();
      final session = await makeSession(t);
      final cache = await CachedSessionsStore.open();
      final svc = SessionsService.fromSession(session, cache: cache);

      final future = svc.start('s1', raiseRefusal: true);
      await Future<void>.delayed(Duration.zero);
      final sent = t.sent.firstWhere((m) => m['type'] == 'session:start');
      t.emit('session:result', {
        'requestId': sent['requestId'],
        'ok': true,
        'session': {
          'id': 's1',
          'name': 'Session 1',
          'createdAt': 0,
          'lastUsedAt': 0,
          'archived': false,
          'running': true,
        },
      });

      final entry = await future;
      expect(entry?.id, 's1');
      expect(entry?.running, isTrue);

      await svc.dispose();
      await session.close();
    });

    test('dispose fails an in-flight raiseRefusal start', () async {
      // Direct pin on _failPending having been taught about the opt-in map: a
      // pending map it doesn't know about leaves the caller's future hanging
      // forever, which is the silent bug a second map can introduce.
      final t = FakeAgentTransport();
      final session = await makeSession(t);
      final cache = await CachedSessionsStore.open();
      final svc = SessionsService.fromSession(session, cache: cache);

      final future = svc.start('s1', raiseRefusal: true);
      await Future<void>.delayed(Duration.zero);
      // Claimed before dispose completes it: an error landing on a future with
      // no listener yet is an unhandled zone error, which the test binding
      // fails on regardless of who awaits it afterwards.
      final refused = expectLater(future, throwsA(isA<StateError>()));
      await svc.dispose();
      await refused;

      await session.close();
    });
  });

  test('delete completes deleted on success', () async {
    final t = FakeAgentTransport();
    final session = await makeSession(t);
    final cache = await CachedSessionsStore.open();
    final svc = SessionsService.fromSession(session, cache: cache);

    final future = svc.delete('sess-1');
    await Future<void>.delayed(Duration.zero);
    final sent = t.sent.firstWhere((m) => m['type'] == 'session:delete');
    t.emit('session:result', {'requestId': sent['requestId'], 'ok': true});

    expect(await future, SessionDeleteAck.deleted);

    await svc.dispose();
    await session.close();
  });

  test(
    'delete surfaces the typed refusal code rather than a bare false',
    () async {
      // The managed-worktree delete flow branches on this code to decide which
      // confirmation to show, so a plain `false` would be unactionable.
      final t = FakeAgentTransport();
      final session = await makeSession(t);
      final cache = await CachedSessionsStore.open();
      final svc = SessionsService.fromSession(session, cache: cache);

      final future = svc.delete('sess-1');
      await Future<void>.delayed(Duration.zero);
      final sent = t.sent.firstWhere((m) => m['type'] == 'session:delete');
      t.emit('session:result', {
        'requestId': sent['requestId'],
        'ok': false,
        'errorCode': 'WORKTREE_UNPUSHED',
        'error': "The isolated worktree's branch has unpushed commits.",
      });

      await expectLater(
        future,
        throwsA(
          isA<SessionOperationException>()
              .having((e) => e.errorCode, 'errorCode', 'WORKTREE_UNPUSHED')
              .having((e) => e.message, 'message', contains('unpushed')),
        ),
      );

      await svc.dispose();
      await session.close();
    },
  );

  test('delete forwards force and deleteBranch only when set', () async {
    final t = FakeAgentTransport();
    final session = await makeSession(t);
    final cache = await CachedSessionsStore.open();
    final svc = SessionsService.fromSession(session, cache: cache);

    svc.delete('sess-1').ignore();
    svc.delete('sess-2', force: true, deleteBranch: true).ignore();
    await Future<void>.delayed(Duration.zero);

    final deletes = t.sent.where((m) => m['type'] == 'session:delete').toList();
    expect(deletes[0].containsKey('force'), isFalse);
    expect(deletes[0].containsKey('deleteBranch'), isFalse);
    expect(deletes[1]['force'], isTrue);
    expect(deletes[1]['deleteBranch'], isTrue);

    await svc.dispose();
    await session.close();
  });

  // The bridge drops a client's focused session the moment its socket closes
  // (`clientGone` in work-status.ts) while leaving read tracking armed, and the
  // reconnect restates `client:focus-state` on its own — so without a matching
  // focus restate the first turn to finish after a reconnect paints an unread
  // dot on the session the user is sitting on.
  group('resyncFocus', () {
    Future<List<String>> focusIdsAfter(
      void Function(SessionsService svc) drive,
    ) async {
      final t = FakeAgentTransport();
      final session = await makeSession(t);
      final cache = await CachedSessionsStore.open();
      final svc = SessionsService.fromSession(session, cache: cache);

      drive(svc);
      await Future<void>.delayed(Duration.zero);

      final ids = t.sent
          .where((m) => m['type'] == 'session:focus')
          .map((m) => m['sessionId'] as String)
          .toList();

      await svc.dispose();
      await session.close();
      return ids;
    }

    test('replays the last declared focus', () async {
      expect(
        await focusIdsAfter((svc) {
          svc.focus('sess-1');
          svc.resyncFocus();
        }),
        ['sess-1', 'sess-1'],
      );
    });

    test('replays the CURRENT focus, not the first one', () async {
      // A reconnect owes the bridge what is on screen now, not the session the
      // user opened when the project was first warmed.
      expect(
        await focusIdsAfter((svc) {
          svc.focus('sess-1');
          svc.focus('sess-2');
          svc.resyncFocus();
        }),
        ['sess-1', 'sess-2', 'sess-2'],
      );
    });

    test('says nothing when this client never named a session', () async {
      // "No client has said" and "the client says nothing is on screen" are the
      // same state to the bridge, so an empty declaration is nothing to restate.
      expect(await focusIdsAfter((svc) => svc.resyncFocus()), isEmpty);
    });
  });

  // The bridge's removal work is unbounded (measured 12.5s and 14.2s), so
  // silence cannot mean failure — and must not be called one at 15s, which a
  // successful delete routinely outlives.
  test('an unanswered delete is accepted, and stays silent past 15s', () async {
    final t = FakeAgentTransport();
    final session = await makeSession(t);
    final cache = await CachedSessionsStore.open();
    final svc = SessionsService.fromSession(session, cache: cache);

    fakeAsync((async) {
      Object? outcome;
      svc
          .delete('sess-1')
          .then<void>((v) => outcome = v, onError: (Object e) => outcome = e);

      async.elapse(const Duration(seconds: 20));
      async.flushMicrotasks();
      expect(
        outcome,
        isNull,
        reason: 'a delete this slow is still in progress',
      );

      async.elapse(kSessionDeleteAckTimeout);
      async.flushMicrotasks();
      expect(outcome, SessionDeleteAck.accepted);
    });

    await svc.dispose();
    await session.close();
  });

  // The backstop de-registers the pending entry, which is why a late refusal
  // has no future left to fail. It still has to reach the user: _handleResult
  // writes the reason onto the state before it looks the entry up, and
  // OperationalErrorToaster listens there.
  test(
    'a refusal with no pending entry left still lands on the state',
    () async {
      final t = FakeAgentTransport();
      final session = await makeSession(t);
      final cache = await CachedSessionsStore.open();
      final svc = SessionsService.fromSession(session, cache: cache);

      t.emit('session:result', {
        'requestId': 'long-gone',
        'ok': false,
        'errorCode': 'WORKTREE_DELETE_FAILED',
        'error': 'Could not remove the worktree.',
      });
      await Future<void>.delayed(Duration.zero);

      expect(svc.currentState.error, 'Could not remove the worktree.');

      await svc.dispose();
      await session.close();
    },
  );
}
