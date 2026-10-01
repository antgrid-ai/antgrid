import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import '../helpers/fake_agent_transport.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';

Map<String, dynamic> _escalationJson(String escalationId, {int at = 1}) => {
  'escalationId': escalationId,
  'question': 'q',
  'reasoning': 'r',
  'draftReply': 'd',
  'urgency': 'normal',
  'at': at,
};

Map<String, dynamic> _statusJson(
  String projectId,
  List<Map<String, dynamic>> escalations,
) => {
  'projectId': projectId,
  'sessions': [
    {
      'terminalId': 't1',
      'state': 'needs_you',
      'pendingEscalations': escalations.length,
      'armedAt': 0,
      'goal': 'summary',
      'backlog': const <Map<String, dynamic>>[],
      'escalations': escalations,
    },
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(useInMemoryPrefs);

  test('a fanned-in escalation names the project it came from', () async {
    final transportA = FakeAgentTransport();
    final transportB = FakeAgentTransport();
    final cache = await CachedSessionsStore.open();
    addTearDown(cache.close);
    final sessions = <String, ProjectSession>{
      'A': ProjectSession(
        projectId: 'A',
        transport: transportA,
        mode: ProjectSessionMode.local,
        cachedSessionsStore: cache,
        onClose: () async => await transportA.dispose(),
      ),
      'B': ProjectSession(
        projectId: 'B',
        transport: transportB,
        mode: ProjectSessionMode.local,
        cachedSessionsStore: cache,
        onClose: () async => await transportB.dispose(),
      ),
    };
    for (final s in sessions.values) {
      addTearDown(s.close);
    }

    // Both projects already hold a pending escalation, so the provider's
    // per-build seed has something to attribute as well as the live stream.
    transportA.emit('handler:status', _statusJson('A', [
      _escalationJson('from-a'),
    ]));
    transportB.emit('handler:status', _statusJson('B', [
      _escalationJson('from-b'),
    ]));
    await Future<void>.delayed(Duration.zero);

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
    final sub = container.listen(handlerEscalationsProvider, (_, next) {
      final scoped = next.value;
      if (scoped == null) return;
      seen.add((scoped.entryId, scoped.message.escalationId));
    });
    addTearDown(sub.close);
    await Future<void>.delayed(Duration.zero);

    expect(seen, containsAll([('A', 'from-a'), ('B', 'from-b')]));

    transportB.emit('handler:escalation', {
      'projectId': 'B',
      'escalationId': 'live-b',
      'terminalId': 't1',
      'question': 'q',
      'reasoning': 'r',
      'draftReply': 'd',
      'urgency': 'high',
    });
    await Future<void>.delayed(Duration.zero);

    expect(seen.last, ('B', 'live-b'));
  });

}
