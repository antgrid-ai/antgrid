import 'package:flutter/material.dart' show Scaffold;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../navigation/back_intent.dart';
import '../navigation/nav_controller.dart';
import '../providers/demo_mode.dart';
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
/// Both halves matter: without the surface branch the drawer's "New Session"
/// button — its primary action, two taps from the first screen — sets a surface
/// nothing reads and appears dead; and without the [Scaffold] the mouse-desktop
/// layout is a bare `Row` with no [Material] ancestor, which every `InkWell` in
/// the drawer throws on.
class DemoHome extends ConsumerWidget {
  const DemoHome({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The other two surfaces (appSettings, remoteDevices) are WorkspaceShell's
    // own overlay children, so they need no branch here.
    final newSession =
        ref.watch(workbenchSurfaceProvider) == WorkbenchSurface.newSession;
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
    return AppBackScope(
      child: BackHandler(
        priority: BackPriority.demoExit,
        active: !canStepBack,
        onBack: () {
          exitDemoMode(ref.container);
          return true;
        },
        child: newSession
            ? const NewSessionScreen()
            : const Scaffold(body: WorkspaceShell()),
      ),
    );
  }
}
