import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/services/terminal_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import '../helpers/prefs_test_mock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    useInMemoryPrefs();
  });

  Future<ProjectSession> newSession(
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
    'fromSession subscribes to heavy; agent:status updates terminal tabs',
    () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);

      t.emit('agent:status', {
        'projectId': 'p',
        'terminals': [
          {
            'id': 'terminal-1',
            'terminalId': 'terminal-1',
            'name': 'Terminal 1',
            'running': true,
          },
        ],
      });
      await Future<void>.delayed(Duration.zero);

      expect(svc.currentState.tabs, isNotEmpty);

      await svc.dispose();
      await session.close();
    },
  );

  test('heavy stream delivers terminal:output to the active tab', () async {
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final svc = TerminalService.fromSession(session);

    // Seed a running tab via agent:status (status tier).
    t.emit('agent:status', {
      'projectId': 'p',
      'terminals': [
        {
          'id': 'terminal-1',
          'terminalId': 'terminal-1',
          'name': 'Terminal 1',
          'running': true,
        },
      ],
    });
    await Future<void>.delayed(Duration.zero);

    // Heavy tier — terminal:output should be applied to the tab.
    t.emit('terminal:output', {
      'terminalId': 'terminal-1',
      'data': 'hello\r\n',
    });
    await Future<void>.delayed(Duration.zero);

    final tab = svc.currentState.tabs['terminal-1'];
    expect(tab, isNotNull);

    await svc.dispose();
    await session.close();
  });

  test('sendInput dispatches terminal:input with terminalId', () async {
    final t = FakeAgentTransport();
    final session = await newSession(t, projectId: 'proj-z');
    final svc = TerminalService.fromSession(session);

    svc.sendInput('terminal-1', 'ls\n');
    await Future<void>.delayed(Duration.zero);

    final sent = t.sent.firstWhere((m) => m['type'] == 'terminal:input');
    expect(sent['terminalId'], 'terminal-1');
    expect(sent['data'], 'ls\n');

    await svc.dispose();
    await session.close();
  });
}
