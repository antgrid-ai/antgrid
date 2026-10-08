// A host restart, a Retry and a re-open after eviction each build the focused
// project a fresh ProjectSession, whose HandlerService has heard nothing yet.
// Until its first handler:status it cannot say whether a session is armed, and
// the Handler tab must not read that silence as a disarm.
import 'package:antgrid/models/workspace_view.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/providers/visible_surface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_agent_transport.dart';
import '../helpers/fake_project_session.dart';
import '../helpers/prefs_test_mock.dart';

Map<String, dynamic> _armedStatus(String terminalId) => {
  'projectId': 'p',
  'sessions': [
    {
      'terminalId': terminalId,
      'state': 'watching',
      'pendingEscalations': 0,
      'armedAt': 1,
      'goal': 'goal',
      'backlog': const <Map<String, dynamic>>[],
      'escalations': const <Map<String, dynamic>>[],
    },
  ],
};

/// Lets the frames through, then reads the way the next frame would: with no
/// frames pumped, nothing else makes Riverpod flush the rebuild it scheduled.
Future<void> _drain(ProviderContainer c) async {
  await Future<void>.delayed(Duration.zero);
  c.read(visibleWorkspaceViewsProvider);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(useInMemoryPrefs);

  test('a rebuilt project session keeps the Handler tab until it hears', () async {
    final transports = <FakeAgentTransport>[];
    final container = ProviderContainer(
      overrides: [
        projectSessionFactoryProvider.overrideWithValue((
          Ref ref,
          String projectId,
        ) async {
          final t = FakeAgentTransport();
          transports.add(t);
          return newFakeProjectSession(t, projectId: projectId);
        }),
      ],
    );
    addTearDown(container.dispose);

    final offered = <bool>[];
    container.listen(
      visibleWorkspaceViewsProvider,
      (_, views) => offered.add(views.contains(WorkspaceView.handler)),
      fireImmediately: true,
    );
    selectProjectInContainer(container, 'p');
    container.read(activeSessionIdProvider.notifier).set('session-1');
    await container.read(projectSessionProvider('p').future);
    transports.single.emit('handler:status', _armedStatus('session-1'));
    await _drain(container);
    expect(offered.last, isTrue);

    // What the host-restart rebind does to every open local project.
    offered.clear();
    container.invalidate(projectSessionProvider('p'));
    await container.read(projectSessionProvider('p').future);
    await _drain(container);
    expect(transports, hasLength(2));
    expect(offered, everyElement(isTrue));

    transports.last.emit('handler:status', _armedStatus('session-1'));
    await _drain(container);
    expect(offered, everyElement(isTrue));

    // Once the fresh service has heard, its answer stands, disarm included.
    transports.last.emit('handler:status', {
      'projectId': 'p',
      'sessions': const <Map<String, dynamic>>[],
    });
    await _drain(container);
    expect(offered.last, isFalse);
  });
}
