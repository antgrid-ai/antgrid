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

  // A result can land after focus moved (late commit hook, sidebar stop), so
  // it must be heard from any project, not only the focused one.
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

  // Rebuilding the fan-in must not cancel subscriptions: events are delivered
  // a microtask after add, so a queued one would be dropped.
  test('an event in flight survives another project opening', () async {
    final transportA = FakeAgentTransport();
    final sessions = <String, ProjectSession>{
      'A': await newFakeProjectSession(transportA, projectId: 'A'),
      'C': await newFakeProjectSession(FakeAgentTransport(), projectId: 'C'),
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
    await container.read(projectSessionProvider('C').future);
    final registry = container.read(projectSessionRegistryProvider.notifier);
    registry.touch('A', isLocal: true);

    final seen = <String>[];
    StreamSubscription<ProjectScoped<String>>? errors;
    final sub = container.listen(operationalErrorsProvider, (_, next) {
      errors?.cancel();
      errors = next.listen((e) => seen.add(e.message));
    }, fireImmediately: true);
    addTearDown(() {
      sub.close();
      errors?.cancel();
    });
    await Future<void>.delayed(Duration.zero);

    transportA.emit('git:commit-result', {
      'projectId': 'A',
      'success': false,
      'error': 'pre-commit hook failed',
    });
    registry.touch('C', isLocal: true);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(seen, ['pre-commit hook failed']);
  });

  test('a project whose session is replaced is heard on the new one', () async {
    final first = FakeAgentTransport();
    final second = FakeAgentTransport();
    final replacements = [
      await newFakeProjectSession(first, projectId: 'A'),
      await newFakeProjectSession(second, projectId: 'A'),
    ];
    for (final s in replacements) {
      addTearDown(s.close);
    }
    var built = 0;
    final container = ProviderContainer(
      overrides: [
        projectSessionProvider.overrideWith(
          (ref, id) async => replacements[built++],
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(projectSessionProvider('A').future);
    container
        .read(projectSessionRegistryProvider.notifier)
        .touch('A', isLocal: true);

    final seen = <String>[];
    StreamSubscription<ProjectScoped<String>>? errors;
    final sub = container.listen(operationalErrorsProvider, (_, next) {
      errors?.cancel();
      errors = next.listen((e) => seen.add(e.message));
    }, fireImmediately: true);
    addTearDown(() {
      sub.close();
      errors?.cancel();
    });

    container.invalidate(projectSessionProvider('A'));
    await container.read(projectSessionProvider('A').future);
    await Future<void>.delayed(Duration.zero);
    second.emit('git:commit-result', {
      'projectId': 'A',
      'success': false,
      'error': 'from the new session',
    });
    await Future<void>.delayed(Duration.zero);

    expect(seen, ['from the new session']);
  });
}
