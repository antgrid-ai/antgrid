import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/models/command_models.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/services/command_service.dart';
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
    ProjectSessionMode mode = ProjectSessionMode.local,
  }) async {
    final cache = await CachedSessionsStore.open();
    return ProjectSession(
      projectId: projectId,
      transport: t,
      mode: mode,
      cachedSessionsStore: cache,
      onClose: () async => await t.dispose(),
    );
  }

  Future<void> waitForOutput(
    CommandService service, {
    Duration timeout = const Duration(seconds: 1),
    Duration pollInterval = const Duration(milliseconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (service.currentState.current?.output.value.isEmpty ?? true) {
      if (DateTime.now().isAfter(deadline)) {
        fail('Command output was still empty after $timeout');
      }
      await Future<void>.delayed(pollInterval);
    }
  }

  group('CommandService.fromSession', () {
    test('runCommand sends command:run with projectId', () async {
      final t = FakeAgentTransport();
      final session = await newSession(t, projectId: 'proj-c');
      final svc = CommandService.fromSession(session);

      svc.runCommand('build');
      await Future<void>.delayed(Duration.zero);

      final sent = t.sent.firstWhere((m) => m['type'] == 'command:run');
      expect(sent['projectId'], 'proj-c');
      expect(sent['commandName'], 'build');

      await svc.dispose();
      await session.close();
    });

    test('runCommand seeds current execution state', () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = CommandService.fromSession(session);

      svc.runCommand('build');

      expect(svc.currentState.current, isNotNull);
      expect(svc.currentState.current!.commandName, 'build');
      expect(svc.currentState.current!.status, CommandStatus.running);

      await svc.dispose();
      await session.close();
    });

    test('command:output accumulates into output buffer', () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = CommandService.fromSession(session);

      svc.runCommand('build');
      // Need to subscribe to heavyStream so the router unpauses.
      final heavySub = session.heavyStream.listen((_) {});

      t.emit('command:output', {
        'projectId': 'p',
        'commandName': 'build',
        'data': 'hello',
      });
      await waitForOutput(svc);

      expect(svc.currentState.current!.output.value, 'hello');

      await heavySub.cancel();
      await svc.dispose();
      await session.close();
    });

    test('command:done marks success when exitCode is 0', () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = CommandService.fromSession(session);

      svc.runCommand('build');

      t.emit('command:done', {
        'projectId': 'p',
        'commandName': 'build',
        'exitCode': 0,
      });
      await Future<void>.delayed(Duration.zero);

      expect(svc.currentState.current!.status, CommandStatus.success);
      expect(svc.currentState.current!.exitCode, 0);

      await svc.dispose();
      await session.close();
    });

    test(
      'relay: command:output (echoed bare projectId) is captured even though '
      'the session id is the compound registrationId',
      () async {
        // Regression guard: the bridge echoes back the BARE projectId it
        // received (= session.wireProjectId), not the compound relay
        // registrationId. The echo-match must anchor on the bare id, or
        // command output is silently dropped over relay.
        final t = FakeAgentTransport();
        final session = await newSession(
          t,
          projectId: '6f05eb01-3b2b-4ffc-8a49-cd58d15c57ac.proj-c',
          mode: ProjectSessionMode.relay,
        );
        final svc = CommandService.fromSession(session);

        svc.runCommand('build');
        await Future<void>.delayed(Duration.zero);

        // Outbound carries the bare wire id.
        final sent = t.sent.firstWhere((m) => m['type'] == 'command:run');
        expect(sent['projectId'], 'proj-c');

        final heavySub = session.heavyStream.listen((_) {});
        t.emit('command:output', {
          'projectId': 'proj-c', // bridge echoes the bare id back
          'commandName': 'build',
          'data': 'hello',
        });
        await waitForOutput(svc);
        expect(svc.currentState.current!.output.value, 'hello');

        t.emit('command:done', {
          'projectId': 'proj-c',
          'commandName': 'build',
          'exitCode': 0,
        });
        await Future<void>.delayed(Duration.zero);
        expect(svc.currentState.current!.status, CommandStatus.success);

        await heavySub.cancel();
        await svc.dispose();
        await session.close();
      },
    );

    test('dismiss clears current state', () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = CommandService.fromSession(session);

      svc.runCommand('build');
      expect(svc.currentState.current, isNotNull);
      svc.dismiss();
      expect(svc.currentState.current, isNull);

      await svc.dispose();
      await session.close();
    });

    test('dispose is idempotent', () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = CommandService.fromSession(session);

      await svc.dispose();
      await svc.dispose();

      await session.close();
    });
  });
}
