// What the Terminals toolbar shows and sends: the checkout folder it names,
// and the Restart and Clear it offers.
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/services/terminal_service.dart';
import '../helpers/fake_agent_transport.dart';
import '../helpers/fake_project_session.dart';
import '../helpers/prefs_test_mock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(useInMemoryPrefs);

  Future<(FakeAgentTransport, TerminalService)> boot() async {
    final t = FakeAgentTransport();
    final session = await newFakeProjectSession(t);
    final svc = TerminalService.fromSession(session);
    addTearDown(() async {
      await svc.dispose();
      await session.close();
    });
    return (t, svc);
  }

  test('agent:status carries the checkout folder, and keeps it across a '
      'frame that omits it', () async {
    final (t, svc) = await boot();
    t.emit('agent:status', {
      'projectId': 'p',
      'terminals': <Object>[],
      'checkoutPath': r'C:\code\demo',
    });
    await Future<void>.delayed(Duration.zero);
    expect(svc.currentState.checkoutPath, r'C:\code\demo');

    t.emit('agent:status', {'projectId': 'p', 'terminals': <Object>[]});
    await Future<void>.delayed(Duration.zero);
    expect(svc.currentState.checkoutPath, r'C:\code\demo');
  });

  test('Restart respawns the terminal under its own id and name', () async {
    final (t, svc) = await boot();
    svc.createAdHocTerminal('terminal-1', name: 'Terminal 1');
    t.clearSent();

    svc.restartTerminal('terminal-1');

    final start = t.sent.where((m) => m['type'] == 'terminal:start').single;
    expect(start['terminalId'], 'terminal-1');
    expect(start['name'], 'Terminal 1');
  });

  group('Clear', () {
    test('sends Ctrl+L to a shell that clears on it', () {
      for (final shell in [
        '/bin/bash',
        '/usr/bin/zsh',
        r'C:\Program Files\PowerShell\7\pwsh.exe',
        // Not started yet, or an older bridge that never named it.
        null,
      ]) {
        expect(
          TerminalService.clearScreenInputFor(shell),
          '\x0c',
          reason: '$shell',
        );
      }
    });

    // cmd.exe has no clear-screen key: Ctrl+L would print a literal ^L.
    test('types cls into cmd.exe', () {
      expect(
        TerminalService.clearScreenInputFor(r'C:\Windows\System32\cmd.exe'),
        'cls\r',
      );
    });
  });
}
