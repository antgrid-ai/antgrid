// Shared harness for tests that need the REAL WorkspaceShell rather than a
// stand-in — the shell gates its whole subtree behind a focused project whose
// transport and session resolve without error, so there is a fair amount of
// scaffolding before anything renders at all.
import 'package:antgrid/models/command_models.dart';
import 'package:antgrid/models/file_tree_models.dart';
import 'package:antgrid/models/preferences_models.dart';
import 'package:antgrid/models/preview_models.dart';
import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/models/terminal_models.dart';
import 'package:antgrid/providers/account_agents.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/device_provisioning.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/screens/app_shell.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid/window/window_chrome.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart'
    show AgentTransport;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Riverpod 3 keeps `Override` out of the main barrel.
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'prefs_test_mock.dart';
import 'test_store_overrides.dart';

/// The focused entry id these tests mount the shell on: a remote PROJECT, i.e.
/// the compound `<machineUuid>.<projectId>` shape.
const testAgentDeviceId = 'agent-123.test-project';

/// Distinguishes "no [SessionTarget] override" (fall back to the
/// `withProject`-derived default) from an explicit `target: null` (the
/// "route mounted, nothing focused yet" window) — `null` itself is a
/// meaningful value here, so it can't double as the "unset" marker.
const _unset = Object();

/// Pumps the real [AppShell] (which renders WorkspaceShell once paired), with
/// a fake window chrome since WorkspaceShell mounts `WindowTitleBar` directly.
///
/// Pass [transport] to drive the wire from the test (inspect `sent`, `emit`
/// replies), [terminalStates] to drive CheckoutReadiness through a specific
/// attach-status sequence, and [target] for a [SessionTarget] other than the
/// default local project (e.g. a remote one, to exercise the ladder, or
/// `null` for the "route mounted, nothing focused yet" window with
/// `withProject: true`) — all three must come through these parameters rather
/// than [extraOverrides]: Riverpod 3 asserts on ANY provider overridden twice
/// in one container, not only a family one.
///
/// Returns the container so a test can read what the shell publishes.
Future<ProviderContainer> pumpWorkspaceShell(
  WidgetTester tester, {
  bool withProject = true,
  bool followSelectedTarget = false,
  AgentTransport Function(String projectId)? transport,
  Stream<TerminalState>? terminalStates,
  Object? target = _unset,
  List<Override> extraOverrides = const [],
}) async {
  useInMemoryPrefs();
  final stores = await buildTestStoreOverrides();
  addTearDown(stores.close);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...stores.overrides,
        // Account- and keychain-backed, and both are read while the shell
        // chrome builds. The real inventory fetch pulls the session cookie out
        // of the keychain and the real uuid MINTS a host identity on desktop —
        // neither belongs in a widget test. Kept out of [extraOverrides] for
        // the same reason the transport is: Riverpod 3 asserts on a provider
        // overridden twice in one container.
        accountAgentsProvider.overrideWith((_) async => const []),
        localDeviceUuidProvider.overrideWith((_) async => 'test-local-device'),
        if (!followSelectedTarget)
          selectedRegistrationIdProvider.overrideWith(
            (ref) => withProject ? testAgentDeviceId : null,
          ),
        // CheckoutReadiness (workspace_shell.dart's boot-overlay gate) reads
        // selectedTargetProvider directly, for the isLocal flag the bare
        // registration-id string above can't carry — so it must stay in sync
        // with the override above or the shell never leaves its boot screen.
        // `isLocal: true` (not a RemoteTarget) is deliberate here even though
        // the id carries a compound machine.project shape: these tests dial no
        // real supervisor (the wire is faked directly via
        // agentTransportForProvider below), so a target that sends readiness
        // through the relay ladder would park on `reachingMachine` forever —
        // the same reason CheckoutReadiness itself skips that ladder for local
        // targets. Matches this harness's pre-existing behaviour, under which
        // every `isRemoteTarget`-gated read here already saw `false`.
        selectedTargetProvider.overrideWith(
          () => ValueController(
            identical(target, _unset)
                ? (withProject ? const LocalProject(testAgentDeviceId) : null)
                : target as SessionTarget?,
          ),
        ),
        // Defaults to `attach: ready`, not the bare const default (`unknown`,
        // which CheckoutReadiness reads as `loadingScreen`): most callers need
        // the workspace actually mounted, and a static single-value stream
        // never advances the way a live TerminalService would. A test driving
        // a specific attach sequence passes [terminalStates] instead.
        terminalStateProvider.overrideWith(
          (ref) =>
              terminalStates ??
              Stream.value(
                const TerminalState(attach: CheckoutAttachStatus.ready),
              ),
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
          (ref, projectId) async =>
              transport?.call(projectId) ?? FakeAgentTransport(),
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
