// Regression tests for the New Session LANDING trap state.
//
// AppShell renders NewSessionScreen when no project is focused (`id == null`)
// even though workbenchSurfaceProvider may still read `workspace` (its default
// on cold start, or a stale value left by a flow that deselected the project).
// In that state, any flow that focuses a project mid-flight (selectProject —
// the composer's Start, the drawer's "+ new session", the folder picker)
// instantly flipped the route to WorkspaceShell: the in-flight flow's widgets
// unmounted (killing its WidgetRef before `session:create` was ever sent) and
// WorkspaceShell's `_bootstrapSessions` auto-opened the most-recent existing
// session instead. AppShell must therefore reconcile the landing's surface to
// `newSession` so the route can only leave the New Session screen through an
// explicit surface write (leaveNewSession / a session-row tap).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/providers/account_agents.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/auth.dart';
import 'package:antgrid/providers/device_provisioning.dart';
import 'package:antgrid/providers/new_session_picker.dart';
import 'package:antgrid/providers/ui_attention_providers.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/screens/app_shell.dart';
import 'package:antgrid/screens/new_session_screen.dart';
import 'package:antgrid/screens/workspace_shell.dart';
import 'package:antgrid/services/account_agents_api.dart';
import 'package:antgrid/widgets/new_session/picker_sources.dart';

import '../helpers/prefs_test_mock.dart';
import '../helpers/test_store_overrides.dart';

void main() {
  late TestStoreOverrides stores;

  setUp(() async {
    useInMemoryPrefs();
    stores = await buildTestStoreOverrides();
  });

  tearDown(() => stores.close());

  List<Override> baseOverrides({WorkbenchSurface? surface}) => [
    ...stores.overrides,
    // The landing subtree (drawer + recents + composer) fans into network- and
    // keychain-backed providers; stub them so the test never leaves memory.
    accountAgentsProvider.overrideWith((ref) async => const <InventoryAgent>[]),
    localDeviceUuidProvider.overrideWith((ref) async => null),
    currentUserProvider.overrideWith((ref) async => null),
    pickerSourcesProvider.overrideWithValue(const [
      PickerSource(
        id: 'local',
        label: 'Local',
        isLocal: true,
        projects: <PickerProject>[],
      ),
    ]),
    newSessionDetectedToolsProvider.overrideWith(
      (ref) async => const <String>{},
    ),
    newSessionChatCapableToolsProvider.overrideWith((ref) async => null),
    if (surface != null)
      workbenchSurfaceProvider.overrideWith(() => ValueController(surface)),
  ];

  Widget host(List<Override> overrides) => ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: buildAbTheme(),
      home: const MediaQuery(
        data: MediaQueryData(size: Size(1200, 800)),
        child: AppShell(),
      ),
    ),
  );

  ProviderContainer containerOf(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(AppShell)));

  // NOT pumpAndSettle: the landing keeps an animation running (loading
  // spinner), so pumpAndSettle never settles and burns its 10-minute timeout.
  // A handful of bounded pumps is enough to flush the post-frame surface
  // reconciliation and the async provider resolutions the landing awaits.
  Future<void> pumpLanding(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('landing (no focused project) pins the surface to newSession', (
    tester,
  ) async {
    await tester.pumpWidget(host(baseOverrides()));
    await pumpLanding(tester);

    expect(find.byType(NewSessionScreen), findsOneWidget);
    expect(
      containerOf(tester).read(workbenchSurfaceProvider),
      WorkbenchSurface.newSession,
    );
  });

  testWidgets('landing pin leaves an open appSettings overlay alone', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(baseOverrides(surface: WorkbenchSurface.appSettings)),
    );
    await pumpLanding(tester);

    expect(
      containerOf(tester).read(workbenchSurfaceProvider),
      WorkbenchSurface.appSettings,
    );
  });

  testWidgets(
    'focusing a project mid-flow on the landing keeps the New Session screen mounted',
    (tester) async {
      await tester.pumpWidget(host(baseOverrides()));
      await pumpLanding(tester);

      // What selectProject does inside startNewSession / the drawer's
      // "+ new session" activation: focus the target project. The route must
      // NOT flip to WorkspaceShell — doing so unmounts the widgets owning the
      // in-flight flow and lets _bootstrapSessions hijack the outcome.
      containerOf(
        tester,
      ).read(selectedTargetProvider.notifier).set(LocalProject('p1'));
      await tester.pump();

      expect(find.byType(NewSessionScreen), findsOneWidget);
      expect(find.byType(WorkspaceShell), findsNothing);
    },
  );
}
