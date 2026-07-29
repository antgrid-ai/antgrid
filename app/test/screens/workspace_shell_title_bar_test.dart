import 'package:antgrid/models/command_models.dart';
import 'package:antgrid/models/file_tree_models.dart';
import 'package:antgrid/models/preferences_models.dart';
import 'package:antgrid/models/preview_models.dart';
import 'package:antgrid/models/terminal_models.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/screens/app_shell.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid/widgets/ab_banner.dart';
import 'package:antgrid/widgets/window_title_bar.dart';
import 'package:antgrid/window/window_chrome.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';
import '../helpers/test_store_overrides.dart';

final _testAgent = PairedAgent(
  relayUrl: 'wss://test.relay',
  agentDeviceId: 'agent-123.test-project',
  agentName: 'Test Agent',
);

/// A fake PairedAgentNotifier that returns a list with one mock PairedAgent.
///
/// Copied from `app_shell_test.dart` (a local class there, not exported).
class FakePairedAgentNotifier extends AsyncNotifier<List<PairedAgent>>
    implements PairedAgentNotifier {
  @override
  Future<List<PairedAgent>> build() async => [_testAgent];

  @override
  Future<void> importCoordinates(dynamic qr) async {}
  @override
  Future<void> selectAgent(String agentDeviceId) async {}
  @override
  Future<void> forgetMachine(String agentDeviceIdOrUuid) async {}
  @override
  Future<void> retryAgentConnection() async {}
  @override
  void cancelActiveAgent() {}
}

/// Pumps the real [AppShell] (which renders WorkspaceShell once paired),
/// with the store/session overrides `app_shell_test.dart`'s `buildTestShell`
/// uses plus a fake window chrome, since WorkspaceShell now mounts
/// [WindowTitleBar] directly.
Future<void> pumpWorkspaceShell(
  WidgetTester tester, {
  bool withProject = true,
}) async {
  useInMemoryPrefs();
  final stores = await buildTestStoreOverrides();
  addTearDown(stores.close);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...stores.overrides,
        pairedAgentProvider.overrideWith(() => FakePairedAgentNotifier()),
        selectedRegistrationIdProvider.overrideWith(
          (ref) => withProject ? _testAgent.agentDeviceId : null,
        ),
        terminalStateProvider.overrideWith(
          (ref) => Stream.value(const TerminalState()),
        ),
        fileTreeStateProvider.overrideWith(
          (ref) => Stream.value(const FileTreeState()),
        ),
        previewStateProvider.overrideWith(
          (ref) => Stream.value(const PreviewState()),
        ),
        commandStateProvider.overrideWith(
          (ref) => Stream.value(const CommandState()),
        ),
        projectPreferencesProvider.overrideWith(
          (ref) => Stream.value(const ProjectPreferences()),
        ),
        // WorkspaceShell gates its whole subtree (including the bar) behind
        // the focused project's transport/session resolving without error —
        // a real relay/local transport would need a live socket, so hand it
        // an in-memory fake instead of letting it fail past the blocking-
        // error screen.
        agentTransportForProvider.overrideWith(
          (ref, projectId) async => FakeAgentTransport(),
        ),
        windowChromeProvider.overrideWithValue(FakeWindowChrome()),
      ],
      child: const MaterialApp(home: AppShell()),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('the title bar sits above AbBanner', (tester) async {
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await pumpWorkspaceShell(tester);

      final barY = tester.getTopLeft(find.byType(WindowTitleBar)).dy;
      final bannerY = tester.getTopLeft(find.byType(AbBanner)).dy;
      // AppKit positions the traffic lights in window coordinates, so nothing
      // may occupy vertical space above the bar or they strand over it.
      expect(barY, lessThan(bannerY));
      expect(barY, 0.0);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('the title bar survives the no-project route', (tester) async {
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await pumpWorkspaceShell(tester, withProject: false);

      // With no project focused AppShell routes to NewSessionScreen instead of
      // WorkspaceShell. The OS bar is hidden process-wide, so a route that
      // drops the bar leaves the window with no drag region and no close
      // button — the state a fresh install opens in.
      expect(find.byType(WindowTitleBar), findsOneWidget);
      expect(tester.getTopLeft(find.byType(WindowTitleBar)).dy, 0.0);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
