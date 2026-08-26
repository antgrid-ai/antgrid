import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../demo/demo_identity.dart';
import '../models/session_target.dart';
import '../navigation/nav_controller.dart';
import '../navigation/nav_location.dart';
import '../navigation/root_navigator.dart';
import '../project/project_session_registry.dart';
import 'agent_transport.dart';
import 'new_session_picker.dart';
import 'ui_attention_providers.dart';
import 'value_controller.dart';

/// Whether the offline sample project is on screen.
///
/// In-memory only, deliberately: nothing about the demo may survive a relaunch,
/// so a reviewer or tester who force-quits comes back to the real app rather
/// than to canned data they might mistake for their machine. It is also the
/// LIFETIME of the demo transport — `agentTransportForProvider` watches this
/// flag for the demo id, so flipping it false disposes the transport instead of
/// leaving a stale one warm.
final demoModeProvider = NotifierProvider<ValueController<bool>, bool>(
  () => ValueController(false),
);

/// Drops every route pushed above the app's root.
///
/// Both edges of the demo need this and neither gets it from Flutter: toggling
/// [demoModeProvider] swaps `DemoFrame`'s child slot, which REPARENTS the app's
/// Navigator rather than tearing it down — `WidgetsApp` gives that Navigator a
/// GlobalKey, so routes pushed over it survive the move with their state
/// intact. Without this a dialog opened over the sample project would be left
/// standing over the real app, and vice versa.
///
/// Lives here rather than at each call site because the three entry points do
/// not all sit on a route that would pop itself — today two of them mount on
/// the New Session surface, which is what has been hiding the gap.
///
/// A null `currentState` (a container-only test, or a call before the first
/// frame) is a no-op by design.
void _popToRoot(ProviderContainer ref) {
  ref.read(rootNavigatorKeyProvider).currentState?.popUntil((r) => r.isFirst);
}

/// Focuses the sample project and turns the demo on.
///
/// Takes the container, not a `WidgetRef`: [_popToRoot] below pops the route
/// the caller was on, so the widget that called this is gone by the time the
/// rest of this function runs.
void enterDemoMode(ProviderContainer ref) {
  _popToRoot(ref);
  // FIRST, before the focus below. Every gate in the app is written as "if the
  // demo is on, refuse" while the thing that ARMS the host-spawn paths is a
  // focused `LocalProject` — which the next statement makes the demo into. In
  // between, the container would hold a local target with the guard still
  // false, and a synchronous read of that chain (`focusedMachineToolsProvider`
  // reads the target first and the flag second, then calls `ensureHost()`)
  // would spawn the real bridge from inside the sample project. Riverpod
  // happens to coalesce these writes into one rebuild today; ordering makes it
  // not depend on that.
  ref.read(demoModeProvider.notifier).set(true);
  ref
      .read(selectedTargetProvider.notifier)
      .set(const LocalProject(kDemoProjectId));
  // The workspace is the demo: whatever surface the user left behind (the New
  // Session canvas is reachable before a project exists) must not be what the
  // sample project opens on.
  ref.read(workbenchSurfaceProvider.notifier).set(WorkbenchSurface.workspace);
  // The New Session composer's draft target is not surface state and survives
  // the switch. Left pointing at a real project it would keep resolving that
  // project's branches — which means spawning the bridge host — from inside
  // the demo.
  ref.read(selectedTargetProjectProvider.notifier).set(null);
  // Nav history is per-scope here, not global. A real project's entry left in
  // it would be applied by a back press INSIDE the demo — focusing a machine
  // under a banner that says nothing is connected — and seeding the demo's own
  // `current` is what gives its first navigation somewhere to go back to.
  ref.read(navControllerProvider.notifier)
    ..reset()
    ..commit(
      const NavLocation(
        target: LocalProject(kDemoProjectId),
        surface: WorkbenchSurface.workspace,
      ),
    );
}

/// Leaves the demo and drops everything it built.
///
/// Mirrors `ProjectsController.cancelActiveAgent`: clear the focus, then evict —
/// eviction invalidates the session and transport family entries, so re-entering
/// replays the script from the top instead of resuming a half-played one.
void exitDemoMode(ProviderContainer ref) {
  _popToRoot(ref);
  ref.read(demoModeProvider.notifier).set(false);
  ref.read(selectedTargetProvider.notifier).set(null);
  // Same reason as on the way in, mirrored: a draft still naming the sample
  // project would ask the real host for its branches.
  ref.read(selectedTargetProjectProvider.notifier).set(null);
  // Every focus change inside the demo committed a NavLocation naming the
  // sample project. Those entries outlive it, and the first back press after
  // leaving would apply one — focusing a project the drawer no longer lists
  // and no transport can resolve.
  ref.read(navControllerProvider.notifier).reset();
  ref.read(projectSessionRegistryProvider.notifier).forceEvict(kDemoProjectId);
}
