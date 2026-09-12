import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/terminal_models.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/services/terminal_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import '../helpers/prefs_test_mock.dart';

Future<void> tick() => Future<void>.delayed(const Duration(milliseconds: 15));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeAgentTransport transport;
  late ProjectSession session;
  late TerminalService service;

  List<Map<String, dynamic>> messages(String type) => transport.sent
      .where((message) => message['type'] == 'terminal:$type')
      .toList();

  Future<void> discover() async {
    transport.emit('agent:status', {
      'projectId': 'p',
      'terminals': [
        for (final id in ['agent', 'a', 'b'])
          {
            'terminalId': id,
            'name': id,
            'running': true,
            if (id == 'agent') 'type': 'agent',
          },
      ],
    });
    await tick();
  }

  Future<void> accept(String id, {String? request, String run = 'run'}) async {
    transport.emit('terminal:subscribed', {
      'terminalId': id,
      'runId': run,
      'attachmentId': 'att-$id',
      'version': 2,
      'requestId':
          request ??
          messages(
            'subscribe',
          ).lastWhere((m) => m['terminalId'] == id)['requestId'],
    });
    await tick();
  }

  Future<void> frame(String id, {int sequence = 1}) async {
    transport.emit('terminal:frame', {
      'terminalId': id,
      'runId': 'run',
      'attachmentId': 'att-$id',
      'version': 2,
      'sequence': sequence,
      'revision': sequence,
      'cols': 80,
      'rows': 24,
      'ansi': '\u001b[2J\u001b[H$id screen',
      'syncTimedOut': false,
      'history': {
        'epoch': 1,
        'firstRowId': 0,
        'nextRowId': 0,
        'status': 'recording',
      },
    });
    await tick();
  }

  setUp(() async {
    useInMemoryPrefs();
    transport = FakeAgentTransport();
    session = ProjectSession(
      projectId: 'p',
      transport: transport,
      mode: ProjectSessionMode.local,
      cachedSessionsStore: await CachedSessionsStore.open(),
      onClose: transport.dispose,
    );
    service = TerminalService.fromSession(
      session,
      prefetchSettleDelay: const Duration(milliseconds: 5),
      prefetchTimeout: const Duration(milliseconds: 150),
    );
    service.activate();
    await discover();
  });
  tearDown(() async {
    await service.dispose();
    await session.close();
  });

  test('discovery preserves metadata without screen demand', () {
    expect(service.currentState.tabs, hasLength(3));
    expect(messages('subscribe'), isEmpty);
    expect(service.currentState.attach, CheckoutAttachStatus.ready);
  });

  test('confirmed hidden-agent handoffs send without screen demand', () {
    expect(service.sendInput('agent', 'y\r'), isFalse);
    expect(
      service.sendToAgentTerminal('Review capture\nAttached file: /a.png'),
      isTrue,
    );
    expect(
      messages('input').single['data'],
      'Review capture\rAttached file: /a.png\r',
    );
    expect(messages('subscribe'), isEmpty);
    expect(service.canSendInput('agent'), isFalse);
  });

  test('hidden-agent handoffs refuse disconnected and exited PTYs', () async {
    transport.setEstablished(false);
    expect(service.sendToAgentTerminal('Review Git failure'), isFalse);
    transport.setEstablished(true);
    await tick();
    expect(messages('input'), isEmpty);
    transport.emit('terminal:exited', {'terminalId': 'agent', 'exitCode': 0});
    await tick();
    expect(service.sendToAgentTerminal('Review Git failure'), isFalse);
    expect(messages('input'), isEmpty);
  });

  for (final suspend in [false, true]) {
    test(
      'canceled resize invalidates geometry on ${suspend ? 'suspend' : 'hide'}',
      () async {
        service.setClientId('desktop');
        service.setDisplayInterest('pane', 'agent');
        final epoch = service.currentState.tabs['agent']!.sizeEpoch;
        expect(service.sendResize('agent', 100, 30), isTrue);
        if (suspend) {
          service.suspendDisplay();
        } else {
          service.setDisplayInterest('pane', null);
        }
        expect(service.currentState.tabs['agent']!.sizeEpoch, epoch + 1);
        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(messages('resize'), isEmpty);
        service.setDisplayInterest('pane', 'agent');
        expect(service.sendResize('agent', 100, 30), isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(messages('resize').single['cols'], 100);
        expect(messages('resize').single['rows'], 30);
      },
    );
  }

  test('hidden active terminals retain notification badges', () async {
    transport.emit('terminal:notification', {
      'terminalId': 'agent',
      'kind': 'osc9',
      'title': 'Done',
    });
    await tick();
    expect(service.currentState.tabs['agent']!.unread, isTrue);
    expect(messages('subscribe'), isEmpty);
    service.setDisplayInterest('pane', 'agent');
    await tick();
    expect(service.currentState.tabs['agent']!.unread, isFalse);
  });

  test('visible demand cancels speculation before its acceptance', () async {
    service.setPrefetchFocus('visit', {'a', 'b'});
    await tick();
    final request = messages('subscribe').single['requestId'] as String;
    service.setDisplayInterest('pane', 'agent');
    await accept('a', request: request);
    expect(messages('unsubscribe').last['terminalId'], 'a');
    expect(messages('subscribe').map((m) => m['terminalId']), ['a', 'agent']);
    await accept('agent');
    await frame('agent');
    expect(messages('subscribe').last['terminalId'], 'b');
  });

  test('known respawn invalidates the hidden screen', () async {
    service.setPrefetchFocus('visit', {'a'});
    await tick();
    await accept('a');
    await frame('a');
    expect(TerminalService.hiddenScreens.contains(service, 'a'), isTrue);
    transport.emit('terminal:started', {
      'terminalId': 'a',
      'shell': 'sh',
      'cols': 80,
      'rows': 24,
    });
    await tick();
    expect(TerminalService.hiddenScreens.contains(service, 'a'), isFalse);
    expect(messages('subscribe'), hasLength(1));
  });

  test('pane owners share an attachment until the last leaves', () async {
    service.setDisplayInterest('left', 'a');
    service.setDisplayInterest('right', 'a');
    expect(messages('subscribe'), hasLength(1));
    await accept('a');
    service.setDisplayInterest('left', null);
    expect(messages('unsubscribe'), isEmpty);
    service.setDisplayInterest('right', null);
    expect(messages('unsubscribe'), hasLength(1));
  });

  test(
    'hidden screens cannot hold visible readiness or accept input',
    () async {
      service.setDisplayInterest('pane', 'agent');
      expect(service.sendInput('agent', 'x'), isFalse);
      await accept('agent');
      expect(service.sendInput('agent', 'x'), isFalse);
      await frame('agent');
      expect(service.currentState.attach, CheckoutAttachStatus.ready);
      expect(service.sendInput('agent', 'x'), isTrue);
      expect(service.sendInput('a', 'x'), isFalse);
    },
  );

  test('prefetch is sequential and retires after its first frame', () async {
    service.setPrefetchFocus('visit', {'b', 'a'});
    await tick();
    expect(messages('subscribe').map((m) => m['terminalId']), ['a']);
    await accept('a');
    expect(messages('subscribe'), hasLength(1));
    await frame('a');
    expect(messages('ack'), hasLength(1));
    expect(messages('unsubscribe'), hasLength(1));
    expect(messages('subscribe').last['terminalId'], 'b');
    expect(service.currentState.tabs['a']!.replaceEpoch.value, 0);
    await frame('a', sequence: 2);
    expect(messages('ack'), hasLength(1));
  });

  test('canceled acceptance is explicitly unsubscribed', () async {
    service.setPrefetchFocus('visit', {'a'});
    await tick();
    final request = messages('subscribe').last['requestId'] as String;
    service.setPrefetchFocus(null, {});
    await accept('a', request: request);
    expect(messages('unsubscribe'), hasLength(1));
    await frame('a');
    expect(messages('ack'), isEmpty);
  });

  test('visible demand promotes a pending speculative attachment', () async {
    service.setPrefetchFocus('visit', {'a'});
    await tick();
    service.setDisplayInterest('pane', 'a');
    expect(messages('subscribe'), hasLength(1));
    await accept('a');
    await frame('a');
    expect(service.canSendInput('a'), isTrue);
    expect(messages('unsubscribe'), isEmpty);
  });

  test(
    'cached screen refresh gates input and does not prefetch again',
    () async {
      service.setPrefetchFocus('visit', {'a'});
      await tick();
      await accept('a');
      await frame('a');
      service.setPrefetchFocus('another visit', {'a'});
      await tick();
      expect(messages('subscribe'), hasLength(1));
      service.setDisplayInterest('pane', 'a');
      expect(
        service.currentState.tabs['a']!.replaceEpoch.value,
        greaterThan(0),
      );
      expect(service.canSendInput('a'), isFalse);
      await accept('a');
      expect(service.canSendInput('a'), isFalse);
      await frame('a');
      expect(service.canSendInput('a'), isTrue);
    },
  );

  test(
    'deadline covers acceptance and first frame and stops the visit',
    () async {
      service.setPrefetchFocus('visit', {'a', 'b'});
      await tick();
      await accept('a');
      await Future<void>.delayed(const Duration(milliseconds: 180));
      service.setPrefetchFocus('visit', {'a', 'b'});
      await tick();
      expect(messages('subscribe'), hasLength(1));
      expect(messages('unsubscribe'), hasLength(1));
      expect(service.currentState.attach, CheckoutAttachStatus.ready);
    },
  );

  test('prefetch cancellation settles a pending exit', () async {
    service.setPrefetchFocus('visit', {'a'});
    await tick();
    await accept('a');
    transport.emit('terminal:exited', {'terminalId': 'a', 'exitCode': 3});
    await tick();
    service.setPrefetchFocus(null, {});
    expect(
      service.currentState.tabs['a']!.sessionState,
      TerminalSessionState.exited,
    );
    expect(service.currentState.tabs['a']!.exitCode, 3);
  });
}
