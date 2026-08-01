import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants/breakpoints.dart';
import '../design/ab_colors.dart';
import '../providers/ui_attention_providers.dart';
import '../widgets/new_session/new_session_content.dart';
import '../widgets/projects_drawer.dart';
import 'app_settings_screen.dart';

// ── Screen ───────────────────────────────────────────────────────────────────

/// Landing surface for starting a new session. Responsive shell that reuses
/// the existing [ProjectsDrawer] — static on desktop (a [Row] of drawer +
/// canvas), slide-in [Drawer] on mobile — mirroring [WorkspaceShell].
///
/// The canvas ([NewSessionContent]) hosts the full flow: recent sessions
/// above a bottom-anchored composer.
class NewSessionScreen extends ConsumerStatefulWidget {
  const NewSessionScreen({super.key});

  @override
  ConsumerState<NewSessionScreen> createState() => _NewSessionScreenState();
}

class _NewSessionScreenState extends ConsumerState<NewSessionScreen> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _drawerSearchFocus = FocusNode();

  @override
  void dispose() {
    _drawerSearchFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final isMobile = width < kCompactBreakpoint;
    final surface = ref.watch(workbenchSurfaceProvider);
    final surfaceChild = _surfaceChild(surface);

    if (isMobile) {
      return Scaffold(
        key: _scaffoldKey,
        backgroundColor: context.antgrid.bgDeepest,
        drawer: Drawer(
          backgroundColor: context.antgrid.bgDeep,
          width: 304,
          child: SafeArea(
            child: ProjectsDrawer(searchFocusNode: _drawerSearchFocus),
          ),
        ),
        body: SafeArea(
          child:
              surfaceChild ??
              NewSessionCanvas(
                onOpenDrawer: () => _scaffoldKey.currentState?.openDrawer(),
              ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: context.antgrid.bgDeepest,
      body: Row(
        children: [
          ProjectsDrawer(searchFocusNode: _drawerSearchFocus),
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
