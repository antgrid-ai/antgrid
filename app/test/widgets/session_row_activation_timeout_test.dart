// Tapping a STOPPED session row sends `session:start` and then, whatever comes
// back, still has to finish the activation the tap asked for: focus the session
// and switch to the workspace surface. A dropped reply fails that request 15s
// later (`SessionsService`'s pending-reply bound) — routine on a flaky link, and
// the bridge may have spawned the PTY anyway — so abandoning the surface + nav
// writes there leaves `activeSessionId` set on a screen that never changed: a
// tap that visibly did nothing.
import 'package:antgrid/models/ab_project.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/project/project_status.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/auth.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/providers/ui_attention_providers.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid/widgets/projects_drawer.dart';
import 'package:antgrid/widgets/session_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';
import '../helpers/test_store_overrides.dart';

const _projectId = 'timeout-proj';
const _sessionId = 'sess-1';

AbProject _project() => AbProject(
  projectId: _projectId,
  folder: '/tmp/$_projectId',
  displayName: _projectId,
  hostDeviceUuid: _projectId,
  hostMachineName: '',
  lastOpenedAt: DateTime.now(),
);

SessionEntry _stopped() => SessionEntry(
  id: _sessionId,
  name: 'Session 1',
  createdAt: 0,
  lastUsedAt: 0,
  archived: false,
  running: false,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestStoreOverrides stores;

  setUp(() async {
    useInMemoryPrefs();
    stores = await buildTestStoreOverrides();
  });
  tearDown(() async {
    await stores.close();
  });

  testWidgets('a start whose reply never lands still opens the session', (
    tester,
  ) async {
    await stores.projectStore.upsert(_project());
    await stores.cachedSessionsStore.put(_projectId, [_stopped()]);
    // CachedSessionsStore debounces writes by 200ms; flush so no timer outlives
    // the tree.
    await stores.cachedSessionsStore.flushNow();

    final transport = FakeAgentTransport();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...stores.overrides,
          // The project is already focused, so the row takes the same-project
          // fast path — and with no paired agents `focusedIsRelayProvider` is
          // false, so it never reaches the remote online check.
          selectedRegistrationIdProvider.overrideWith((_) => _projectId),
          agentTransportForProvider.overrideWith(
            (ref, projectId) async => transport,
          ),
          projectStatusProvider(
            _projectId,
          ).overrideWith((_) => Stream.value(const ProjectStatus.empty())),
          currentUserProvider.overrideWith((_) async => null),
        ],
        child: const MaterialApp(home: Scaffold(body: ProjectsDrawer())),
      ),
    );
    await tester.pump();
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProjectsDrawer)),
    );

    await tester.tap(find.byType(SessionRow).first);
    // Let the row warm the project session and issue the start.
    await tester.pump();
    await tester.pump();
    expect(
      transport.sent.where((m) => m['type'] == 'session:start'),
      isNotEmpty,
      reason: 'tapping a stopped row starts it',
    );
    expect(container.read(activeSessionIdProvider), _sessionId);

    // Never answer it, then step past the 15s pending-reply bound.
    await tester.pump(const Duration(seconds: 20));
    await tester.pump();

    expect(
      transport.sent.where((m) => m['type'] == 'session:focus'),
      isNotEmpty,
      reason: 'the focus that bumps lastUsedAt survives the failed start',
    );
    expect(
      container.read(workbenchSurfaceProvider),
      WorkbenchSurface.workspace,
      reason: 'the tap still lands the user on the session it asked for',
    );
  });
}
