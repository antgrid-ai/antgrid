import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants/breakpoints.dart';
import '../design/ab_colors.dart';
import '../navigation/back_intent.dart';
import '../navigation/nav_controller.dart';
import '../navigation/nav_location.dart';
import '../providers/agent_transport.dart';
import '../providers/providers.dart';
import '../providers/sessions.dart';
import '../providers/ui_attention_providers.dart';
import '../providers/visible_surface.dart';
import '../widgets/new_session/new_session_content.dart';
import '../widgets/projects_drawer.dart';
import 'app_settings_screen.dart';

// ── Screen ───────────────────────────────────────────────────────────────────

/// Landing surface for starting a new session. Responsive shell that reuses
/// the existing [ProjectsDrawer] — static on desktop (a [Row] of drawer +
/// canvas), a swipeable page on mobile — mirroring [WorkspaceShell].
///
/// The canvas ([NewSessionContent]) hosts the full flow: recent sessions
/// above a bottom-anchored composer.
class NewSessionScreen extends ConsumerStatefulWidget {
  const NewSessionScreen({super.key});

  @override
  ConsumerState<NewSessionScreen> createState() => _NewSessionScreenState();
}

/// Minimum rightward fling velocity that reveals the drawer.
///
/// This route has no PageView to read an overscroll off, so the swipe is a
/// plain fling over the canvas. Velocity-gated so a slow horizontal drag inside
/// the recent-sessions list still belongs to the list.
const double _kDrawerFlingVelocity = 700.0;

class _NewSessionScreenState extends ConsumerState<NewSessionScreen> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  /// The exact callback published to [openDrawerProvider], held so [deactivate]
  /// can retract ITS OWN and never the next route's (see that provider's doc).
  late final VoidCallback _publishedOpenDrawer = _openDrawer;

  @override
  void initState() {
    super.initState();
    // No workspace tab exists on this route, so no content back handler may
    // claim a press here.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(visibleWorkspaceViewProvider.notifier).set(null);
      ref.read(openDrawerProvider.notifier).set(_publishedOpenDrawer);
    });
  }

  @override
  void deactivate() {
    // Same lifetime rule as WorkspaceShell's: the callback closes over this
    // State's controller, and the drawer button lives above this route.
    // Retracted by identity, not unconditionally — see openDrawerProvider's doc:
    // WorkspaceShell has already published its own by the time this runs.
    final notifier = ref.read(openDrawerProvider.notifier);
    final container = ref.container;
    scheduleMicrotask(() {
      try {
        if (identical(
          container.read(openDrawerProvider),
          _publishedOpenDrawer,
        )) {
          notifier.set(null);
        }
      } catch (_) {
        // Container already torn down; nothing to clear.
      }
    });
    super.deactivate();
  }

  void _openDrawer() {
    final scaffold = _scaffoldKey.currentState;
    if (scaffold != null && !scaffold.isDrawerOpen) scaffold.openDrawer();
  }

  bool _closeDrawer() {
    final scaffold = _scaffoldKey.currentState;
    if (!(scaffold?.isDrawerOpen ?? false)) return false;
    scaffold!.closeDrawer();
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final isMobile = width < kCompactBreakpoint;
    final surface = ref.watch(workbenchSurfaceProvider);
    final surfaceChild = _surfaceChild(surface);

    if (isMobile) {
      return BackHandler(
        priority: BackPriority.drawer,
        onBack: _closeDrawer,
        child: Scaffold(
          key: _scaffoldKey,
          backgroundColor: context.antgrid.bgDeepest,
          // The fling below is the way in, and it works from anywhere; an edge
          // strip on top of it would only hand the OS back gesture something to
          // collide with.
          drawerEdgeDragWidth: 0,
          drawer: Drawer(
            backgroundColor: context.antgrid.bgDeep,
            width: 304,
            child: SafeArea(
              child: const ProjectsDrawer(),
            ),
          ),
          body: SafeArea(
            child:
                surfaceChild ??
                GestureDetector(
                  // Translucent so the canvas keeps every tap and every
                  // vertical scroll; only a horizontal drag lands here.
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragEnd: (details) {
                    final v = details.primaryVelocity;
                    if (v != null && v > _kDrawerFlingVelocity) _openDrawer();
                  },
                  child: NewSessionCanvas(onOpenDrawer: _openDrawer),
                ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: context.antgrid.bgDeepest,
      body: Row(
        children: [
          const ProjectsDrawer(),
          Expanded(child: surfaceChild ?? const NewSessionCanvas()),
        ],
      ),
    );
  }

  Widget? _surfaceChild(WorkbenchSurface surface) {
    void close() {
      ref
          .read(workbenchSurfaceProvider.notifier)
          .set(WorkbenchSurface.workspace);
      // Mirrors workspace_shell's close(): closing an overlay is a navigation,
      // and without the commit nav.current still points at the settings entry,
      // so the next back press is a silent no-op. Records the surface we
      // actually land on — AppShell's reconciler forces newSession straight
      // back on when no project is focused.
      final target = ref.read(selectedTargetProvider);
      ref
          .read(navControllerProvider.notifier)
          .commit(
            NavLocation(
              target: target,
              surface: target == null
                  ? WorkbenchSurface.newSession
                  : WorkbenchSurface.workspace,
              sessionId: ref.read(activeSessionIdProvider),
            ),
          );
    }

    return switch (surface) {
      WorkbenchSurface.appSettings => AppSettingsScreen(onClose: close),
      WorkbenchSurface.remoteDevices ||
      WorkbenchSurface.workspace ||
      WorkbenchSurface.newSession => null,
    };
  }
}

// ── Canvas ───────────────────────────────────────────────────────────────────

/// Body wrapper for the New Session screen.
///
/// Extracted to avoid duplicating [onOpenDrawer] wiring across the mobile and
/// desktop branches of [NewSessionScreen]. Pass [onOpenDrawer] only from the
/// mobile branch; the desktop branch omits it.
class NewSessionCanvas extends ConsumerWidget {
  const NewSessionCanvas({super.key, this.onOpenDrawer});

  final VoidCallback? onOpenDrawer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return NewSessionContent(onOpenDrawer: onOpenDrawer);
  }
}
