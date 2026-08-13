import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';

import 'package:antgrid/models/terminal_models.dart';
import 'package:antgrid/models/file_tree_models.dart';
import 'package:antgrid/models/command_models.dart';
import 'package:antgrid/models/preview_models.dart';
import 'package:antgrid/models/preferences_models.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/screens/app_shell.dart';
import 'package:antgrid/screens/workspace_shell.dart';

import '../helpers/test_store_overrides.dart';
import '../helpers/prefs_test_mock.dart';

final _testAgent = PairedAgent(
  relayUrl: 'wss://test.relay',
  agentDeviceId: 'agent-123.test-project',
  agentName: 'Test Agent',
);

/// A fake PairedAgentNotifier that returns a list with one mock PairedAgent.
class FakePairedAgentNotifier extends AsyncNotifier<List<PairedAgent>>
    implements PairedAgentNotifier {
  @override
  Future<List<PairedAgent>> build() async => [_testAgent];

  @override
  Future<void> selectAgent(String agentDeviceId) async {}
  @override
  Future<void> forgetMachine(String agentDeviceIdOrUuid) async {}
  @override
  Future<void> retryAgentConnection() async {}
  @override
  void cancelActiveAgent() {}
}

void main() {
  late TestStoreOverrides stores;

  setUp(() async {
    useInMemoryPrefs();
    stores = await buildTestStoreOverrides();
  });

  tearDown(() => stores.close());

  Widget buildTestShell({required double width}) {
    return ProviderScope(
      overrides: [
        ...stores.overrides,
        pairedAgentProvider.overrideWith(() => FakePairedAgentNotifier()),
        selectedRegistrationIdProvider.overrideWith(
          (ref) => _testAgent.agentDeviceId,
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
      ],
      child: MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(size: Size(width, 800)),
          child: const AppShell(),
        ),
      ),
    );
  }

  group('AppShell layout', () {
    testWidgets('renders WorkspaceShell when paired', (tester) async {
      await tester.pumpWidget(buildTestShell(width: 1000));
      await tester.pump();

      expect(find.byType(WorkspaceShell), findsOneWidget);
    });

    testWidgets('renders WorkspaceShell at compact width', (tester) async {
      await tester.pumpWidget(buildTestShell(width: 400));
      await tester.pump();

      expect(find.byType(WorkspaceShell), findsOneWidget);
    });

    // AppBackScope owns the app's ONLY PopScope. A second one on the same route
    // would double-handle every system back press.
    testWidgets('mounts exactly one PopScope', (tester) async {
      await tester.pumpWidget(buildTestShell(width: 400));
      await tester.pump();

      expect(find.byType(PopScope<Object?>), findsOneWidget);
    });
  });
}
