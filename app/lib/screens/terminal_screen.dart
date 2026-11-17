import 'dart:async';

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_carbon.dart';
import '../design/widgets/ab_toast.dart';
import '../models/terminal_models.dart';
import '../project/checkout_readiness.dart';
import '../project/project_session_registry.dart';
import '../providers/agent_transport.dart';
import '../providers/checkout_readiness.dart' show checkoutReadinessProvider;
import '../providers/new_session_picker.dart' show enterNewSession;
import '../providers/providers.dart';
import '../providers/session_setup.dart';
import '../providers/sessions.dart';
import '../services/pending_reply.dart' show SessionDownException;
import '../services/sessions_service.dart' show SessionOperationException;
import '../util/ab_log.dart';
import '../util/detached.dart';
import '../widgets/carbon_empty_state.dart';
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
    // Watched unconditionally: the branch below returns before a
    // TerminalState exists to read `attach` off, which is exactly the window
    // this provider names — `session`/`terminalAsync` alone can't.
    final readiness = ref.watch(checkoutReadinessProvider);
    if (session == null || !terminalAsync.hasValue) {
      return _PaneWait(message: _bootstrapWaitMessage(readiness));
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
        // Keyed by session, for the same reason `AgentTranscriptView` is
        // (agent_panel.dart): without it Flutter reuses one State across a
        // session switch, and the in-flight verb — plus the refusal snackbar
        // it is waiting on — would land on whichever session is on screen by
        // the time the reply arrives.
        return _ProvisioningSessionState(
          key: ValueKey(activeSession.id),
          sessionId: activeSession.id,
        );
      }
      return activeSession.mode == 'chat'
          ? _StoppedSessionEmptyState(
              sessionId: activeSession.id,
              title: 'Chat stopped',
              buttonLabel: 'Restart',
              buttonIcon: CarbonIcons.restart,
              pendingLabel: 'Restarting…',
            )
          : _StoppedSessionEmptyState(
              sessionId: activeSession.id,
              title: 'Session stopped',
              buttonLabel: 'Start',
              buttonIcon: CarbonIcons.play,
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
      // The race is only ever won by waiting it out — except when readiness
      // itself has given up. A per-terminal failure never escalates this;
      // only the checkout-wide verdict does.
      if (readiness == CheckoutReadiness.stalled) {
        // Retry re-pulls this checkout's durable state rather than re-dialling
        // the machine: `stalled` is only reachable with the supervisor already
        // connected, so the connection is not what failed, and re-establishing
        // it would re-pull every checkout's tree to fix one workspace's
        // missing tabs. No in-flight label — the re-ask clears the verdict
        // synchronously, so this arm is gone before one could paint.
        return _PaneSurface(
          child: CarbonEmptyState(
            error: true,
            heading: "couldn't reach the agent",
            action: CarbonButton(
              label: 'Retry',
              onPressed: () => detached(
                'TerminalScreen',
                'retry checkout attach failed',
                terminalService.retryCheckoutAttach,
              ),
            ),
          ),
        );
      }
      return const _PaneWait(message: 'waiting for agent...');
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

/// A Carbon piece's own backdrop. Carbon is scoped around each non-terminal
/// state rather than around [TerminalScreen]'s whole output, so the live
/// terminal (and the Antgrid chrome around it) never inherits a CarbonTheme.
class _PaneSurface extends StatelessWidget {
  const _PaneSurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => AbCarbonScope(
    child: Builder(
      builder: (context) => ColoredBox(
        color: CarbonTheme.of(context).colors.background,
        child: child,
      ),
    ),
  );
}

/// A wait with nothing to show yet, centred in the pane.
class _PaneWait extends StatelessWidget {
  const _PaneWait({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => _PaneSurface(
    child: SizedBox.expand(
      child: Center(
        child: CarbonLoading(size: CarbonLoadingSize.small, message: message),
      ),
    ),
  );
}

/// Copy for the pre-session-list wait, keyed off the checkout-wide verdict
/// rather than the local `session`/`terminalAsync` pair — this fires before
/// either has anything to derive a message from.
String _bootstrapWaitMessage(CheckoutReadiness readiness) =>
    switch (readiness) {
      CheckoutReadiness.reachingMachine => 'reaching machine',
      CheckoutReadiness.openingSession => 'opening session',
      CheckoutReadiness.cold ||
      CheckoutReadiness.blocked ||
      CheckoutReadiness.loadingScreen ||
      CheckoutReadiness.stalled ||
      CheckoutReadiness.ready => 'waiting for agent...',
    };

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

  /// Gives the button an icon so that busy swaps only the glyph for the spinner: a
  /// text-only Carbon button hides its label while busy, and the label is what
  /// says the press was heard.
  final CarbonIcons buttonIcon;

  /// Label while the start is in flight — the press can wait out a project
  /// warm-up plus a bridge round trip, so the button has to say it is working.
  final String pendingLabel;

  const _StoppedSessionEmptyState({
    required this.sessionId,
    required this.title,
    required this.buttonLabel,
    required this.buttonIcon,
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
        showAbToast(
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
      if (mounted) reportStartRefusal(AbToaster.maybeOf(context), error);
    } on TimeoutException catch (_) {
      // The button the user just pressed is still on screen and the session is
      // still stopped, so a silent swallow reads as a dropped tap. A dropped
      // reply doesn't prove the start failed — the bridge may have spawned the
      // PTY anyway, in which case `session:updated` replaces this empty state
      // on its own — so the copy invites a retry without claiming either way.
      if (mounted) {
        showAbToast(
          context,
          "The agent didn't answer. If the session doesn't come up in a moment, "
          'try again.',
        );
      }
    } on SessionDownException catch (e) {
      if (mounted) showAbToast(context, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return _PaneSurface(
      child: CarbonEmptyState(
        icon: CarbonIcons.terminal,
        heading: widget.title,
        action: CarbonButton(
          label: _starting ? widget.pendingLabel : widget.buttonLabel,
          icon: CarbonIcon(widget.buttonIcon),
          // Busy rather than disabled: a disabled button dims, and dimming on a
          // button the user just pressed reads as a control that died under the
          // press. Busy also swallows taps; `_starting` still latches the
          // handler for a keyboard activation racing the first frame.
          busy: _starting,
          // `onPressed` is a VoidCallback, so nothing awaits the start —
          // detached rather than an `async` closure whose rejection would
          // land on the top-level handler as a fatal.
          onPressed: () =>
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
    return _PaneSurface(
      child: CarbonEmptyState(
        icon: CarbonIcons.terminal,
        heading: 'No active session',
        action: CarbonButton(
          label: 'New session',
          icon: const CarbonIcon(CarbonIcons.add),
          onPressed: () => enterNewSession(ref.container),
        ),
      ),
    );
  }
}
/// Rendered inside the terminal pane while an isolated session's agent is
/// QUEUED behind its checkout's `worktree.setup` run.
///
/// Deliberately calm: the run's progress, step list, log and cancel all live in
/// the setup strip floating above this pane (`SessionSetupBanner`), so what is
/// left to say here is when the agent starts and the one way to hurry it.
///
/// The verb releases the agent and lets the run finish anyway ("the deps are
/// cached"); it does not stop the run. It shares the banner's one-in-flight
/// guard, since this and the strip's cancel are alternatives for a run only one
/// of them can end.
class _ProvisioningSessionState extends ConsumerStatefulWidget {
  const _ProvisioningSessionState({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<_ProvisioningSessionState> createState() =>
      _ProvisioningSessionStateState();
}

class _ProvisioningSessionStateState
    extends ConsumerState<_ProvisioningSessionState> {
  /// Whether THIS pane's verb is in flight, so the busy spinner lands on the
  /// control the user pressed rather than on a press made elsewhere.
  bool _starting = false;

  Future<void> _start() async {
    final container = ref.container;
    final ui = container.read(sessionSetupBannerUiProvider.notifier);
    if (_starting ||
        container
            .read(sessionSetupBannerUiProvider)
            .actingVerbs
            .containsKey(widget.sessionId)) {
      return;
    }
    const verb = SessionSetupAction.skip;
    setState(() => _starting = true);
    ui.setActing(widget.sessionId, verb);
    // Captured before the first await: a settling run rebuilds this pane away
    // — the agent spawns, the session flips `running` — and a `ref` read after
    // that throws.
    final entryId = container.read(selectedRegistrationIdProvider);
    try {
      if (entryId == null) {
        // A project mid-re-resolve has no registration to address, which is
        // reachable across a run this long. Saying so is the whole contract
        // below: a press that produces no wire traffic and no message is
        // indistinguishable from a dropped tap.
        if (mounted) {
          showAbToast(
            context,
            '${sessionSetupFailureCopy(verb)} — this project is reconnecting.',
          );
        }
        return;
      }
      final result = await runSessionSetupAction(
        container,
        entryId: entryId,
        sessionId: widget.sessionId,
        action: verb,
      );
      if (!mounted || result.ok) return;
      // Only while this session is still the one on screen: a refusal narrated
      // over a DIFFERENT session's pane reads as that session having failed.
      // The key above makes this rare rather than impossible — the pane is
      // rebuilt away on a switch, but a reply can still land first.
      if (container.read(activeSessionIdProvider) != widget.sessionId) return;
      // Nothing else on screen changes when a setup verb is refused, so a log
      // line alone would make a refusal indistinguishable from a dropped press.
      showAbToast(
        context,
        '${sessionSetupFailureCopy(verb)} — ${result.error}',
      );
    } finally {
      // The success path usually never reaches the setState: releasing the
      // agent spawns the PTY, which flips `running` and renders the terminal
      // over this widget.
      ui.setActing(widget.sessionId, null);
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final otherVerbActing =
        !_starting &&
        ref.watch(
          sessionSetupBannerUiProvider.select(
            (s) => s.actingVerbs.containsKey(widget.sessionId),
          ),
        );
    return _PaneSurface(
      child: Builder(
        builder: (context) {
          final t = CarbonTheme.of(context);
          return SizedBox.expand(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(CarbonSpacing.spacing05),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'The agent starts when setup ends',
                      textAlign: TextAlign.center,
                      style: t.typography.body.copyWith(
                        color: t.colors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: CarbonSpacing.spacing05),
                    CarbonButton(
                      label: 'Start now',
                      kind: CarbonButtonKind.tertiary,
                      icon: const CarbonIcon(CarbonIcons.play),
                      // Busy rather than disabled: a disabled button dims, and
                      // dimming on a control the user just pressed reads as one
                      // that died under the press.
                      busy: _starting,
                      // `onPressed` is a VoidCallback, so nothing awaits this —
                      // detached rather than an `async` closure whose rejection
                      // would reach PlatformDispatcher.onError as a fatal.
                      onPressed: otherVerbActing
                          ? null
                          : () => detached(
                              'TerminalScreen',
                              'session:setup ${SessionSetupAction.skip.wire} failed',
                              _start,
                            ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
