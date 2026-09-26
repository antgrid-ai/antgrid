// Per-project-stream RPC-timeout accounting: three consecutive timeouts on
// ONE project's own native stream reset and reopen that stream, never the
// whole link — a project riding a wedged stream is not the same failure as a
// session with a dead control plane, whose own escape is the app's
// wedge-probe ping (`kPingSilenceSeconds`/`kMaxMissedPongs`). The control
// transport counts nothing at all.
import 'dart:async';
import 'dart:convert';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

import 'support/fake_live_relay.dart';

/// Marks [pid] ready, opens it, and binds it on its own fresh native stream —
/// mirrors `establishReady` in `machine_session_project_stream_test.dart`.
Future<StreamTransport> openReady(
  FakeLiveRelay relay,
  MachineSession session,
  String pid,
) async {
  relay.injectFrame(
    encodeFromAgent(jsonEncode({'type': 'stream-ready', 'projectId': pid})),
  );
  await Future<void>.delayed(const Duration(milliseconds: 10));
  final opening = session.openProject(pid, {
    'type': 'project:start',
    'projectId': pid,
  });
  await Future<void>.delayed(const Duration(milliseconds: 10));
  relay.openedStreams
      .lastWhere((s) => s.open == ProjectStreamOpen(pid))
      .injectStreamReady(pid);
  return opening;
}

