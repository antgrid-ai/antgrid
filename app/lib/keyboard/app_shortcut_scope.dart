import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants/breakpoints.dart';
import '../models/session_entry.dart';
import '../navigation/back_intent.dart';
import '../navigation/nav_controller.dart';
import '../providers/agent_transport.dart';
import '../providers/new_session_picker.dart';
import '../providers/open_target_session.dart';
import '../providers/providers.dart';
import '../providers/session_search.dart';
import '../providers/sessions.dart';
import '../util/detached.dart';
import '../utils/platform_utils.dart';
import '../widgets/account_footer.dart' show openAppSettings;
import '../widgets/projects_drawer.dart' show VisibleInDrawer;
import '../widgets/session_row.dart' show showSessionSurface;
import '../widgets/session_search_modal.dart';
import 'app_command_registry.dart';
import 'app_shortcuts.dart';
import 'command_palette.dart';
import 'focus_regions.dart';
import 'shortcuts_sheet.dart';
import 'user_keybindings.dart';

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
    // Loads the user's rebindings and rebuilds the focused-chord map below when
    // they change; the global chords read the table at each key press.
    ref.watch(userKeybindingsProvider);
    final sidebar = ref.watch(sidebarControlProvider);
    final panel = ref.watch(contextPanelControlProvider);
    // Only the yes/no: watching the list itself rebuilt this root scope on
    // every status or title change in the focused project.
    final regId = ref.watch(selectedRegistrationIdProvider);
    // Capped at 2: all the handlers below need is none, one, or several.
    final sessionCount = regId == null
        ? 0
        : ref.watch(
            sessionsForEntryProvider(
              regId,
            ).select((all) => _cycleCandidates(all).length.clamp(0, 2)),
          );
    final canCycle = sessionCount > 1;
    final agentFocusable = ref.watch(focusAgentInputProvider) != null;

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
        AppCommand.commandPalette: () => detached(
          'AppShortcutScope',
          'command palette failed',
          () => showCommandPalette(context, ref),
        ),
        AppCommand.focusAgent: agentFocusable ? _focusAgent : null,
        AppCommand.focusNextArea: () => _cycleArea(1),
        AppCommand.focusPreviousArea: () => _cycleArea(-1),
        AppCommand.goToSession: sessionCount > 0 ? _goToSession : null,
        AppCommand.goBack: () =>
            resolveBackIntent(ref.container, allowExit: false),
        AppCommand.goForward: () =>
            ref.read(navControllerProvider.notifier).forward(),
        AppCommand.nextSession: canCycle ? () => _cycleSession(1) : null,
        AppCommand.previousSession: canCycle ? () => _cycleSession(-1) : null,
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
  static List<SessionEntry> _cycleCandidates(List<SessionEntry> all) => all
      .whereVisibleInDrawer()
      .where((s) => !s.deleting)
      .toList(growable: false);

  /// Ctrl/⌘+1–8 is that session in drawer order, 9 the last one — the
  /// browsers' tab rule.
  void _goToSession() {
    final regId = ref.read(selectedRegistrationIdProvider);
    if (regId == null) return;
    final sessions = _cycleCandidates(
      ref.read(sessionsForEntryProvider(regId)),
    );
    if (sessions.isEmpty) return;
    final digit = ref.read(appCommandRegistryProvider).dispatchingChordIndex;
    final index = digit >= 8 ? sessions.length - 1 : digit;
    if (index >= sessions.length) return;
    final id = sessions[index].id;
    if (!focusSessionInFocusedProject(ref.container, id)) return;
    showSessionSurface(ref.container, id);
  }

  void _focusAgent() {
    ref.read(switchToAgentProvider)?.call();
    final input = ref.read(focusAgentInputProvider);
    if (input != null) {
      input();
    } else {
      ref.read(focusAreaRegistryProvider).focus(AppFocusArea.agent);
    }
  }

  /// F6 order: projects, agent, context panel — skipping a hidden pane rather
  /// than opening it, since F6 walks what is on screen.
  void _cycleArea(int delta) {
    final areas = ref.read(focusAreaRegistryProvider);
    final sidebarHidden = ref.read(sidebarControlProvider)?.hidden ?? false;
    final panelHidden = ref.read(contextPanelControlProvider)?.hidden ?? false;
    final visible = [
      for (final area in AppFocusArea.values)
        if (areas.isMounted(area) &&
            !(area == AppFocusArea.projects && sidebarHidden) &&
            !(area == AppFocusArea.context && panelHidden))
          area,
    ];
    if (visible.isEmpty) return;
    final at = visible.indexOf(areas.current ?? AppFocusArea.agent);
    for (var step = 1; step <= visible.length; step++) {
      final next = visible[((at < 0 ? 0 : at) + delta * step) % visible.length];
      if (next == AppFocusArea.agent &&
          ref.read(focusAgentInputProvider) != null) {
        _focusAgent();
        return;
      }
      if (areas.focus(next)) return;
    }
  }

  void _cycleSession(int delta) {
    final regId = ref.read(selectedRegistrationIdProvider);
    if (regId == null) return;
    final sessions = _cycleCandidates(
      ref.read(sessionsForEntryProvider(regId)),
    );
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
      !registry.paused && registry.handlerFor(intent.command) != null;

  @override
  Object? invoke(_AppCommandIntent intent) {
    registry.handlerFor(intent.command)?.call();
    return null;
  }
}
