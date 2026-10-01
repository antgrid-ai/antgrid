import 'dart:async';

import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_agent_transport.dart';
import '../helpers/fake_project_session.dart';
import '../helpers/prefs_test_mock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(useInMemoryPrefs);

  // A commit's hook can outlast a switch to another checkout, and the sidebar
  // can stop a session in a project that is not focused, so the result has to
  // be heard from wherever it lands — not only from what is focused when it
  // does.
  test('carries results from every warm project and checkout', () async {
    final transportA = FakeAgentTransport();
    final transportB = FakeAgentTransport();
    final sessions = <String, ProjectSession>{
      'A': await newFakeProjectSession(transportA, projectId: 'A'),
      'B': await newFakeProjectSession(transportB, projectId: 'B'),
    };
    for (final s in sessions.values) {
      addTearDown(s.close);
    }

    final container = ProviderContainer(
      overrides: [
        projectSessionProvider.overrideWith((ref, id) async => sessions[id]!),
      ],
    );
    addTearDown(container.dispose);
    await container.read(projectSessionProvider('A').future);
    await container.read(projectSessionProvider('B').future);
    final registry = container.read(projectSessionRegistryProvider.notifier);
    registry.touch('A', isLocal: true);
    registry.touch('B', isLocal: true);

    final seen = <(String, String)>[];
    StreamSubscription<ProjectScoped<String>>? errors;
    final sub = container.listen(operationalErrorsProvider, (_, next) {
      errors?.cancel();
      errors = next.listen((e) => seen.add((e.entryId, e.message)));
    }, fireImmediately: true);
    addTearDown(() {
      sub.close();
      errors?.cancel();
    });

    // B's refusal, from a project nothing has focused.
    final stop = sessions['B']!.sessionsService.stopSession('sess-1');
    await Future<void>.delayed(Duration.zero);
    final sent = transportB.sent.lastWhere((m) => m['type'] == 'session:stop');
    transportB.emit('session:result', {
      'requestId': sent['requestId'],
      'ok': false,
      'error': 'no such session',
    });
    await stop;
    await Future<void>.delayed(Duration.zero);

    // A checkout of A created after the subscription, so it arrives over the
    // bundle stream rather than the initial listing.
    sessions['A']!.servicesForCheckout('wt-1');
    await Future<void>.delayed(Duration.zero);
    transportA.emit('git:commit-result', {
      'projectId': 'A',
      'checkoutId': 'wt-1',
      'success': false,
      'error': 'pre-commit hook failed',
    });
    await Future<void>.delayed(Duration.zero);

    expect(seen, [
      ('B', 'Session error: no such session'),
      ('A', 'pre-commit hook failed'),
    ]);
  });
}
