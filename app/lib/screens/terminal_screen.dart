import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_empty_state.dart';
import '../design/widgets/ab_loading.dart';
import '../design/widgets/ab_snack_bar.dart';
import '../models/terminal_models.dart';
import '../project/project_session_registry.dart';
import '../providers/agent_transport.dart';
import '../providers/new_session_picker.dart' show enterNewSession;
import '../providers/providers.dart';
import '../providers/session_setup.dart';
import '../providers/sessions.dart';
import '../services/sessions_service.dart' show SessionOperationException;
import '../util/ab_log.dart';
import '../util/detached.dart';
import '../widgets/session_start_refusal.dart';
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
    final terminalService = session
        .servicesForCheckout(ref.watch(focusedCheckoutIdProvider))
        .terminalService;
    final activeSession = ref.watch(activeSessionProvider);
    // The id, not the live row's id: the row is null for the whole window in
    // which the session list re-resolves, and a null id here opens the legacy
    // fallback below onto whatever terminal happens to be first.
    final activeSessionId = ref.watch(activeSessionIdProvider);

    final terminalState = terminalAsync.value ?? const TerminalState();

    // Empty-state branches — render BEFORE picking a tab so the legacy
    // type=='agent' fallback can't shadow a deliberate stopped state.
    if (activeSession != null && !activeSession.running) {
      // A queued session reports `running: false` for the whole setup run, so
      // this branch is reached by one whose agent is on its way — calling it
      // stopped, over a Start button that only re-enters the same gate, is the
      // one account of itself the workspace must never give.
      if (sessionStartQueued(
        ref.watch(sessionSetupProvider(activeSession.id)),
      )) {
        return _ProvisioningSessionState(sessionId: activeSession.id);
      }
      return activeSession.mode == 'chat'
          ? _StoppedSessionEmptyState(
              sessionId: activeSession.id,
              title: 'Chat stopped',
              buttonLabel: 'Restart',
              pendingLabel: 'Restarting…',
            )
          : _StoppedSessionEmptyState(
              sessionId: activeSession.id,
              title: 'Session stopped',
              buttonLabel: 'Start',
              pendingLabel: 'Starting…',
            );
    }

    // The tab keyed by the active session id. The legacy "first agent-typed
    // tab" lookup answers a wire with no session model at all, so it is reached
    // ONLY when no session is focused: with one focused it renders a DIFFERENT
    // session's terminal, which is what a chat session (never has a tab of its
    // own) and a just-started one (tab not here yet) both hit.
    final TerminalTab? agentTab = activeSessionId != null
        ? terminalState.tabs[activeSessionId]
        : terminalState.tabs.values.where((t) => t.type == 'agent').firstOrNull;

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
        // The agent panel's own terminal: where a "send to agent" lands, so
        // this is the copy that owns focusAgentInputProvider.
        isAgentSurface: true,
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
class _StoppedSessionEmptyState extends ConsumerStatefulWidget {
  final String sessionId;
  final String title;
  final String buttonLabel;

  /// Label while the start is in flight — the press can wait out a project
  /// warm-up plus a bridge round trip, so the button has to say it is working.
  final String pendingLabel;

  const _StoppedSessionEmptyState({
    required this.sessionId,
    required this.title,
    required this.buttonLabel,
    required this.pendingLabel,
  });

  @override
  ConsumerState<_StoppedSessionEmptyState> createState() =>
      _StoppedSessionEmptyStateState();
}

