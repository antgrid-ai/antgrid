import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';

import 'package:antgrid/models/terminal_models.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
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
  bool alternate = false,
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
    'ansi':
        '\x1b[?1049l\x1b[r\x1b[0m\x1b[3J\x1b[2J\x1b[H'
        '${alternate ? '\x1b[?1049h\x1b[2J\x1b[H' : ''}$screen',
    'syncTimedOut': false,
    'history': {
      'epoch': 1,
      'firstRowId': 0,
      'nextRowId': 0,
      'status': 'recording',
    },
  });
  await _flush();
}

void _expectNoLegacyRequests(FakeAgentTransport transport) {
  expect(
    transport.requests.where(
      (request) => request.method == 'terminal.snapshot',
    ),
    isEmpty,
  );
  expect(
    transport.sent.where(
      (message) => message['type'] == 'terminal:snapshot:request',
    ),
    isEmpty,
  );
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
    addTearDown(session.close);
    return session;
  }

  test(
    'reconnect replaces its request and releases the old attachment',
    () async {
      final t = FakeAgentTransport();
      await makeSession(t);
      await _seed(t);
      final firstRequest = _lastSubscribe(t)['requestId'];
      await _accept(t);
      await _frame(t, 'FIRST');
      t.redriveHydrators();
      await _flush();
      expect(_lastSubscribe(t)['requestId'], isNot(firstRequest));
      final released = t.sent.singleWhere(
        (message) => message['type'] == 'terminal:unsubscribe',
      );
      expect(released['runId'], 'run-1');
      expect(released['attachmentId'], 'att-1');
      _expectNoLegacyRequests(t);
    },
  );

  test(
    'a fresh attachment accepts sequence one after a high old sequence',
    () async {
      final t = FakeAgentTransport();
      final session = await makeSession(t);
      await _seed(t);
      await _accept(t);
      await _frame(t, 'OLD', sequence: 900);
      t.redriveHydrators();
      await _flush();
      await _accept(t, attachmentId: 'att-2');
      await _frame(t, 'CURRENT', attachmentId: 'att-2');
      final tab = session.terminalService.currentState.tabs['a']!;
      expect(tab.ghostty.plainText, contains('CURRENT'));
      expect(tab.ghostty.plainText, isNot(contains('OLD')));
      expect(
        t.sent.lastWhere((m) => m['type'] == 'terminal:ack')['sequence'],
        1,
      );
    },
  );

  test(
    'an unanswered reconnect retains its screen and rejects old frames',
    () async {
      final t = FakeAgentTransport();
      final session = await makeSession(t);
      await _seed(t);
      await _accept(t);
      await _frame(t, 'RETAINED');
      t.redriveHydrators();
      await _flush();
      t.clearSent();
      await _frame(t, 'STALE', sequence: 2);
      expect(
        session.terminalService.currentState.tabs['a']!.ghostty.plainText,
        contains('RETAINED'),
      );
      expect(t.sent.where((m) => m['type'] == 'terminal:ack'), isEmpty);
      _expectNoLegacyRequests(t);
    },
  );

  test(
    'late subscribed replies cannot replace the current reconnect',
    () async {
      final t = FakeAgentTransport();
      final session = await makeSession(t);
      await _seed(t);
      final oldRequest = _lastSubscribe(t)['requestId'] as String;
      t.redriveHydrators();
      await _flush();
      await _accept(t, requestId: oldRequest);
      await _frame(t, 'STALE');
      expect(
        session.terminalService.currentState.tabs['a']!.ghostty.plainText,
        isNot(contains('STALE')),
      );
      await _accept(t, attachmentId: 'att-2');
      await _frame(t, 'CURRENT', attachmentId: 'att-2');
      expect(
        session.terminalService.currentState.tabs['a']!.ghostty.plainText,
        contains('CURRENT'),
      );
    },
  );

  test(
    'same-id respawn retires geometry and rejects the previous run',
    () async {
      final t = FakeAgentTransport();
      final session = await makeSession(t);
      await _seed(t);
      await _accept(t);
      await _frame(t, 'PREVIOUS');
      final before = session.terminalService.currentState.tabs['a']!.sizeEpoch;
      t.emit('terminal:started', {
        'terminalId': 'a',
        'shell': 'bash',
        'cols': 80,
        'rows': 24,
      });
      await _flush();
      final tab = session.terminalService.currentState.tabs['a']!;
      expect(tab.cols, 80);
      expect(tab.sizeEpoch, greaterThan(before));
      await _accept(t, runId: 'run-2', attachmentId: 'att-2');
      await _frame(t, 'REBORN', runId: 'run-2', attachmentId: 'att-2');
      await _frame(t, 'STALE', sequence: 999);
      expect(tab.ghostty.plainText, contains('REBORN'));
      expect(tab.ghostty.plainText, isNot(contains('STALE')));
    },
  );

  test('repeated screens and attachments never accumulate copies', () async {
    final t = FakeAgentTransport();
    final session = await makeSession(t);
    await _seed(t);
    await _accept(t);
    final tab = session.terminalService.currentState.tabs['a']!;
    await _frame(t, 'TOP\r\nMIDDLE\r\nBOTTOM');
    final initial = tab.ghostty.plainText;
    for (var sequence = 2; sequence <= 20; sequence++) {
      await _frame(t, 'TOP\r\nMIDDLE\r\nBOTTOM', sequence: sequence);
    }
    for (var index = 2; index <= 4; index++) {
      t.redriveHydrators();
      await _flush();
      await _accept(t, attachmentId: 'att-$index');
      await _frame(t, 'TOP\r\nMIDDLE\r\nBOTTOM', attachmentId: 'att-$index');
    }
    expect(tab.ghostty.plainText, initial);
    expect('TOP'.allMatches(tab.ghostty.plainText), hasLength(1));
  });

  test(
    'normal and alternate screens remain independent after reattach',
    () async {
      final t = FakeAgentTransport();
      final session = await makeSession(t);
      await _seed(t);
      await _accept(t);
      await _frame(t, 'NORMAL');
      await _frame(t, 'FULLSCREEN', sequence: 2, alternate: true);
      final tab = session.terminalService.currentState.tabs['a']!;
      expect(tab.ghostty.plainText, contains('FULLSCREEN'));
      t.redriveHydrators();
      await _flush();
      await _accept(t, attachmentId: 'att-2');
      await _frame(t, 'AFTER', attachmentId: 'att-2');
      expect(tab.ghostty.plainText, contains('AFTER'));
      expect(tab.ghostty.plainText, isNot(contains('FULLSCREEN')));
      expect(tab.ghostty.plainText, isNot(contains('NORMAL')));
    },
  );

  test(
    'same-id terminals subscribe and paint only in their own checkout',
    () async {
      final t = FakeAgentTransport();
      final session = await makeSession(t);
      await _seed(t);
      final isolated = session.servicesForCheckout('wt-1').terminalService;
      await _seed(t, checkoutId: 'wt-1');
      expect(_lastSubscribe(t)['checkoutId'], 'main');
      expect(_lastSubscribe(t, checkoutId: 'wt-1')['checkoutId'], 'wt-1');
      await _accept(t);
      await _accept(t, checkoutId: 'wt-1', attachmentId: 'isolated');
      await _frame(t, 'MAIN');
      await _frame(t, 'ISOLATED', checkoutId: 'wt-1', attachmentId: 'isolated');
      expect(
        session.terminalService.currentState.tabs['a']!.ghostty.plainText,
        contains('MAIN'),
      );
      expect(
        isolated.currentState.tabs['a']!.ghostty.plainText,
        contains('ISOLATED'),
      );
      expect(
        isolated.currentState.tabs['a']!.ghostty.plainText,
        isNot(contains('MAIN')),
      );
    },
  );

  test(
    'unsupported peers never enable legacy fallback and can recover after upgrade',
    () async {
      final t = FakeAgentTransport();
      final session = await makeSession(t);
      await _seed(t);
      t.emit('terminal:display:status', {
        'terminalId': 'a',
        'requestId': _lastSubscribe(t)['requestId'],
        'code': 'UPGRADE_REQUIRED',
        'message': 'Upgrade the bridge',
      });
      await _flush();
      final service = session.terminalService;
      expect(
        service.currentState.hydration['a']!.stage,
        TerminalAttachStage.failed,
      );
      service.retryAttach('a');
      await _flush();
      expect(_lastSubscribe(t)['version'], kTerminalFrameProtocolVersion);
      _expectNoLegacyRequests(t);
      t.redriveHydrators();
      await _flush();
      await _accept(t, attachmentId: 'upgraded');
      await _frame(t, 'UPGRADED', attachmentId: 'upgraded');
      expect(
        service.currentState.tabs['a']!.ghostty.plainText,
        contains('UPGRADED'),
      );
      _expectNoLegacyRequests(t);
    },
  );

  test('a re-drive retires the geometry the driver booked', () async {
    final t = FakeAgentTransport();
    final session = await makeSession(t);
    await _seed(t);
    final before = session.terminalService.currentState.tabs['a']!.sizeEpoch;
    t.redriveHydrators();
    await _flush();
    expect(
      session.terminalService.currentState.tabs['a']!.sizeEpoch,
      greaterThan(before),
    );
  });
}
