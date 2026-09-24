import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants/breakpoints.dart';
import '../models/session_entry.dart';
import '../models/workspace_view.dart';
import '../navigation/back_intent.dart';
import '../navigation/nav_controller.dart';
import '../providers/agent_transport.dart';
import '../providers/new_session_picker.dart';
import '../providers/open_target_session.dart';
import '../providers/providers.dart';
import '../providers/session_search.dart';
import '../providers/sessions.dart';
import '../providers/visible_surface.dart';
import '../util/detached.dart';
import '../utils/platform_utils.dart';
import '../widgets/account_footer.dart' show openAppSettings;
import '../widgets/projects_drawer.dart' show VisibleInDrawer;
import '../widgets/session_row.dart' show showSessionSurface;
import '../widgets/session_search_modal.dart';
import 'app_command_registry.dart';
import 'app_shortcuts.dart';
import 'shortcuts_sheet.dart';

/// Installs the app's keyboard shortcuts over [child] and offers the commands
/// that belong to no single screen.
///
/// Two dispatch paths, split by [ChordReach]:
///  * global chords are claimed by a `FocusManager` EARLY handler, ahead of
///    the focus tree, because the agent's terminal consumes every key it is
///    given — an ancestor `Shortcuts` never sees a chord while it has focus;
///  * focused chords go through an ordinary `Shortcuts`, so a terminal or
///    text field that wants the key keeps it.
///
/// Mounted once per root route (`AppShell`, `DemoHome`), inside
/// `AppBackScope`.
class AppShortcutScope extends ConsumerStatefulWidget {
  const AppShortcutScope({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AppShortcutScope> createState() => _AppShortcutScopeState();
}

class _AppShortcutScopeState extends ConsumerState<AppShortcutScope> {
  late final AppCommandRegistry _registry;

  @override
  void initState() {
    super.initState();
    _registry = ref.read(appCommandRegistryProvider);
    _registry.addActiveCheck(_isActive);
    FocusManager.instance.addEarlyKeyEventHandler(_registry.handleEarlyKey);
  }

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_registry.handleEarlyKey);
    _registry.removeActiveCheck(_isActive);
    super.dispose();
  }

  ModalRoute<Object?>? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  /// Global chords fire only while this route is on top: a dialog, menu or
  /// pushed screen owns the keyboard until it closes.
  bool _isActive() => mounted && (_route?.isCurrent ?? true);

  @override
  Widget build(BuildContext context) {
    final sidebar = ref.watch(sidebarControlProvider);
    final panel = ref.watch(contextPanelControlProvider);
    final menu = ref.watch(workspaceMenuControlProvider);
    final switchToAgent = ref.watch(switchToAgentProvider);
    final focusAgentInput = ref.watch(focusAgentInputProvider);
    final canCycle = _cycleCandidates().length > 1;

    VoidCallback? reveal(WorkspaceView view) =>
        menu == null ? null : () => menu.reveal(view);

    return AppCommandHandlers(
      handlers: {
        AppCommand.searchSessions: _searchSessions,
        AppCommand.newSession: () => enterNewSession(ref.container),
        AppCommand.openSettings: () => openAppSettings(ref.container),
        AppCommand.showShortcuts: () => detached(
          'AppShortcutScope',
          'shortcut sheet failed',
          () => showShortcutsSheet(context),
        ),
        AppCommand.goBack: () =>
            resolveBackIntent(ref.container, allowExit: false),
        AppCommand.goForward: () =>
            ref.read(navControllerProvider.notifier).forward(),
        AppCommand.nextSession: canCycle ? () => _cycleSession(1) : null,
        AppCommand.previousSession: canCycle ? () => _cycleSession(-1) : null,
        AppCommand.focusAgent:
            (switchToAgent == null && focusAgentInput == null)
            ? null
            : () {
                switchToAgent?.call();
                focusAgentInput?.call();
              },
        for (final view in WorkspaceView.values)
          AppCommand.forWorkspaceView(view): reveal(view),
        AppCommand.toggleSidebar: sidebar?.toggle,
        AppCommand.toggleContextPanel: panel?.toggle,
      },
      child: Shortcuts(
        shortcuts: {
          for (final entry in appShortcutChords().entries)
            for (final chord in entry.value)
              if (chord.reach == ChordReach.focused)
                for (final activator in chord.activators)
                  activator: _AppCommandIntent(entry.key),
        },
        child: Actions(
          actions: {_AppCommandIntent: _AppCommandAction(_registry)},
          child: widget.child,
        ),
      ),
    );
  }

  /// On a desktop wide enough for the title bar, focusing its field is all it
  /// takes: the field opens its result popup on focus. Everywhere else there is
  /// no field to focus — below [kMediumBreakpoint] and on any touch platform
  /// the search is a modal — and the chord must not be a silent no-op against
  /// a field that was never mounted.
  void _searchSessions() {
    if (isMobilePlatform ||
        MediaQuery.sizeOf(context).width < kMediumBreakpoint) {
      detached(
        'AppShortcutScope',
        'session search failed',
        () => showSessionSearch(context),
      );
      return;
    }
    ref.read(sessionSearchFocusProvider).requestFocus();
  }

  /// The focused project's sessions in drawer order — the list the user sees
  /// the chord walk through. A session mid-delete stays in the drawer but can
  /// never be focused, so it is stepped over.
  List<SessionEntry> _cycleCandidates() {
    final regId = ref.watch(selectedRegistrationIdProvider);
    if (regId == null) return const [];
    return ref
        .watch(sessionsForEntryProvider(regId))
        .whereVisibleInDrawer()
        .where((s) => !s.deleting)
        .toList(growable: false);
  }

  void _cycleSession(int delta) {
    final regId = ref.read(selectedRegistrationIdProvider);
    if (regId == null) return;
    final sessions = ref
        .read(sessionsForEntryProvider(regId))
        .whereVisibleInDrawer()
        .where((s) => !s.deleting)
        .toList(growable: false);
    if (sessions.length < 2) return;
    final current = sessions.indexWhere(
      (s) => s.id == ref.read(activeSessionIdProvider),
    );
    final next = current < 0
        ? (delta > 0 ? 0 : sessions.length - 1)
        : (current + delta) % sessions.length;
    final id = sessions[next].id;
    // Shows the session, never starts it: a stopped session stays stopped
    // until the user asks, same as arriving at one from a notification.
    if (!focusSessionInFocusedProject(ref.container, id)) return;
    showSessionSurface(ref.container, id);
  }
}

class _AppCommandIntent extends Intent {
  const _AppCommandIntent(this.command);
  final AppCommand command;
}

/// Disabled while nothing offers the command, which lets the key carry on to
/// whatever else wants it instead of being swallowed.
class _AppCommandAction extends Action<_AppCommandIntent> {
  _AppCommandAction(this.registry);
  final AppCommandRegistry registry;

  @override
  bool isEnabled(_AppCommandIntent intent) =>
      registry.handlerFor(intent.command) != null;

  @override
  Object? invoke(_AppCommandIntent intent) {
    registry.handlerFor(intent.command)?.call();
    return null;
  }
}
