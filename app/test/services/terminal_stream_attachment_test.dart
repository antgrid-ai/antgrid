// Pins `terminal_service.dart`'s handling of `TerminalAttachment.done`
// (the transport-agnostic end-of-attachment signal introduced for the native
// stream path) using `FakeAgentTransport.endTerminalAttachment` as the test
// seam — it drives every `TerminalAttachmentEnd` variant onto the
// socket-path attachment the fake always creates, regardless of which
// transport would actually produce it on the wire.
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';

import 'package:antgrid/models/terminal_models.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import '../helpers/prefs_test_mock.dart';

Future<void> _flush() => Future<void>.delayed(Duration.zero);

Map<String, dynamic> _lastSubscribe(
  FakeAgentTransport transport, {
  String checkoutId = 'main',
}) => transport.sent.lastWhere(
  (message) =>
      message['type'] == 'terminal:subscribe' &&
      message['terminalId'] == 'a' &&
      message['checkoutId'] == checkoutId,
);

Future<void> _seed(
  FakeAgentTransport transport, {
  String checkoutId = 'main',
}) async {
  transport.emit('agent:status', {
    'projectId': 'p',
    'checkoutId': checkoutId,
    'terminals': [
      {'terminalId': 'a', 'name': 'a', 'running': true},
    ],
  });
  await _flush();
}

Future<void> _accept(
  FakeAgentTransport transport, {
  String checkoutId = 'main',
  String runId = 'run-1',
  String attachmentId = 'att-1',
  String? requestId,
}) async {
  transport.emit('terminal:subscribed', {
    'terminalId': 'a',
    'checkoutId': checkoutId,
    'runId': runId,
    'attachmentId': attachmentId,
    'version': kTerminalFrameProtocolVersion,
    'requestId':
        requestId ??
        _lastSubscribe(transport, checkoutId: checkoutId)['requestId'],
  });
  await _flush();
}

