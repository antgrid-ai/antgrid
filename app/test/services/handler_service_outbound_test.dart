import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/handler_state.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/services/handler_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import '../helpers/prefs_test_mock.dart';

Future<ProjectSession> _newSession(FakeAgentTransport t) async {
  useInMemoryPrefs();
  final cache = await CachedSessionsStore.open();
  return ProjectSession(
    projectId: 'p',
    transport: t,
    mode: ProjectSessionMode.local,
    cachedSessionsStore: cache,
    onClose: () async => await t.dispose(),
  );
}

const _brief = HandlerBrief(
  taskSummary: 'ship the feature',
  willHandle: ['fix lint', 'rerun tests'],
  wakeFor: ['schema change'],
  doneWhen: 'tests green',
  thenItems: ['open PR'],
);

void main() {
  test('requestPlan sends handler:planRequest', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);

    svc.requestPlan('t1');

    final sent = t.sent.firstWhere((m) => m['type'] == 'handler:planRequest');
    expect(sent['projectId'], 'p');
    expect(sent['terminalId'], 't1');

    await svc.dispose();
    await session.close();
  });

  test('requestPlan carries the judge pick when given', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);

    svc.requestPlan('t1', judgeTool: 'codex', judgeModel: 'm');

    final sent = t.sent.lastWhere((m) => m['type'] == 'handler:planRequest');
    expect(sent['judgeTool'], 'codex');
    expect(sent['judgeModel'], 'm');

    await svc.dispose();
    await session.close();
  });

  test('requestPlan omits judge keys when not given', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);

    svc.requestPlan('t1');

    final sent = t.sent.lastWhere((m) => m['type'] == 'handler:planRequest');
    expect(sent.containsKey('judgeTool'), isFalse);
    expect(sent.containsKey('judgeModel'), isFalse);

    await svc.dispose();
    await session.close();
  });

  test(
    'arm sends handler:configure with armed:true and the brief wire shape',
    () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = HandlerService.fromSession(session);

      svc.arm(terminalId: 't1', brief: _brief, notifyOnly: true);

      final sent = t.sent.firstWhere((m) => m['type'] == 'handler:configure');
      expect(sent['projectId'], 'p');
      expect(sent['terminalId'], 't1');
      expect(sent['armed'], true);
      expect(sent['notifyOnly'], true);
      expect(sent['brief'], _brief.toWire());
      // Cached immediately, without waiting for the next status round-trip.
      expect(svc.lastKnownBrief('t1'), _brief);

      await svc.dispose();
      await session.close();
    },
  );

  test('disarm sends armed:false without a brief', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);

    svc.disarm('t1');

    final sent = t.sent.firstWhere((m) => m['type'] == 'handler:configure');
    expect(sent['projectId'], 'p');
    expect(sent['terminalId'], 't1');
    expect(sent['armed'], false);
    expect(sent.containsKey('brief'), false);

    await svc.dispose();
    await session.close();
  });

  test(
    'reply still sends terminal:input with trailing CR and drops the row',
    () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = HandlerService.fromSession(session);
      final sub = session.heavyStream.listen((_) {});

      t.emit('handler:escalation', {
        'projectId': 'p',
        'escalationId': 'e1',
        'terminalId': 't9',
        'question': 'q',
        'reasoning': 'r',
        'draftReply': 'use bun',
        'urgency': 'normal',
      });
      await Future<void>.delayed(Duration.zero);
      final esc = svc.currentState.escalations.single;

      svc.reply(esc, 'use bun');

      final sent = t.sent.firstWhere((m) => m['type'] == 'terminal:input');
      expect(sent['terminalId'], 't9');
      expect(sent['data'], 'use bun\r');
      expect(svc.currentState.escalations, isEmpty);

      await sub.cancel();
      await svc.dispose();
      await session.close();
    },
  );

  test('reply with blank text is a no-op (never sends a bare CR)', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);
    final sub = session.heavyStream.listen((_) {});

    t.emit('handler:escalation', {
      'projectId': 'p',
      'escalationId': 'e1',
      'terminalId': 't9',
      'question': 'q',
      'reasoning': 'r',
      'draftReply': '',
      'urgency': 'normal',
    });
    await Future<void>.delayed(Duration.zero);
    final esc = svc.currentState.escalations.single;

    svc.reply(esc, '   '); // whitespace-only

    expect(t.sent.any((m) => m['type'] == 'terminal:input'), false);
    // Escalation is untouched — nothing was answered.
    expect(svc.currentState.escalations, isNotEmpty);

    await sub.cancel();
    await svc.dispose();
    await session.close();
  });
}
