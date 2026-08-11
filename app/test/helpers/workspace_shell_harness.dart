// Shared harness for tests that need the REAL WorkspaceShell rather than a
// stand-in — the shell gates its whole subtree behind a focused project whose
// transport and session resolve without error, so there is a fair amount of
// scaffolding before anything renders at all.
import 'package:antgrid/models/command_models.dart';
import 'package:antgrid/models/file_tree_models.dart';
import 'package:antgrid/models/preferences_models.dart';
import 'package:antgrid/models/preview_models.dart';
import 'package:antgrid/models/terminal_models.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/screens/app_shell.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid/window/window_chrome.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Riverpod 3 keeps `Override` out of the main barrel.
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'prefs_test_mock.dart';
import 'test_store_overrides.dart';

final testAgent = PairedAgent(
  relayUrl: 'wss://test.relay',
  agentDeviceId: 'agent-123.test-project',
  agentName: 'Test Agent',
);

/// A fake PairedAgentNotifier that returns a list with one mock PairedAgent.
class FakePairedAgentNotifier extends AsyncNotifier<List<PairedAgent>>
    implements PairedAgentNotifier {
  @override
  Future<List<PairedAgent>> build() async => [testAgent];

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

/// Pumps the real [AppShell] (which renders WorkspaceShell once paired), with
/// a fake window chrome since WorkspaceShell mounts `WindowTitleBar` directly.
///
/// Returns the container so a test can read what the shell publishes.
Future<ProviderContainer> pumpWorkspaceShell(
  WidgetTester tester, {
  bool withProject = true,
  List<Override> extraOverrides = const [],
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
          (ref) => withProject ? testAgent.agentDeviceId : null,
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
        // A real relay/local transport would need a live socket, and the shell
        // routes to its blocking-error screen if the transport fails.
        agentTransportForProvider.overrideWith(
          (ref, projectId) async => FakeAgentTransport(),
        ),
        windowChromeProvider.overrideWithValue(FakeWindowChrome()),
        // Last so a caller can replace any of the defaults above.
        ...extraOverrides,
      ],
      child: const MaterialApp(home: AppShell()),
    ),
  );
  await tester.pump();
  await tester.pump();

  return ProviderScope.containerOf(tester.element(find.byType(AppShell)));
}