Future<void> _frame(
  FakeAgentTransport transport,
  String screen, {
  int sequence = 1,
  String checkoutId = 'main',
  String runId = 'run-1',
  String attachmentId = 'att-1',
  int historyNextRowId = 1000,
}) async {
  transport.emit('terminal:frame', {
    'terminalId': 'a',
    'checkoutId': checkoutId,
    'runId': runId,
    'attachmentId': attachmentId,
    'version': kTerminalFrameProtocolVersion,
    'sequence': sequence,
    'revision': sequence,
    'cols': 20,
    'rows': 3,
    'ansi': '\x1b[?1049l\x1b[r\x1b[0m\x1b[3J\x1b[2J\x1b[H$screen',
    'syncTimedOut': false,
    'history': {
      'epoch': 1,
      'firstRowId': 0,
      'nextRowId': historyNextRowId,
      'status': 'recording',
    },
  });
  await _flush();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    useInMemoryPrefs();
    // Missing native assets must fail the frame reapplication release gate.
    GhosttyVt.newTerminal(cols: 8, rows: 2).close();
  });

  Future<ProjectSession> makeSession(FakeAgentTransport transport) async {
    final session = ProjectSession(
      projectId: 'p',
      transport: transport,
      mode: ProjectSessionMode.local,
      cachedSessionsStore: await CachedSessionsStore.open(),
      onClose: transport.dispose,
    )..setActiveCheckouts({'main'});
    session.terminalService.setDisplayInterest('pane', 'a');
    addTearDown(session.close);
    return session;
  }

  test(
    'PeerEnded during an ENDED drain completes the run immediately',
    () async {
      final t = FakeAgentTransport();
      final session = await makeSession(t);
      await _seed(t);
      await _accept(t);
      await _frame(t, 'BEFORE', sequence: 1);
      final requestId = _lastSubscribe(t)['requestId'] as String;

      t.emit('terminal:display:status', {
        'terminalId': 'a',
        'attachmentId': 'att-1',
        'code': 'ENDED',
        'message': 'exited',
        'finalSequence': 5,
        'exitCode': 0,
      });
      await _flush();
      // Draining: the last applied sequence (1) hasn't reached finalSequence
      // (5), so the run must not be retired on the status alone.
      expect(
        session.terminalService.currentState.hydration['a']!.stage,
        isNot(TerminalAttachStage.ended),
      );

      t.endTerminalAttachment(requestId, const TerminalAttachmentPeerEnded());
      await _flush();
      // Hazard B: the bridge's FIN is what finishes a drain nothing else will.
      expect(
        session.terminalService.currentState.hydration['a']!.stage,
        TerminalAttachStage.ended,
      );
      expect(
        session.terminalService.currentState.tabs['a']!.sessionState,
        TerminalSessionState.exited,
      );
    },
  );

  test(
    'a bare PeerEnded re-subscribes once with a fresh requestId, and not '
    'again until a frame is accepted',
    () async {
      final t = FakeAgentTransport();
      final session = await makeSession(t);
      await _seed(t);
      await _accept(t);
      await _frame(t, 'FIRST', sequence: 1);
      final requestId1 = _lastSubscribe(t)['requestId'] as String;

      t.endTerminalAttachment(requestId1, const TerminalAttachmentPeerEnded());
      await _flush();
      final requestId2 = _lastSubscribe(t)['requestId'] as String;
      expect(requestId2, isNot(requestId1));
      expect(
        t.sent.where((m) => m['type'] == 'terminal:subscribe').length,
        2,
      );

      // The fresh attachment (requestId2) is itself still unconfirmed when it
      // ends bare a second time: the peer-end always terminates it, but the
      // guard blocks the automatic resubscribe, leaving the terminal
      // unattached rather than looping.
      t.endTerminalAttachment(requestId2, const TerminalAttachmentPeerEnded());
      await _flush();
      expect(
        t.sent.where((m) => m['type'] == 'terminal:subscribe').length,
        2,
      );

      // Only an explicit reattach (never the guard) recovers it; the frame it
      // accepts is what re-arms the guard for next time.
      session.terminalService.retryAttach('a');
      await _flush();
      final requestId3 = _lastSubscribe(t)['requestId'] as String;
      expect(requestId3, isNot(requestId2));
      await _accept(t, requestId: requestId3, attachmentId: 'att-3');
      await _frame(t, 'THIRD', attachmentId: 'att-3');

      t.endTerminalAttachment(requestId3, const TerminalAttachmentPeerEnded());
      await _flush();
      final requestId4 = _lastSubscribe(t)['requestId'] as String;
      expect(requestId4, isNot(requestId3));
      expect(
        t.sent.where((m) => m['type'] == 'terminal:subscribe').length,
        4,
      );
    },
  );

  test(
    'a bare PeerEnded while the transport is not established does not '
    're-subscribe',
    () async {
      final t = FakeAgentTransport();
      final session = await makeSession(t);
      await _seed(t);
      await _accept(t);
      await _frame(t, 'FIRST', sequence: 1);
      final requestId = _lastSubscribe(t)['requestId'] as String;

      t.setEstablishedQuietly(false);
      t.endTerminalAttachment(requestId, const TerminalAttachmentPeerEnded());
      await _flush();

      expect(_lastSubscribe(t)['requestId'], requestId);
      expect(
        t.sent.where((m) => m['type'] == 'terminal:subscribe').length,
        1,
      );
      expect(
        session.terminalService.currentState.hydration['a']!.stage,
        TerminalAttachStage.painted,
      );
    },
  );

  test(
    'Refused and Failed clear the pending subscribe without re-subscribing',
    () async {
      final t = FakeAgentTransport();
      final session = await makeSession(t);
      await _seed(t);
      final requestId1 = _lastSubscribe(t)['requestId'] as String;
      expect(
        session.terminalService.currentState.hydration['a']!.stage,
        TerminalAttachStage.awaitingScreen,
      );

      t.endTerminalAttachment(
        requestId1,
        const TerminalAttachmentRefused(
          StreamRefused(code: StreamRefusedCode.notReady, message: 'x'),
        ),
      );
      await _flush();
      expect(
        t.sent.where((m) => m['type'] == 'terminal:subscribe').length,
        1,
        reason: 'a refusal must never trigger an immediate resubscribe',
      );
      expect(
        session.terminalService.currentState.hydration['a']!.stage,
        TerminalAttachStage.cold,
      );

      session.terminalService.retryAttach('a');
      await _flush();
      final requestId2 = _lastSubscribe(t)['requestId'] as String;

      t.endTerminalAttachment(
        requestId2,
        const TerminalAttachmentFailed('SEND_FAILED'),
      );
      await _flush();
      expect(
        t.sent.where((m) => m['type'] == 'terminal:subscribe').length,
        2,
        reason: 'a local failure must never trigger an immediate resubscribe',
      );
      expect(
        session.terminalService.currentState.hydration['a']!.stage,
        TerminalAttachStage.cold,
      );
    },
  );

  test(
    'ack, unsubscribe and history requests go through the attachment, '
    'stamped like sendForCheckout',
    () async {
      final t = FakeAgentTransport();
      final session = await makeSession(t);
      await _seed(t);
      await _accept(t);
      await _frame(t, 'FIRST', sequence: 1);
      t.clearSent();

      await _frame(t, 'SECOND', sequence: 2);
      final ack = t.sent.singleWhere((m) => m['type'] == 'terminal:ack');
      expect(ack['checkoutId'], 'main');
      expect(ack['runId'], 'run-1');
      expect(ack['attachmentId'], 'att-1');
      expect(ack['sequence'], 2);

      final requested = session.terminalService.requestTerminalHistoryPage(
        'a',
      );
      expect(requested, isTrue);
      await _flush();
      final history = t.sent.singleWhere(
        (m) => m['type'] == 'terminal:history:request',
      );
      expect(history['checkoutId'], 'main');
      expect(history['runId'], 'run-1');
      expect(history['attachmentId'], 'att-1');
      expect(history['beforeRowId'], 1000);

      session.terminalService.suspendDisplay();
      await _flush();
      final unsubscribe = t.sent.singleWhere(
        (m) => m['type'] == 'terminal:unsubscribe',
      );
      expect(unsubscribe['checkoutId'], 'main');
      expect(unsubscribe['runId'], 'run-1');
      expect(unsubscribe['attachmentId'], 'att-1');
    },
  );

  test(
    'on a stream attachment, ack, unsubscribe and history requests ride the '
    'attachment and never the project stream',
    () async {
      final t = FakeAgentTransport()..terminalAttachmentsAsStream = true;
      final session = await makeSession(t);
      await _seed(t);
      final subscribe = t.attachmentSent.lastWhere(
        (m) => m['type'] == 'terminal:subscribe',
      );
      expect(subscribe['checkoutId'], 'main');
      await _accept(t, requestId: subscribe['requestId'] as String);
      await _frame(t, 'FIRST', sequence: 1);
      await _frame(t, 'SECOND', sequence: 2);
      expect(
        session.terminalService.requestTerminalHistoryPage('a'),
        isTrue,
      );
      await _flush();
      session.terminalService.suspendDisplay();
      await _flush();

      final types = t.attachmentSent.map((m) => m['type']).toSet();
      expect(
        types,
        containsAll(<String>[
          'terminal:ack',
          'terminal:history:request',
          'terminal:unsubscribe',
        ]),
      );
      for (final m in t.attachmentSent) {
        expect(m['checkoutId'], 'main');
      }
      expect(
        t.sent.where(
          (m) => const {
            'terminal:subscribe',
            'terminal:ack',
            'terminal:history:request',
            'terminal:unsubscribe',
          }.contains(m['type']),
        ),
        isEmpty,
      );
    },
  );

  test('history for an ended attachment goes through sendForCheckout', () async {
    final t = FakeAgentTransport();
    final session = await makeSession(t);
    await _seed(t);
    await _accept(t);
    await _frame(t, 'FIRST', sequence: 1);
    t.clearSent();

    t.emit('terminal:display:status', {
      'terminalId': 'a',
      'attachmentId': 'att-1',
      'code': 'ENDED',
      'message': 'exited',
      'finalSequence': 1,
      'exitCode': 0,
    });
    await _flush();
    expect(
      session.terminalService.currentState.hydration['a']!.stage,
      TerminalAttachStage.ended,
    );

    final requested = session.terminalService.requestTerminalHistoryPage('a');
    expect(requested, isTrue);
    await _flush();
    final history = t.sent.singleWhere(
      (m) => m['type'] == 'terminal:history:request',
    );
    expect(history['checkoutId'], 'main');
    expect(history['runId'], 'run-1');
    expect(history['attachmentId'], 'att-1');
  });
}