void main() {
  Future<MachineSession> establish(FakeLiveRelay relay) => establishSession(
    relay,
    handshaker: FakeHandshaker(),
    projectStartMessageBuilder: (pid) => {
      'type': 'project:start',
      'projectId': pid,
    },
  );

  test('three timeouts on project X reset only X', () async {
    final relay = FakeLiveRelay();
    final session = await establish(relay);

    final transportX = await openReady(relay, session, 'X');
    final streamX = relay.openedStreams.firstWhere(
      (s) => s.open == const ProjectStreamOpen('X'),
    );
    await openReady(relay, session, 'Y');
    final streamY = relay.openedStreams.firstWhere(
      (s) => s.open == const ProjectStreamOpen('Y'),
    );

    final terminal = transportX.openTerminalAttachment(
      requestId: 'term-1',
      checkoutId: 'main',
      subscribe: {'type': 'terminal:subscribe', 'requestId': 'term-1'},
    );
    final tunnel = transportX.openTunnelHttp(
      requestId: 'tun-1',
      checkoutId: 'main',
      head: {
        'type': 'tunnel:http-request',
        'requestId': 'tun-1',
        'method': 'GET',
        'path': '/',
        'headers': <String, String>{},
      },
      bodyLength: 0,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final terminalStream = relay.openedStreams.firstWhere(
      (s) => s.open is TerminalStreamOpen,
    );
    final tunnelStream = relay.openedStreams.firstWhere(
      (s) => s.open is TunnelHttpStreamOpen,
    );

    final events = <ProjectStreamEvent>[];
    final eventsSub = session.projectStreamEvents.listen(events.add);

    // A fourth, longer-lived RPC is still pending when the reset fires — it
    // proves `failAllPending(code: 'E_STREAM_RESET')` sweeps it.
    final longLived = transportX.request(
      'agent.noop',
      timeout: const Duration(milliseconds: 500),
    );
    final shortTimeouts = [
      transportX.request('a', timeout: const Duration(milliseconds: 10)),
      transportX.request('b', timeout: const Duration(milliseconds: 10)),
      transportX.request('c', timeout: const Duration(milliseconds: 10)),
    ];
    for (final f in shortTimeouts) {
      await expectLater(
        f,
        throwsA(
          isA<RpcException>().having((e) => e.code, 'code', 'E_TIMEOUT'),
        ),
      );
    }
    await expectLater(
      longLived,
      throwsA(
        isA<RpcException>().having((e) => e.code, 'code', 'E_STREAM_RESET'),
      ),
    );

    expect(streamX.resetCalled, isTrue);
    expect(streamY.resetCalled, isFalse);
    expect(terminalStream.resetCalled, isFalse);
    expect(tunnelStream.resetCalled, isFalse);
    // projectStreamEvents is an async broadcast stream: the close notice
    // lands a turn after the reset that queued it.
    await Future<void>.delayed(Duration.zero);
    expect(events, contains((projectId: 'X', open: false)));
    expect(
      relay.closeCalled,
      isFalse,
      reason: 'a wedged project stream resets that stream, never the link',
    );

    // The bind resync: X reopens on its own (with backoff) and re-pulls its
    // durable-state snapshot once the fresh stream binds.
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    relay.injectFrame(
      encodeFromAgent(jsonEncode({'type': 'stream-ready', 'projectId': 'X'})),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final reopenedStream = relay.openedStreams.lastWhere(
      (s) => s.open == const ProjectStreamOpen('X'),
    );
    expect(identical(reopenedStream, streamX), isFalse);
    reopenedStream.injectStreamReady('X');
    await Future<void>.delayed(const Duration(milliseconds: 20));

    bool sawSnapshotRequest(FakePeerStream s) => s.sent.any((record) {
      final m = jsonDecode(utf8.decode(record)) as Map<String, dynamic>;
      return m['type'] == 'request' && m['method'] == 'state.snapshot';
    });
    expect(sawSnapshotRequest(reopenedStream), isTrue);

    await eventsSub.cancel();
    await terminal.close();
    tunnel.cancel();
    terminalStream.end();
    tunnelStream.end();
    await session.dispose();
    await relay.closeStreams();
  });

  test('an answered RPC clears the streak', () async {
    final relay = FakeLiveRelay();
    final session = await establish(relay);
    final transportX = await openReady(relay, session, 'X');
    final streamX = relay.openedStreams.firstWhere(
      (s) => s.open == const ProjectStreamOpen('X'),
    );

    Future<void> timeOut() => expectLater(
      transportX.request('x', timeout: const Duration(milliseconds: 10)),
      throwsA(isA<RpcException>()),
    );

    await timeOut();
    await timeOut();

    final answered = transportX.request(
      'y',
      timeout: const Duration(seconds: 5),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final sentReq =
        jsonDecode(utf8.decode(streamX.sent.last)) as Map<String, dynamic>;
    streamX.injectJson({
      'type': 'response',
      'requestId': sentReq['requestId'],
      'ok': true,
      'result': <String, dynamic>{},
    });
    await answered;

    await timeOut();
    await timeOut();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(
      streamX.resetCalled,
      isFalse,
      reason: 'the answered RPC in between must clear the streak',
    );

    await session.dispose();
    await relay.closeStreams();
  });

  test('an application error clears the streak', () async {
    final relay = FakeLiveRelay();
    final session = await establish(relay);
    final transportX = await openReady(relay, session, 'X');
    final streamX = relay.openedStreams.firstWhere(
      (s) => s.open == const ProjectStreamOpen('X'),
    );

    Future<void> timeOut() => expectLater(
      transportX.request('x', timeout: const Duration(milliseconds: 10)),
      throwsA(isA<RpcException>()),
    );

    await timeOut();
    await timeOut();

    final answered = transportX.request(
      'y',
      timeout: const Duration(seconds: 5),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final sentReq =
        jsonDecode(utf8.decode(streamX.sent.last)) as Map<String, dynamic>;
    streamX.injectJson({
      'type': 'response',
      'requestId': sentReq['requestId'],
      'ok': false,
      'error': {'code': 'E_NOT_FOUND', 'message': 'not found'},
    });
    await expectLater(
      answered,
      throwsA(isA<RpcException>().having((e) => e.code, 'code', 'E_NOT_FOUND')),
    );

    await timeOut();
    await timeOut();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(
      streamX.resetCalled,
      isFalse,
      reason: 'the bridge\'s own application error still proves the stream '
          'carried a reply',
    );

    await session.dispose();
    await relay.closeStreams();
  });

  test('a late reply clears the streak', () async {
    final relay = FakeLiveRelay();
    final session = await establish(relay);
    final transportX = await openReady(relay, session, 'X');
    final streamX = relay.openedStreams.firstWhere(
      (s) => s.open == const ProjectStreamOpen('X'),
    );

    final first = transportX.request(
      'x1',
      timeout: const Duration(milliseconds: 10),
    );
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final firstSent =
        jsonDecode(utf8.decode(streamX.sent.last)) as Map<String, dynamic>;
    await expectLater(first, throwsA(isA<RpcException>()));

    await expectLater(
      transportX.request('x2', timeout: const Duration(milliseconds: 10)),
      throwsA(isA<RpcException>()),
    );

    // The first request's late reply lands as an orphan and clears the
    // streak — `StreamTransport.noteOrphanResponse`.
    streamX.injectJson({
      'type': 'response',
      'requestId': firstSent['requestId'],
      'ok': true,
      'result': <String, dynamic>{},
    });
    await Future<void>.delayed(const Duration(milliseconds: 10));

    await expectLater(
      transportX.request('x3', timeout: const Duration(milliseconds: 10)),
      throwsA(isA<RpcException>()),
    );
    await expectLater(
      transportX.request('x4', timeout: const Duration(milliseconds: 10)),
      throwsA(isA<RpcException>()),
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(streamX.resetCalled, isFalse);

    await session.dispose();
    await relay.closeStreams();
  });

  test('a timeout from an earlier binding is not counted', () async {
    final relay = FakeLiveRelay();
    final session = await establish(relay);
    final transportX = await openReady(relay, session, 'X');

    // Outlives the rebind below, so its own timeout fires under the NEW
    // binding's epoch.
    final stale = transportX.request(
      'stale',
      timeout: const Duration(milliseconds: 1500),
    );

    // A rebind with nothing to do with RPC timeouts — the bridge ending the
    // stream on its own — still bumps the epoch the same way a health reset
    // does.
    relay.openedStreams
        .firstWhere((s) => s.open == const ProjectStreamOpen('X'))
        .end();
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    relay.injectFrame(
      encodeFromAgent(jsonEncode({'type': 'stream-ready', 'projectId': 'X'})),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    relay.openedStreams
        .lastWhere((s) => s.open == const ProjectStreamOpen('X'))
        .injectStreamReady('X');
    await Future<void>.delayed(const Duration(milliseconds: 20));

    await expectLater(stale, throwsA(isA<RpcException>()));

    final newStream = relay.openedStreams
        .where((s) => s.open == const ProjectStreamOpen('X'))
        .last;
    Future<void> timeOut() => expectLater(
      transportX.request('x', timeout: const Duration(milliseconds: 10)),
      throwsA(isA<RpcException>()),
    );
    await timeOut();
    await timeOut();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(
      newStream.resetCalled,
      isFalse,
      reason: 'the stale timeout belonged to a binding this stream has since '
          'left behind',
    );

    await session.dispose();
    await relay.closeStreams();
  });

  test('repeated health resets back off', () async {
    final relay = FakeLiveRelay();
    final session = await establish(relay);
    await openReady(relay, session, 'X');

    int projectStartsSent() => relay.sent.where((f) {
      final m = jsonDecode(decodeFromPhone(f.payload));
      return m is Map && m['type'] == 'project:start' && m['projectId'] == 'X';
    }).length;

    // Measured from the reset to the reopen's `project:start`, before any
    // ready notice is injected: a session `stream-ready` for an unbound
    // project rebinds at once (`MachineSession._markReady`), which would hide
    // the backoff timer entirely.
    Future<Duration> resetAndTimeToReopen() async {
      for (var i = 0; i < 3; i++) {
        await expectLater(
          session.projectTransport('X')!.request(
            'x',
            timeout: const Duration(milliseconds: 10),
          ),
          throwsA(isA<RpcException>()),
        );
      }
      final before = projectStartsSent();
      final sw = Stopwatch()..start();
      while (projectStartsSent() == before) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      sw.stop();
      relay.injectFrame(
        encodeFromAgent(jsonEncode({'type': 'stream-ready', 'projectId': 'X'})),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      relay.openedStreams
          .lastWhere((s) => s.open == const ProjectStreamOpen('X'))
          .injectStreamReady('X');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(session.projectTransport('X')!.isEstablished, isTrue);
      return sw.elapsed;
    }

    final firstBackoff = await resetAndTimeToReopen();
    final secondBackoff = await resetAndTimeToReopen();
    expect(
      secondBackoff - firstBackoff,
      greaterThan(const Duration(milliseconds: 500)),
      reason: 'no answered RPC landed between the two resets, so the second '
          'reopen must wait longer than the first',
    );

    await session.dispose();
    await relay.closeStreams();
  });

  test('timeouts on the control transport never close the link', () async {
    final relay = FakeLiveRelay();
    final session = await establishSession(relay, handshaker: FakeHandshaker());
    final control = session.control;
    for (var i = 0; i < 5; i++) {
      await expectLater(
        control.request(
          'config:read',
          timeout: const Duration(milliseconds: 10),
        ),
        throwsA(isA<RpcException>()),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(
      relay.closeCalled,
      isFalse,
      reason: 'the control transport\'s only connection-level escape is the '
          'ping, never an RPC timeout',
    );

    await session.dispose();
    await relay.closeStreams();
  });
}
