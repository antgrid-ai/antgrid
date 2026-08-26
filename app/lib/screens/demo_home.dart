import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart' show Scaffold;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../navigation/back_intent.dart';
import '../navigation/nav_controller.dart';
import '../providers/agent_transport.dart';
import '../providers/demo_mode.dart';
import '../providers/providers.dart';
import '../providers/ui_attention_providers.dart';
import 'new_session_screen.dart';
import 'workspace_shell.dart';

/// Root route while the demo is on.
///
/// Deliberately NOT [AppShell]: its `initState` kicks the eager relay dials and
/// the device-revoked check, which read the keychain and open sockets — the two
/// things the demo may never do. The "sample data" strip and, on desktop, the
/// window chrome AppShell would have drawn come from `DemoFrame` in the app
/// builder.
///
/// What it does have to reproduce is `AppShell._buildAgentRouting`'s route
/// switch, minus the control-plane reaper (the demo opens no control plane).
/// All three arms matter: without the surface branch the drawer's "New Session"
/// button — its primary action, two taps from the first screen — sets a surface
/// nothing reads and appears dead; without the no-project branch a surface that
/// deselects the sample project (a blocking error's Back, which clears
/// `selectedTargetProvider`) leaves WorkspaceShell on its boot spinner with
/// nothing left to resolve; and without the [Scaffold] the mouse-desktop layout
/// is a bare `Row` with no [Material] ancestor, which every `InkWell` in the
/// drawer throws on.
class DemoHome extends ConsumerStatefulWidget {
  const DemoHome({super.key});

  @override
  ConsumerState<DemoHome> createState() => _DemoHomeState();
}

class _DemoHomeState extends ConsumerState<DemoHome> {
  late final AppLifecycleListener _lifecycleListener;

  @override
  void initState() {
    super.initState();
    // The demo replaces AppShell as the root route, so it inherits AppShell's
    // duty to the REAL app underneath it: preference writes are debounced, and
    // a project the user was in before entering the demo can still have one
    // pending. Nothing else flushes on the way out of the process.
    _lifecycleListener = AppLifecycleListener(
      onExitRequested: () async {
        await ref.read(preferencesServiceProvider).flush();
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final id = ref.watch(selectedRegistrationIdProvider);
    // The other two surfaces (appSettings, remoteDevices) are WorkspaceShell's
    // own overlay children, so they need no branch here.
    final surface = ref.watch(workbenchSurfaceProvider);
    // Same keep-alive chain AppShell holds for the same reason: this screen is
    // the only host that survives the New Session ↔ workspace swap, and an
    // unwatched binder goes stale and then flushes from inside the next
    // mount's build(), which throws. See the comment at AppShell's watch site.
    ref.watch(agentFocusBinderProvider);
    // `resolveBackIntent` runs the handler registry BEFORE its project/session
    // history step, so an always-active handler here would leave the demo on
    // the first press instead of stepping back through it — the opposite of
    // what [BackPriority.demoExit]'s "below every surface" rank promises.
    final canStepBack = ref.watch(
      navControllerProvider.select((s) => s.canBack),
    );
    final Widget body;
    if (id == null || surface == WorkbenchSurface.newSession) {
      body = const NewSessionScreen();
      // Landing trap, identical to AppShell's: with no focused project the New
      // Session screen renders while the surface may still read `workspace`, and
      // any flow that focuses one mid-flight flips this route to WorkspaceShell,
      // unmounting the widgets that own the in-flight flow.
      if (id == null &&
          (surface == WorkbenchSurface.workspace ||
              surface == WorkbenchSurface.remoteDevices)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final s = ref.read(workbenchSurfaceProvider);
          if (ref.read(selectedRegistrationIdProvider) == null &&
              (s == WorkbenchSurface.workspace ||
                  s == WorkbenchSurface.remoteDevices)) {
            ref
                .read(workbenchSurfaceProvider.notifier)
                .set(WorkbenchSurface.newSession);
          }
        });
      }
    } else {
      body = const Scaffold(body: WorkspaceShell());
    }
    return AppBackScope(
      child: BackHandler(
        priority: BackPriority.demoExit,
        active: !canStepBack,
        onBack: () {
          exitDemoMode(ref.container);
          return true;
        },
        child: body,
      ),
    );
  }
}
