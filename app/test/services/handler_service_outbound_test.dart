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

void main() {
  test('configure sends handler:configure with wire template + model', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);

    svc.configure(
      enabled: true,
      template: HandlerTemplate.autopilot,
      model: 'claude-sonnet-4-6',
    );

    final sent = t.sent.firstWhere((m) => m['type'] == 'handler:configure');
    expect(sent['projectId'], 'p');
    expect(sent['enabled'], true);
    expect(sent['template'], 'autopilot');
    expect(sent['model'], 'claude-sonnet-4-6');

    await svc.dispose();
    await session.close();
  });

  test('configure omits model when null', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);

    svc.configure(enabled: false, template: HandlerTemplate.watchdog);

    final sent = t.sent.firstWhere((m) => m['type'] == 'handler:configure');
    expect(sent.containsKey('model'), false);

    await svc.dispose();
    await session.close();
  });

  test('reply sends terminal:input with CR, drops the escalation, '
      'and decrements the pending count', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);
    final sub = session.heavyStream.listen((_) {});

    // Authoritative count comes from handler:status, not the escalation list.
    t.emit('handler:status', {
      'projectId': 'p', 'enabled': true, 'template': 'closer',
      'state': 'needs_you', 'pendingEscalations': 1,
    });
    t.emit('handler:escalation', {
      'projectId': 'p', 'escalationId': 'e1', 'terminalId': 't9',
      'question': 'q', 'reasoning': 'r', 'draftReply': 'use bun', 'urgency': 'normal',
    });
    await Future<void>.delayed(Duration.zero);
    expect(svc.currentState.pendingEscalations, 1);
    final esc = svc.currentState.escalations.single;

    svc.reply(esc, 'use bun');

    final sent = t.sent.firstWhere((m) => m['type'] == 'terminal:input');
    expect(sent['terminalId'], 't9');
    expect(sent['data'], 'use bun\r');
    expect(svc.currentState.escalations, isEmpty);
    expect(svc.currentState.pendingEscalations, 0); // decremented optimistically

    await sub.cancel();
    await svc.dispose();
    await session.close();
  });

  test('reply with blank text is a no-op (never sends a bare CR)', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);
    final sub = session.heavyStream.listen((_) {});

    t.emit('handler:status', {
      'projectId': 'p', 'enabled': true, 'template': 'closer',
      'state': 'needs_you', 'pendingEscalations': 1,
    });
    t.emit('handler:escalation', {
      'projectId': 'p', 'escalationId': 'e1', 'terminalId': 't9',
      'question': 'q', 'reasoning': 'r', 'draftReply': '', 'urgency': 'normal',
    });
    await Future<void>.delayed(Duration.zero);
    final esc = svc.currentState.escalations.single;

    svc.reply(esc, '   '); // whitespace-only

    expect(t.sent.any((m) => m['type'] == 'terminal:input'), false);
    // Escalation is untouched — nothing was answered.
    expect(svc.currentState.escalations, isNotEmpty);
    expect(svc.currentState.pendingEscalations, 1);

    await sub.cancel();
    await svc.dispose();
    await session.close();
  });
}
