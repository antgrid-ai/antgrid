import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/models/command_models.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/services/command_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import '../helpers/fake_agent_transport.dart';
import '../helpers/prefs_test_mock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    useInMemoryPrefs();
  });

  // Poll for [condition] instead of guessing a fixed delay. CommandService
  // batches output via a 16ms flush timer; a fixed `Future.delayed` races that
  // timer, and on Windows the ~15.6ms timer granularity puts a 16ms flush and a
  // ~32ms wait on adjacent ticks — so the assertion sometimes fired before the
  // flush ran (flaky, not deterministic). Waiting on the actual state is stable
  // regardless of granularity.
  Future<void> waitFor(
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final sw = Stopwatch()..start();
    while (!condition()) {
      if (sw.elapsed > timeout) {
        throw StateError('Timed out waiting for condition');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

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
    while (service.currentState.current?.output.isEmpty ?? true) {
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

      expect(svc.currentState.current!.output.text, 'hello');

      await heavySub.cancel();
      await svc.dispose();
      await session.close();
    });

    test('a long-running command keeps only the newest output within the cap',
        () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = CommandService.fromSession(session);

      svc.runCommand('build');
      final heavySub = session.heavyStream.listen((_) {});

      final line = '${'x' * 99}\n';
      for (var i = 0; i < kCommandOutputMaxChars ~/ 4000 + 10; i++) {
        t.emit('command:output', {
          'projectId': 'p',
          'commandName': 'build',
          'data': line * 40,
        });
      }
      t.emit('command:output', {
        'projectId': 'p',
        'commandName': 'build',
        'data': 'END\n',
      });
      await waitFor(
        () => svc.currentState.current!.output.text.endsWith('END\n'),
      );

      final output = svc.currentState.current!.output;
      expect(output.length, lessThanOrEqualTo(kCommandOutputMaxChars));
      expect(output.trimmed, isTrue);
      expect(output.text.endsWith('END\n'), isTrue);

      await heavySub.cancel();
      await svc.dispose();
      await session.close();
    });

    test('output split across messages reaches the panel in order', () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = CommandService.fromSession(session);

      svc.runCommand('build');
      final heavySub = session.heavyStream.listen((_) {});

      for (final data in ['a', 'b\n', 'c']) {
        t.emit('command:output', {
          'projectId': 'p',
          'commandName': 'build',
          'data': data,
        });
      }
      await waitFor(() => svc.currentState.current!.output.text == 'ab\nc');
      expect(svc.currentState.current!.output.text, 'ab\nc');

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
      await waitFor(
        () => svc.currentState.current!.status == CommandStatus.success,
      );

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
        expect(svc.currentState.current!.output.text, 'hello');

        t.emit('command:done', {
          'projectId': 'proj-c',
          'commandName': 'build',
          'exitCode': 0,
        });
        await waitFor(
          () => svc.currentState.current!.status == CommandStatus.success,
        );
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
