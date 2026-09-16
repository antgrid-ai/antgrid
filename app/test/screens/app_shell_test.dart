import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:antgrid/providers/relay_connection.dart';

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

const _testAgentDeviceId = 'agent-123.test-project';

class _ResumeManager extends RelayConnectionManager {
  _ResumeManager() : super(crypto: CryptoService());
  int resumes = 0;
  @override
  void noteResume() => resumes++;
}

void main() {
  late TestStoreOverrides stores;

  setUp(() async {
    useInMemoryPrefs();
    stores = await buildTestStoreOverrides();
  });

  tearDown(() => stores.close());

  Widget buildTestShell({
    required double width,
    RelayConnectionManager? manager,
  }) {
    return ProviderScope(
      overrides: [
        ...stores.overrides,
        if (manager != null)
          relayConnectionManagerProvider.overrideWithValue(manager),
        selectedRegistrationIdProvider.overrideWith(
          (ref) => _testAgentDeviceId,
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
    testWidgets(
      'one foreground transition refreshes remote authorization once',
      (tester) async {
        final manager = _ResumeManager();
        addTearDown(manager.disposeAll);
        await tester.pumpWidget(buildTestShell(width: 400, manager: manager));
        await tester.pump();
        final binding = tester.binding;
        binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        await tester.pump();
        expect(manager.resumes, 0);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pump();
        expect(manager.resumes, 1);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

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
