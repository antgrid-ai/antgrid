// The project-open bootstrap runs detached from any awaiting frame, so a
// `session:*` reply that never arrives (a frame dropped while the transport is
// still re-establishing — the routine case on a mobile resume) must be reported
// and dropped, never rethrown. It escaped as a fatal
// `TimeoutException: session reply timed out` in 1.20668.151, with no in-app
// frames in the report because nothing on the stack was awaiting it.
import 'dart:convert';
import 'dart:io';

import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid/util/ab_log.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/workspace_shell_harness.dart';

void main() {
  late Directory tmp;
  late String logPath;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('shell_bootstrap_');
    logPath = '${tmp.path}/app.log';
    AbLog.configureForTest(logPath);
  });
  tearDown(() {
    AbLog.dispose();
    tmp.deleteSync(recursive: true);
  });

  List<Map<String, dynamic>> logLines() => !File(logPath).existsSync()
      ? const []
      : File(logPath)
            .readAsLinesSync()
            .where((l) => l.trim().isNotEmpty)
            .map((l) => jsonDecode(l) as Map<String, dynamic>)
            .toList();

  Map<String, dynamic> stoppedSession() => {
    'id': 'session-1',
    'name': 'Session 1',
    'createdAt': 0,
    'lastUsedAt': 0,
    'archived': false,
    'running': false,
    'mode': 'terminal',
  };

  testWidgets('an unanswered auto-start is logged, not thrown', (tester) async {
    final transport = FakeAgentTransport();
    await pumpWorkspaceShell(tester, transport: (_) => transport);
    // The bootstrap runs from a post-frame callback and awaits the project
    // session before it asks for the list.
    await tester.pump();
    await tester.pump();

    // Answer the bootstrap's OWN request (the last `session:list` on the wire —
    // the transport's hydrator sends one too, with no pending reply behind it)
    // with a single stopped session, which is what sends `session:start`.
    final list = transport.sent.lastWhere((m) => m['type'] == 'session:list');
    transport.emit('session:list:result', {
      'requestId': list['requestId'],
      'sessions': [stoppedSession()],
    });
    await tester.pump();

    expect(
      transport.sent.where((m) => m['type'] == 'session:start'),
      isNotEmpty,
      reason: 'a stopped most-recent session is auto-started on project open',
    );

    // Never answer it. Past the service's 15s pending-reply bound the request
    // fails — the assertion is that this test survives at all: an unhandled
    // async error here fails the test from the zone, as it crashed the app.
    await tester.pump(const Duration(seconds: 20));
    // The log's writer does real file I/O, which only progresses outside the
    // widget binding's fake-async zone.
    await tester.runAsync(AbLog.flush);

    expect(
      logLines().where(
        (l) =>
            l['component'] == 'WorkspaceShell' &&
            '${l['error']}'.contains('session reply timed out'),
      ),
      isNotEmpty,
      reason: 'the dropped reply should be reported to app.log',
    );
  });
}
