import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants/breakpoints.dart';
import '../design/ab_colors.dart';
import '../design/ab_tokens.dart';
import '../navigation/back_intent.dart';
import '../navigation/nav_controller.dart';
import '../navigation/nav_location.dart';
import '../providers/agent_transport.dart';
import '../providers/providers.dart';
import '../providers/sessions.dart';
import '../providers/ui_attention_providers.dart';
import '../providers/visible_surface.dart';
import '../services/app_settings_service.dart';
import '../utils/platform_utils.dart';
import '../widgets/new_session/new_session_content.dart';
import '../widgets/projects_drawer.dart';
import 'app_settings_screen.dart';

// ── Screen ───────────────────────────────────────────────────────────────────

/// Landing surface for starting a new session. Responsive shell that reuses
/// the existing [ProjectsDrawer] — a persistent [Row] pane on a mouse
/// desktop, the SAME docked pane (open by default, still swipeable) on a
/// touch tablet, and a real swiped-in `Scaffold.drawer` overlay only at phone
/// width — mirroring [WorkspaceShell]'s own three-way split.
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

  /// Whether the touch TABLET's docked sidebar pane is open — phone width
  /// keeps the real `Scaffold.drawer` above ([_scaffoldKey]) instead. Starts
  /// true, matching the mouse desktop's always-on rail and
  /// `WorkspaceShellState._tabletDrawerOpen`'s own default; swiping and the
  /// canvas's own hamburger both flip this same flag (see [_openDrawer]).
  bool _tabletSidebarOpen = true;

  /// The exact callback published to [openDrawerProvider], held so [deactivate]
  /// can retract ITS OWN and never the next route's (see that provider's doc).
  late final VoidCallback _publishedOpenDrawer = _openDrawer;

  /// Same identity-retraction need as [_publishedOpenDrawer], for the record
  /// published to [sidebarControlProvider]: a tear-off (`_toggleSidebar`)
  /// evaluated fresh each build is never `identical` to itself across builds,
  /// so [deactivate] captures ONE stable reference here and compares against
  /// it — the same fix `_publishedOpenDrawer` already applies to
  /// [openDrawerProvider], now also applied to the sidebar control that was
  /// missing it (unconditional retraction raced WorkspaceShell's own publish
  /// and could leave the title bar's sidebar toggle hidden after switching
  /// routes in either direction).
  late final VoidCallback _publishedToggleSidebar = _toggleSidebar;

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
    // Same lifetime again: the title bar outlives this route, so a stale
    // sidebar control would leave a toggle on WorkspaceShell governing a
    // drawer this route no longer owns. Retracted by identity too — see
    // _publishedToggleSidebar's doc.
    final sidebarNotifier = ref.read(sidebarControlProvider.notifier);
    final container = ref.container;
    scheduleMicrotask(() {
      try {
        if (identical(
          container.read(openDrawerProvider),
          _publishedOpenDrawer,
        )) {
          notifier.set(null);
        }
        if (identical(
          container.read(sidebarControlProvider)?.toggle,
          _publishedToggleSidebar,
        )) {
          sidebarNotifier.set(null);
        }
      } catch (_) {
        // Container already torn down; nothing to clear.
      }
    });
    super.deactivate();
  }

  /// Opens the sidebar regardless of which touch layout is live: a real
  /// `Scaffold.drawer` at phone width ([_scaffoldKey], only ever attached
  /// there) or the touch tablet's docked pane otherwise ([_tabletSidebarOpen]).
  void _openDrawer() {
    final scaffold = _scaffoldKey.currentState;
    if (scaffold != null) {
      if (!scaffold.isDrawerOpen) scaffold.openDrawer();
      return;
    }
    if (!_tabletSidebarOpen) setState(() => _tabletSidebarOpen = true);
  }

  bool _closeDrawer() {
    final scaffold = _scaffoldKey.currentState;
    if (scaffold != null) {
      if (!scaffold.isDrawerOpen) return false;
      scaffold.closeDrawer();
      return true;
    }
    if (_tabletSidebarOpen) {
      setState(() => _tabletSidebarOpen = false);
      return true;
    }
    return false;
  }

  void _toggleSidebar() {
    final settings = ref.read(appSettingsServiceProvider);
    unawaited(
      ref
          .read(appSettingsServiceProvider.notifier)
          .setSidebarHidden(!settings.sidebarHidden),
    );
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final isMobile = width < kCompactBreakpoint;
    final surface = ref.watch(workbenchSurfaceProvider);
    final surfaceChild = _surfaceChild(surface);

    // Phone width, any platform (including a narrow mouse-desktop window,
    // which has no room for a docked rail either): a real swipeable
    // `Scaffold.drawer`.
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

    // A touch tablet (any width >= kCompactBreakpoint): the SAME docked
    // sidebar the mouse desktop's own Row below uses — open by default,
    // rather than mobile's swiped-in overlay — but still swipeable, since
    // there's no title bar here to toggle it from (app_shell.dart never
    // mounts one on a touch platform). Mirrors
    // `WorkspaceShellState._buildTabletTouch`'s own sidebar treatment; see
    // its doc for why neither pane's WIDTH animates (only an [AnimatedSlide]
    // offset does) and why the canvas's reserved space animates via
    // [AnimatedPadding] on the same duration/curve instead, so the two move
    // in lockstep.
    if (isMobilePlatform) {
      return BackHandler(
        priority: BackPriority.drawer,
        onBack: _closeDrawer,
        child: Scaffold(
          backgroundColor: context.antgrid.bgDeepest,
          body: SafeArea(
            child: Stack(
              children: [
                GestureDetector(
                  // Translucent so the canvas keeps every tap and every
                  // vertical scroll; only a horizontal drag lands here.
                  // Rightward opens, leftward closes — the mirror image of
                  // the sidebar's own closing gesture below.
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragEnd: (details) {
                    final v = details.primaryVelocity;
                    if (v == null) return;
                    if (v > _kDrawerFlingVelocity) {
                      _openDrawer();
                    } else if (v < -_kDrawerFlingVelocity) {
                      _closeDrawer();
                    }
                  },
                  child: AnimatedPadding(
                    duration: AbTokens.motionPane,
                    curve: Curves.easeOut,
                    padding: EdgeInsets.only(
                      left: _tabletSidebarOpen ? AbTokens.drawerPaneWidth : 0,
                    ),
                    child:
                        surfaceChild ??
                        NewSessionCanvas(onOpenDrawer: _openDrawer),
                  ),
                ),
                Positioned(
                  top: 0,
                  bottom: 0,
                  left: 0,
                  width: AbTokens.drawerPaneWidth,
                  child: AnimatedSlide(
                    duration: AbTokens.motionPane,
                    curve: Curves.easeOut,
                    offset: _tabletSidebarOpen
                        ? Offset.zero
                        : const Offset(-1, 0),
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onHorizontalDragEnd: (details) {
                        final v = details.primaryVelocity;
                        if (v != null && v < -_kDrawerFlingVelocity) {
                          _closeDrawer();
                        }
                      },
                      child: ColoredBox(
                        color: context.antgrid.bgDeep,
                        child: const ProjectsDrawer(),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // From here down: a non-touch (mouse) desktop window only — any touch
    // platform already returned above, regardless of width. A narrow desktop
    // window (< kMediumBreakpoint) mounts no title bar above this route (see
    // app_shell.dart), so its inline search field doesn't exist here either —
    // the canvas gets a search button instead, mirroring mobile's. True
    // desktop keeps relying on the title bar's field, so the canvas shows none.
    final isNarrowDesktopWindow = width < kMediumBreakpoint;
    // Same gate as WorkspaceShell's: below kMediumBreakpoint the title bar
    // (and with it the restore button) doesn't mount at all, so the drawer
    // stays forced visible the whole way down to kCompactBreakpoint — hiding
    // it there would be a trap with no way back.
    final sidebarHidden =
        width >= kMediumBreakpoint &&
        ref.watch(appSettingsServiceProvider).sidebarHidden;
    // Published for the title bar's sidebar toggle, which mounts above this
    // route and cannot reach this State directly — same handover as
    // WorkspaceShell's own publish of [sidebarControlProvider].
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(sidebarControlProvider.notifier)
          .set((hidden: sidebarHidden, toggle: _publishedToggleSidebar));
    });
    // SafeArea here, unlike the mobile branch's Scaffold.drawer approach: at
    // a narrow desktop width app_shell no longer consumes system insets above
    // this route (that only happens at >= kMediumBreakpoint) — though a mouse
    // desktop window has none anyway, so this is a no-op in practice and just
    // matches the mobile branch's own belt-and-suspenders SafeArea.
    return Scaffold(
      backgroundColor: context.antgrid.bgDeepest,
      body: SafeArea(
        child: Row(
          children: [
            if (!sidebarHidden) const ProjectsDrawer(),
            Expanded(
              child:
                  surfaceChild ??
                  NewSessionCanvas(showSearchButton: isNarrowDesktopWindow),
            ),
          ],
        ),
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
  const NewSessionCanvas({
    super.key,
    this.onOpenDrawer,
    this.showSearchButton = false,
  });

  final VoidCallback? onOpenDrawer;
  final bool showSearchButton;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return NewSessionContent(
      onOpenDrawer: onOpenDrawer,
      showSearchButton: showSearchButton,
    );
  }
}
