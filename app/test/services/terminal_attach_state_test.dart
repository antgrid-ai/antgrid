// Terminal attach state is derived exclusively from the frame subscription
// lifecycle. These tests deliberately contain no raw-output or snapshot path:
// an unsupported bridge must fail the subscription and require an upgrade.

import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/models/terminal_models.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/services/terminal_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import '../helpers/prefs_test_mock.dart';

const _attachBound = Duration(milliseconds: 30);
const _checkoutBound = Duration(milliseconds: 30);
const _pastBound = Duration(milliseconds: 120);
const _unreachedBound = Duration(seconds: 30);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(useInMemoryPrefs);

  Future<ProjectSession> newSession(FakeAgentTransport transport) async {
    final cache = await CachedSessionsStore.open();
    return ProjectSession(
      projectId: 'p',
      transport: transport,
      mode: ProjectSessionMode.local,
      cachedSessionsStore: cache,
      onClose: transport.dispose,
    );
  }

  TerminalService newService(
    ProjectSession session, {
    Duration snapshotAttachTimeout = _unreachedBound,
    Duration checkoutAttachTimeout = _unreachedBound,
  }) =>
      TerminalService.fromSession(
          session,
          snapshotAttachTimeout: snapshotAttachTimeout,
          checkoutAttachTimeout: checkoutAttachTimeout,
        )
        ..activate()
        ..setDisplayInterest('pane', 'a');

  Map<String, dynamic> terminalInfo(String id, {bool running = true}) => {
    'id': id,
    'terminalId': id,
    'name': id,
    'running': running,
  };

  void emitStatus(
    FakeAgentTransport transport,
    List<Map<String, dynamic>> terminals,
  ) {
    transport.emit('agent:status', {'projectId': 'p', 'terminals': terminals});
  }

  Map<String, dynamic> lastSubscribe(
    FakeAgentTransport transport,
    String terminalId,
  ) => transport.sent.lastWhere(
    (message) =>
        message['type'] == 'terminal:subscribe' &&
        message['terminalId'] == terminalId,
  );

  void acceptSubscribe(
    FakeAgentTransport transport,
    String terminalId, {
    String runId = 'run-1',
    String attachmentId = 'attachment-1',
  }) {
    transport.emit('terminal:subscribed', {
      'terminalId': terminalId,
      'requestId': lastSubscribe(transport, terminalId)['requestId'],
      'runId': runId,
      'attachmentId': attachmentId,
      'version': kTerminalFrameProtocolVersion,
    });
  }

  void emitFrame(
    FakeAgentTransport transport,
    String terminalId, {
    String runId = 'run-1',
    String attachmentId = 'attachment-1',
    int sequence = 1,
    String ansi = 'SCREEN',
  }) {
    transport.emit('terminal:frame', {
      'terminalId': terminalId,
      'runId': runId,
      'attachmentId': attachmentId,
      'sequence': sequence,
      'version': kTerminalFrameProtocolVersion,
      'revision': sequence,
      'cols': 80,
      'rows': 24,
      'ansi': ansi,
      'syncTimedOut': false,
      'history': {
        'epoch': 1,
        'firstRowId': 0,
        'nextRowId': 0,
        'status': 'recording',
      },
    });
  }

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  TerminalAttachStage stageOf(TerminalService service, String terminalId) =>
      service.currentState.hydration[terminalId]!.stage;

  int subscribeCount(FakeAgentTransport transport, String terminalId) =>
      transport.sent
          .where(
            (message) =>
                message['type'] == 'terminal:subscribe' &&
                message['terminalId'] == terminalId,
          )
          .length;

  test('a discovered terminal waits for an independent frame', () async {
    final transport = FakeAgentTransport();
    final session = await newSession(transport);
    final service = newService(session);

    emitStatus(transport, [terminalInfo('a')]);
    await settle();

    expect(stageOf(service, 'a'), TerminalAttachStage.awaitingScreen);
    expect(service.currentState.hydration['a']!.requestedAtMs, isNotNull);
    expect(service.currentState.attach, CheckoutAttachStatus.attaching);

    acceptSubscribe(transport, 'a');
    emitFrame(transport, 'a');
    await settle();

    expect(stageOf(service, 'a'), TerminalAttachStage.painted);
    expect(service.currentState.attach, CheckoutAttachStatus.ready);

    await service.dispose();
    await session.close();
  });

  test('a re-subscribe preserves a painted screen as refreshing', () async {
    final transport = FakeAgentTransport();
    final session = await newSession(transport);
    final service = newService(session);

    emitStatus(transport, [terminalInfo('a')]);
    await settle();
    acceptSubscribe(transport, 'a');
    emitFrame(transport, 'a');
    await settle();

    service.retryAttach('a');
    await settle();

    expect(stageOf(service, 'a'), TerminalAttachStage.refreshing);
    expect(service.currentState.attach, CheckoutAttachStatus.ready);

    await service.dispose();
    await session.close();
  });

  test(
    'an unanswered subscription fails and retry sends one fresh subscribe',
    () async {
      final transport = FakeAgentTransport();
      final session = await newSession(transport);
      final service = newService(session, snapshotAttachTimeout: _attachBound);

      emitStatus(transport, [terminalInfo('a')]);
      await settle();
      await Future<void>.delayed(_pastBound);

      expect(stageOf(service, 'a'), TerminalAttachStage.failed);
      final before = subscribeCount(transport, 'a');

      service.retryAttach('a');
      await settle();

      expect(subscribeCount(transport, 'a'), before + 1);
      expect(stageOf(service, 'a'), TerminalAttachStage.awaitingScreen);
      expect(
        transport.requests.where(
          (request) => request.method == 'terminal.snapshot',
        ),
        isEmpty,
      );

      await service.dispose();
      await session.close();
    },
  );

  test('one failed terminal does not condemn the checkout', () async {
    final transport = FakeAgentTransport();
    final session = await newSession(transport);
    final service = newService(session, snapshotAttachTimeout: _attachBound);

    service.setDisplayInterest('second pane', 'b');
    emitStatus(transport, [terminalInfo('a'), terminalInfo('b')]);
    await settle();
    acceptSubscribe(transport, 'a', attachmentId: 'attachment-a');
    emitFrame(transport, 'a', attachmentId: 'attachment-a');
    await settle();
    await Future<void>.delayed(_pastBound);

    expect(stageOf(service, 'a'), TerminalAttachStage.painted);
    expect(stageOf(service, 'b'), TerminalAttachStage.failed);
    expect(service.currentState.attach, CheckoutAttachStatus.ready);

    await service.dispose();
    await session.close();
  });

  test(
    'late agent status clears a checkout timeout, then its frame is ready',
    () async {
      final transport = FakeAgentTransport();
      final session = await newSession(transport);
      final service = newService(
        session,
        checkoutAttachTimeout: _checkoutBound,
      );
      final subscription = service.stateStream.listen((_) {});

      await Future<void>.delayed(_pastBound);
      expect(service.currentState.attach, CheckoutAttachStatus.failed);

      emitStatus(transport, [terminalInfo('a')]);
      await settle();
      expect(service.currentState.attach, CheckoutAttachStatus.attaching);

      acceptSubscribe(transport, 'a');
      emitFrame(transport, 'a');
      await settle();
      expect(service.currentState.attach, CheckoutAttachStatus.ready);

      await subscription.cancel();
      await service.dispose();
      await session.close();
    },
  );

  test(
    'retrying checkout hydration sends a fresh frame subscription',
    () async {
      final transport = FakeAgentTransport();
      final session = await newSession(transport);
      final service = newService(session);

      emitStatus(transport, [terminalInfo('a')]);
      await settle();
      final before = subscribeCount(transport, 'a');

      await service.retryCheckoutAttach();
      await settle();

      expect(subscribeCount(transport, 'a'), before + 1);

      await service.dispose();
      await session.close();
    },
  );

  test(
    'a returning watcher reopens a subscription abandoned on departure',
    () async {
      final transport = FakeAgentTransport();
      final session = await newSession(transport);
      final service = newService(session);
      final first = service.stateStream.listen((_) {});

      emitStatus(transport, [terminalInfo('a')]);
      await settle();
      service.setDisplayInterest('pane', null);
      await first.cancel();
      await settle();

      final before = subscribeCount(transport, 'a');
      service.setDisplayInterest('pane', 'a');
      final second = service.stateStream.listen((_) {});
      await settle();

      expect(subscribeCount(transport, 'a'), before + 1);
      expect(stageOf(service, 'a'), TerminalAttachStage.awaitingScreen);

      await second.cancel();
      await service.dispose();
      await session.close();
    },
  );

  test('a stale subscription cannot paint a recreated terminal', () async {
    final transport = FakeAgentTransport();
    final session = await newSession(transport);
    final service = newService(session);

    emitStatus(transport, [terminalInfo('a')]);
    await settle();
    final staleRequestId = lastSubscribe(transport, 'a')['requestId'];

    service.deleteTerminal('a');
    await settle();
    emitStatus(transport, [terminalInfo('a')]);
    await settle();

    transport.emit('terminal:subscribed', {
      'terminalId': 'a',
      'requestId': staleRequestId,
      'runId': 'stale-run',
      'attachmentId': 'stale-attachment',
      'version': kTerminalFrameProtocolVersion,
    });
    emitFrame(
      transport,
      'a',
      runId: 'stale-run',
      attachmentId: 'stale-attachment',
    );
    await settle();

    expect(stageOf(service, 'a'), TerminalAttachStage.awaitingScreen);

    await service.dispose();
    await session.close();
  });
}