class _StoppedSessionEmptyStateState
    extends ConsumerState<_StoppedSessionEmptyState> {
  /// True from the press until the start is answered, refused or timed out.
  bool _starting = false;

  /// Uses `State.context` and guards every post-await UI touch on `mounted`
  /// rather than taking a [BuildContext] parameter — the two are the same
  /// element here, and only the State's own flag is a valid guard for it.
  Future<void> _start() async {
    // Latched rather than merely inert: the button below is non-interactive
    // while this runs, but a keyboard activation racing the first frame would
    // otherwise queue a second `session:start` behind the first.
    if (_starting) return;
    setState(() => _starting = true);
    try {
      await _startInner();
    } finally {
      // A start that lands unmounts this widget — `session:updated` flips
      // `running` and TerminalScreen renders the terminal instead — so the
      // common success path never reaches a setState here.
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _startInner() async {
    final sessionId = widget.sessionId;
    // Resolved off the session, not through the throwing façade: the guard in
    // [TerminalScreen] proves the session was resolved when this widget was
    // BUILT, which a tap arriving after a reconnect or LRU evict no longer
    // implies — and the throw would be unhandled from here.
    //
    // WARMED rather than read synchronously: this button is the only way back
    // from a stopped session, and the windows where the project isn't live —
    // the reconnect and LRU-evict ones — are exactly when the user reaches for
    // it. Reading `focusedServiceOrNull` here answered null in those windows and
    // dropped the press. The id is captured before the await so a focus switch
    // mid-warm can't retarget the start at another project's session.
    final container = ref.container;
    final entryId = container.read(selectedRegistrationIdProvider);
    final svc = entryId == null
        ? null
        : await warmServiceFor(container, entryId, (s) => s.sessionsService);
    if (svc == null) {
      // Reported, not `?.`-skipped: a press that reaches neither the agent nor
      // the log is indistinguishable from a dead button.
      AbLog.error(
        'TerminalScreen',
        'session start skipped: project did not warm',
        fields: {'sessionId': sessionId, 'entryId': entryId},
      );
      if (mounted) {
        showAbSnackBar(
          context,
          "Couldn't reach this project. Reopen it and try again.",
        );
      }
      return;
    }
    try {
      await svc.start(sessionId, raiseRefusal: true);
    } on SessionOperationException catch (error) {
      // The bridge ANSWERED, and the answer was no — most often because this
      // session's isolated checkout is gone. That is a different sentence from
      // the timeout below, which invites a retry: retrying a refusal just earns
      // the same refusal.
      if (mounted) reportStartRefusal(context, error);
    } on TimeoutException {
      // The button the user just pressed is still on screen and the session is
      // still stopped, so a silent swallow reads as a dropped tap. A dropped
      // reply doesn't prove the start failed — the bridge may have spawned the
      // PTY anyway, in which case `session:updated` replaces this empty state
      // on its own — so the copy invites a retry without claiming either way.
      if (mounted) {
        showAbSnackBar(
          context,
          "The agent didn't answer. If the session doesn't come up in a moment, "
          'try again.',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: context.antgrid.bgDeepest,
      child: AbEmptyState(
        title: widget.title,
        action: AbButton(
          label: _starting ? widget.pendingLabel : widget.buttonLabel,
          // The dot is what separates "busy" from "broken": `onTap: null` also
          // buys AbButton's dimmed disabled state, and dimming alone on a button
          // the user just pressed reads as a control that died under the press.
          // It pulses by scale, so it stays legible at that opacity.
          leading: _starting ? const AbLoadingDot(size: 8) : null,
          // Inert while in flight, matching SessionModeControl: a second press
          // would queue a second `session:start` behind the first. No tooltip or
          // reason — the user just pressed it.
          onTap: _starting
              ? null
              // `onTap` is a VoidCallback, so nothing awaits the start —
              // detached rather than an `async` closure whose rejection would
              // land on the top-level handler as a fatal.
              : () =>
                    detached('TerminalScreen', 'session start failed', _start),
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

/// Rendered inside the terminal pane while an isolated session's agent is
/// QUEUED behind its checkout's `worktree.setup` run.
///
/// The pane IS the transcript here rather than the banner's one-line tail: for
/// the whole run the setup PTY is the only live output the session has, and the
/// state this replaced left it collapsed behind a chevron above an empty pane
/// that called the session stopped.
///
/// Both verbs it offers end the wait, and they are not the same answer: `skip`
/// releases the agent and lets the run finish anyway ("the deps are cached"),
/// `cancel` kills the run first. The bridge has accepted `cancel` since the
/// verb shipped; this is the first surface to offer it.
class _ProvisioningSessionState extends ConsumerStatefulWidget {
  const _ProvisioningSessionState({required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<_ProvisioningSessionState> createState() =>
      _ProvisioningSessionStateState();
}

class _ProvisioningSessionStateState
    extends ConsumerState<_ProvisioningSessionState> {
  /// The verb in flight, or null. Held as the verb rather than a bool so the
  /// pending dot lands on the control the user actually pressed — and shared
  /// across both, since they are alternatives and a second press would race the
  /// first for a run only one of them can end.
  SessionSetupAction? _acting;

  Future<void> _act(SessionSetupAction verb) async {
    if (_acting != null) return;
    setState(() => _acting = verb);
    // Captured before the first await: a settling run rebuilds this pane away
    // — the agent spawns, the session flips `running` — and a `ref` read after
    // that throws.
    final container = ref.container;
    final entryId = container.read(selectedRegistrationIdProvider);
    try {
      if (entryId == null) return;
      final result = await runSessionSetupAction(
        container,
        entryId: entryId,
        sessionId: widget.sessionId,
        action: verb,
      );
      if (!mounted || result.ok) return;
      // Nothing else on screen changes when a setup verb is refused, so a log
      // line alone would make a refusal indistinguishable from a dropped press.
      showAbSnackBar(
        context,
        '${sessionSetupFailureCopy(verb)} — ${result.error}',
      );
    } finally {
      // The success path usually never reaches this: releasing the agent
      // spawns the PTY, which flips `running` and renders the terminal over
      // this widget.
      if (mounted) setState(() => _acting = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.antgrid;
    final setup = ref.watch(sessionSetupProvider(widget.sessionId));
    final terminalId = setup?.terminalId;
    final terminalService = serviceWhenReady(ref, terminalServiceProvider);
    final tabs =
        ref.watch(terminalStateProvider).value?.tabs ??
        const <String, TerminalTab>{};
    final tab = terminalId == null ? null : tabs[terminalId];
    return ColoredBox(
      color: colors.bgDeepest,
      child: Column(
        children: [
          Expanded(
            child: tab == null || terminalService == null
                // Not a dead end: the run has yet to report the PTY it spawned,
                // or a reconnect has yet to recover the transcript. The wait
                // itself is the same either way, so the copy states it rather
                // than reporting the missing log.
                ? const AbEmptyState(
                    title: 'Preparing workspace…',
                    subtitle: 'The agent starts when provisioning finishes.',
                  )
                : TerminalViewWrapper(
                    key: ValueKey(tab.terminalId),
                    tab: tab,
                    terminalService: terminalService,
                  ),
          ),
          _buildActions(colors),
        ],
      ),
    );
  }

  Widget _buildActions(AbColors colors) {
    return Container(
      decoration: BoxDecoration(
        color: colors.bgElevated,
        border: Border(top: BorderSide(color: colors.borderSubtle)),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AbTokens.space12,
        vertical: AbTokens.space8,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Waiting for workspace setup',
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXs,
                color: colors.textMuted,
              ),
            ),
          ),
          _action(SessionSetupAction.cancel, 'Cancel setup'),
          const SizedBox(width: AbTokens.space8),
          _action(
            SessionSetupAction.skip,
            'Start agent now',
            variant: AbButtonVariant.primary,
          ),
        ],
      ),
    );
  }

  Widget _action(
    SessionSetupAction verb,
    String label, {
    AbButtonVariant variant = AbButtonVariant.normal,
  }) {
    final acting = _acting;
    return AbButton(
      label: label,
      variant: variant,
      // The dot is what separates "busy" from "broken": `onTap: null` also buys
      // AbButton's dimmed disabled state, and dimming alone on a control the
      // user just pressed reads as one that died under the press.
      leading: acting == verb ? const AbLoadingDot(size: 8) : null,
      onTap: acting != null
          // `onTap` is a VoidCallback, so nothing awaits this — detached rather
          // than an `async` closure whose rejection would reach
          // PlatformDispatcher.onError as a fatal.
          ? null
          : () => detached(
              'TerminalScreen',
              'session:setup ${verb.wire} failed',
              () => _act(verb),
            ),
    );
  }
}
