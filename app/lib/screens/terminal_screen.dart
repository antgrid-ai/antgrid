import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_empty_state.dart';
import '../design/widgets/ab_loading.dart';
import '../models/terminal_models.dart';
import '../project/project_session_registry.dart';
import '../providers/agent_transport.dart';
import '../providers/new_session_picker.dart' show enterNewSession;
import '../providers/providers.dart';
import '../providers/sessions.dart';
import '../widgets/terminal_view_wrapper.dart';

/// Shows the terminal for the currently active session.
///
/// When multi-session is wired (an `activeSessionId` is set), the matching tab
/// is selected by id — PTYs spawned via `session:start` use the session id as
/// the terminalId. When the active session is stopped (or no session exists),
/// the body is replaced with an empty-state widget — but only the terminal
/// pane area: the surrounding [AgentPanel] toolbar and command tray remain
/// mounted (spec: empty state scoped to the terminal pane).
class TerminalScreen extends ConsumerWidget {
  const TerminalScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projectId = ref.watch(selectedRegistrationIdProvider);
    final session = projectId == null
        ? null
        : ref.watch(projectSessionProvider(projectId)).value;
    final terminalAsync = ref.watch(terminalStateProvider);
    if (session == null || !terminalAsync.hasValue) {
      return const AbLoading(message: 'waiting for agent...');
    }
    final terminalService = session.terminalService;
    final activeSession = ref.watch(activeSessionProvider);
    final activeSessionId = activeSession?.id;

    final terminalState = terminalAsync.value ?? const TerminalState();

    // Empty-state branches — render BEFORE picking a tab so the legacy
    // type=='agent' fallback can't shadow a deliberate stopped state.
    if (activeSession != null && !activeSession.running) {
      return activeSession.mode == 'chat'
          ? _StoppedSessionEmptyState(
              sessionId: activeSession.id,
              title: 'Chat stopped',
              buttonLabel: 'Restart',
            )
          : _StoppedSessionEmptyState(
              sessionId: activeSession.id,
              title: 'Session stopped',
              buttonLabel: 'Start',
            );
    }

    // Prefer the tab keyed by the active session id; fall back to the
    // legacy "first agent-typed tab" lookup before sessions are wired up.
    final TerminalTab? agentTab =
        (activeSessionId != null
            ? terminalState.tabs[activeSessionId]
            : null) ??
        terminalState.tabs.values.where((t) => t.type == 'agent').firstOrNull;

    if (agentTab == null) {
      // No active session AND no agent-typed tab. The normal path is for
      // _bootstrapSessions (workspace_shell) to route an empty project to the
      // New Session page before this state is visible. This branch is a
      // defensive fallback — reached during the brief window before bootstrap
      // completes or a brief race between bootstrap and the session list
      // settling. Gate on an actually-empty, non-loading list to avoid hiding
      // a real spinner.
      if (activeSession == null) {
        final state = ref.watch(freshSessionsStateProvider);
        if (state != null && !state.loading && state.sessions.isEmpty) {
          return const _NoSessionEmptyState();
        }
      }
      return const AbLoading(message: 'waiting for agent...');
    }

    return ClipRect(
      child: TerminalViewWrapper(
        key: ValueKey(agentTab.terminalId),
        tab: agentTab,
        terminalService: terminalService,
      ),
    );
  }
}

/// Rendered inside the terminal/chat pane when the focused session is in the
/// `stopped` state. Project-open auto-starts the most-recent session, so
/// this is reached via explicit `Stop` or a crashed PTY — the user taps the
/// button to respawn (for chat sessions, this resumes + rehydrates the
/// transcript via the bridge rather than spawning a fresh session). The
/// agent panel toolbar and command tray remain mounted around this widget so
/// the user keeps access to project controls (status, git branch, settings,
/// mobile-access).
class _StoppedSessionEmptyState extends ConsumerWidget {
  final String sessionId;
  final String title;
  final String buttonLabel;
  const _StoppedSessionEmptyState({
    required this.sessionId,
    required this.title,
    required this.buttonLabel,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ColoredBox(
      color: context.antgrid.bgDeepest,
      child: AbEmptyState(
        title: title,
        action: AbButton(
          label: buttonLabel,
          onTap: () async {
            // Resolved off the session, not through the throwing façade: the
            // guard above proves the session was resolved when this widget was
            // BUILT, which a tap arriving after a reconnect or LRU evict no
            // longer implies — and the throw would be unhandled from here.
            final svc = focusedServiceOrNull(
              ref.container,
              (s) => s.sessionsService,
            );
            await svc?.start(sessionId);
          },
        ),
      ),
    );
  }
}

/// Defensive fallback rendered inside the terminal pane when no session is
/// focused and the session list is known-empty. Normally _bootstrapSessions
/// routes an empty project to the New Session page before this is visible;
/// this widget is a safety net for a requestList transient or a brief race.
/// Tapping the button routes to the New Session page so the user picks an
/// agent (consistent with the no-cold-start policy).
class _NoSessionEmptyState extends ConsumerWidget {
  const _NoSessionEmptyState();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ColoredBox(
      color: context.antgrid.bgDeepest,
      child: AbEmptyState(
        title: 'No active session',
        action: AbButton(
          label: 'New session',
          onTap: () => enterNewSession(ref.container),
        ),
      ),
    );
  }
}
