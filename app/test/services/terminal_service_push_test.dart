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

  Future<ProjectSession> newSession(FakeAgentTransport t) async {
    final cache = await CachedSessionsStore.open();
    return ProjectSession(
      projectId: 'p',
      transport: t,
      mode: ProjectSessionMode.local,
      cachedSessionsStore: cache,
      onClose: () async => await t.dispose(),
    );
  }

  test('notification:push is forwarded on pushNotificationStream', () async {
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final svc = TerminalService.fromSession(session);
    final got = svc.pushNotificationStream.first;

    t.emit('notification:push', {
      'type': 'notification:push',
      'id': 'm1',
      'timestamp': 1,
      'notificationType': 'task_complete',
      'message': 'Done',
    });

    final msg = await got;
    expect(msg.notificationType, 'task_complete');
    expect(msg.message, 'Done');

    await svc.dispose();
    await session.close();
  });
}
