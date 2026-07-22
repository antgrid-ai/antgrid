import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/handler_state.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/services/handler_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import '../helpers/prefs_test_mock.dart';

Future<ProjectSession> _newSession(FakeAgentTransport t) async {
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
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    useInMemoryPrefs();
  });

  test('handler:status updates enabled/template/runState/count', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);

    t.emit('handler:status', {
      'projectId': 'p',
      'enabled': true,
      'template': 'closer',
      'model': 'claude-haiku-4-5',
      'state': 'watching',
      'pendingEscalations': 1,
    });
    await Future<void>.delayed(Duration.zero);

    expect(svc.currentState.enabled, true);
    expect(svc.currentState.template, HandlerTemplate.closer);
    expect(svc.currentState.runState, HandlerRunState.watching);
    expect(svc.currentState.model, 'claude-haiku-4-5');
    expect(svc.currentState.pendingEscalations, 1);

    await svc.dispose();
    await session.close();
  });

  test('handler:escalation appends, deduped by id', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);
    final sub = session.heavyStream.listen((_) {}); // unpause the heavy gate

    void emitEsc(String escId) => t.emit('handler:escalation', {
          'projectId': 'p',
          'escalationId': escId,
          'terminalId': 't1',
          'question': 'q',
          'reasoning': 'r',
          'draftReply': 'd',
          'urgency': 'normal',
        });

    emitEsc('e1');
    emitEsc('e1'); // duplicate
    emitEsc('e2');
    await Future<void>.delayed(Duration.zero);

    expect(svc.currentState.escalations.map((e) => e.escalationId), ['e1', 'e2']);
    expect(svc.currentState.latestEscalationId, 'e2');

    await sub.cancel();
    await svc.dispose();
    await session.close();
  });

  test('handler:status with pendingEscalations:0 clears stale escalations',
      () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);
    final sub = session.heavyStream.listen((_) {});

    t.emit('handler:escalation', {
      'projectId': 'p',
      'escalationId': 'e1',
      'terminalId': 't1',
      'question': 'q',
      'reasoning': 'r',
      'draftReply': 'd',
      'urgency': 'normal',
    });
    await Future<void>.delayed(Duration.zero);
    expect(svc.currentState.escalations, isNotEmpty);

    // Bridge resolved it outside the app (answered in terminal / auto-handled):
    // a 0 count must drop the stale, still-tappable row.
    t.emit('handler:status', {
      'projectId': 'p',
      'enabled': true,
      'template': 'closer',
      'state': 'watching',
      'pendingEscalations': 0,
    });
    await Future<void>.delayed(Duration.zero);

    expect(svc.currentState.escalations, isEmpty);
    expect(svc.currentState.pendingEscalations, 0);

    await sub.cancel();
    await svc.dispose();
    await session.close();
  });

  test('handler:status with non-zero count leaves the escalation list intact',
      () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);
    final sub = session.heavyStream.listen((_) {});

    t.emit('handler:escalation', {
      'projectId': 'p',
      'escalationId': 'e1',
      'terminalId': 't1',
      'question': 'q',
      'reasoning': 'r',
      'draftReply': 'd',
      'urgency': 'normal',
    });
    t.emit('handler:status', {
      'projectId': 'p',
      'enabled': true,
      'template': 'closer',
      'state': 'needs_you',
      'pendingEscalations': 2,
    });
    await Future<void>.delayed(Duration.zero);

    // Count can lead the list (an escalation not yet received); a non-zero
    // shrink/lead must not drop or pad the rows we do have.
    expect(svc.currentState.escalations.map((e) => e.escalationId), ['e1']);
    expect(svc.currentState.pendingEscalations, 2);

    await sub.cancel();
    await svc.dispose();
    await session.close();
  });

  test('escalationStream emits each new escalation once (deduped by id)',
      () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);
    final sub = session.heavyStream.listen((_) {}); // unpause the heavy gate

    final seen = <String>[];
    final escSub = svc.escalationStream.listen((e) => seen.add(e.escalationId));

    void emitEsc(String escId) => t.emit('handler:escalation', {
          'projectId': 'p',
          'escalationId': escId,
          'terminalId': 't1',
          'question': 'q',
          'reasoning': 'r',
          'draftReply': 'd',
          'urgency': 'normal',
        });

    emitEsc('e1');
    emitEsc('e1'); // duplicate — must not re-emit
    emitEsc('e2');
    await Future<void>.delayed(Duration.zero);

    expect(seen, ['e1', 'e2']);

    await escSub.cancel();
    await sub.cancel();
    await svc.dispose();
    await session.close();
  });

  test('handler:activity prepends newest-first', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);
    final sub = session.heavyStream.listen((_) {});

    t.emit('handler:activity', {
      'projectId': 'p',
      'recordId': 'r1',
      'at': 10,
      'terminalId': 't1',
      'decision': 'continue',
      'reason': 'first',
    });
    t.emit('handler:activity', {
      'projectId': 'p',
      'recordId': 'r2',
      'at': 20,
      'terminalId': 't1',
      'decision': 'handle',
      'reason': 'second',
    });
    await Future<void>.delayed(Duration.zero);

    expect(svc.currentState.activity.map((a) => a.recordId), ['r2', 'r1']);

    await sub.cancel();
    await svc.dispose();
    await session.close();
  });
}
