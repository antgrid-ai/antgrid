import 'dart:math' as math;

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_carbon.dart';
import '../design/widgets/ab_toast.dart';
import '../models/session_entry.dart';
import '../models/terminal_models.dart';
import '../providers/agent_transport.dart';
import '../providers/providers.dart';
import '../providers/session_setup.dart';
import '../providers/sessions.dart';
import '../services/terminal_service.dart';
import '../util/detached.dart';
import 'carbon_empty_state.dart';
import 'session_setup_progress.dart';
import 'terminal_view_wrapper.dart';

/// Log height inside the details panel. Capped against the viewport as well,
/// so the log never swallows a phone screen the agent is also on.
const double _kLogHeight = 220.0;
const double _kLogMaxViewportFraction = 0.35;

/// How much of the area the details panel may take before it scrolls.
const double _kPanelMaxFraction = 0.6;

/// Keys the running-phase close apart from the run key itself: a hidden run key
/// also hides the ended-state notification, and a run the user closed while it
/// was going must still be able to announce that it failed.
const String _kRunningCloseSuffix = '|running';

/// Provisioning state for the workspace the active session runs in.
///
/// Renders nothing for every shared session and every bridge that does not
/// report `setup`, so the common path costs one provider read and a
/// zero-sized box.
///
/// While a run is going this is ONE slim strip, whether the agent waits behind
/// the run or is already working in the tree: setup is background work, and the
/// strip must not compete with the agent for attention. The step list, the log
/// and the cancel live in a panel behind its chevron. The panel is capped at a
/// fraction of the height its host passes down, so a host that floats it over
/// the content in a `Stack` must hand it the Stack's height, not unbounded.
///
/// Persistent by design in its failure states. A setup failure means the agent
/// is working in a half-provisioned tree — the thing that explains every
/// confusing build error it is about to hit — and a toast would be gone by the
/// time the user comes back from another session, leaving them with no account
/// of why the tree is broken.
class SessionSetupBanner extends ConsumerStatefulWidget {
  const SessionSetupBanner({super.key});

  @override
  ConsumerState<SessionSetupBanner> createState() => _SessionSetupBannerState();
}

class _SessionSetupBannerState extends ConsumerState<SessionSetupBanner> {
  @override
  Widget build(BuildContext context) {
    final sessionId = ref.watch(activeSessionIdProvider);
    final setup = ref.watch(activeSessionSetupProvider);
    final phase = sessionSetupPhase(setup);
    final ui = ref.watch(sessionSetupBannerUiProvider);
    // `unknown` is a state this build cannot name — say nothing rather than
    // guess at either "still going" or "finished".
    if (sessionId == null ||
        setup == null ||
        phase == SessionSetupPhase.unknown) {
      return const SizedBox.shrink();
    }

    final runKey = '$sessionId|${setup.startedAt}';
    final uiController = ref.read(sessionSetupBannerUiProvider.notifier);
    if (phase == SessionSetupPhase.running) uiController.noteRunning(runKey);
    final closedWhileRunning = ui.hiddenRunKeys.contains(
      '$runKey$_kRunningCloseSuffix',
    );
    final running = phase == SessionSetupPhase.running;
    // A success this app never saw coming is history, not news; one finished
    // while the panel was unmounted goes unannounced, and so does one the user
    // closed the strip on.
    if (ui.hiddenRunKeys.contains(runKey) ||
        (running && closedWhileRunning) ||
        (phase == SessionSetupPhase.done &&
            (closedWhileRunning || !uiController.sawRunning(runKey)))) {
      return const SizedBox.shrink();
    }

    final expanded = ui.expandedSessionId == sessionId;
    if (phase == SessionSetupPhase.done && !expanded) {
      uiController.hideSuccessAfterDelay(runKey);
    }

    final session = ref.watch(activeSessionProvider);
    final queued = sessionStartQueued(setup);
    // A terminal-mode session mounts the waiting pane, which carries its own
    // "Start now"; a chat session mounts no pane, so the strip carries it.
    // The pane sits under an open panel, so a terminal session's panel carries
    // a release of its own while the start is queued.
    final stripStart = running && queued && session?.mode == 'chat';
    final panelStart = running && queued && !stripStart;
    final terminalId = setup.terminalId;
    // Resolved here rather than in the builder below: `ref.watch` is only
    // legal while this State builds, and the builder can rebuild on its own.
    final terminalService = expanded
        ? serviceWhenReady(ref, terminalServiceProvider)
        : null;
    final logTab = expanded && terminalId != null
        ? ref.watch(terminalStateProvider).value?.tabs[terminalId]
        : null;
    final action = _endedAction(phase);
    final actingVerb = ui.actingVerbs[sessionId];
    final acting = actingVerb != null;
    final headline = _headline(setup, phase);
    void toggle() => uiController.toggleExpanded(sessionId, runKey);
    void closeStrip() {
      // An open panel would otherwise outlive the strip and unfold under the
      // ended-state notification the moment the run settles.
      if (expanded) uiController.toggleExpanded(sessionId, runKey);
      uiController.hide('$runKey$_kRunningCloseSuffix');
    }

    // One scope for the whole column, at a position that never moves: the
    // strip, the notification and the panel all read the Carbon theme, while
    // the terminal the log mounts paints itself.
    return AbCarbonScope(
      child: Builder(
        builder: (context) => LayoutBuilder(
          builder: (context, box) {
            // Hosts hand this the room it really has (see AgentPanel); the
            // screen only stands in when one forgets, since a keyboard or a
            // short window leaves less than the screen to float over.
            final area = box.hasBoundedHeight
                ? box.maxHeight
                : MediaQuery.sizeOf(context).height;
            // Never taller than the room it floats over: a long failure reason
            // at a large text size on a short screen scrolls inside the banner
            // rather than spilling past the bottom of the pane.
            return SingleChildScrollView(
              child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (running)
                  _buildRunningStrip(
                    context,
                    headline: headline,
                    setup: setup,
                    expanded: expanded,
                    showStart: stripStart,
                    actingVerb: actingVerb,
                    onToggle: toggle,
                    onClose: closeStrip,
                    onStart: () => _act(sessionId, SessionSetupAction.skip),
                  )
                else ...[
                  CarbonNotification(
                    kind: _kind(phase),
                    subtitle: headline,
                    action: action == null
                        ? null
                        : CarbonNotificationAction(
                            label: action.label,
                            onPressed: acting
                                ? null
                                : () => _act(sessionId, action.verb),
                          ),
                    onClose: () => uiController.hide(runKey),
                    closeLabel: 'Dismiss',
                  ),
                  _buildLogDisclosure(context, expanded, toggle),
                ],
                if (expanded)
                  _buildPanel(
                    context,
                    setup: setup,
                    running: running,
                    showStart: panelStart,
                    actingVerb: actingVerb,
                    maxHeight: area * _kPanelMaxFraction,
                    logTab: logTab,
                    terminalService: terminalService,
                    onCancel: () => _act(sessionId, SessionSetupAction.cancel),
                    onStart: () => _act(sessionId, SessionSetupAction.skip),
                  ),
              ],
              ),
            );
          },
        ),
      ),
    );
  }

  CarbonNotificationKind _kind(SessionSetupPhase phase) => switch (phase) {
    SessionSetupPhase.failed => CarbonNotificationKind.error,
    SessionSetupPhase.interrupted => CarbonNotificationKind.warning,
    SessionSetupPhase.done => CarbonNotificationKind.success,
    _ => CarbonNotificationKind.info,
  };

  /// The surface and rule shared by everything that sits under the headline,
  /// so the pieces read as one banner.
  Widget _strip(BuildContext context, {required Widget child}) {
    final t = CarbonTheme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: t.colors.layer01,
        border: Border(
          bottom: BorderSide(color: t.borderSubtle(CarbonLayer.of(context))),
        ),
      ),
      child: SizedBox(width: double.infinity, child: child),
    );
  }

  /// The headline, the clock, the disclosure and the close, with the measure
  /// under them.
  ///
  /// The elapsed reading is what separates a slow step from a hung one — a
  /// four-minute `bun install` prints nothing for most of its run, and the
  /// bar alone does not move either. The bar is never animated: it sits beside
  /// live output, where a perpetual sweep is motion nobody asked for.
  Widget _buildRunningStrip(
    BuildContext context, {
    required String headline,
    required SessionSetup setup,
    required bool expanded,
    required bool showStart,
    required SessionSetupAction? actingVerb,
    required VoidCallback onToggle,
    required VoidCallback onClose,
    required VoidCallback onStart,
  }) {
    final t = CarbonTheme.of(context);
    return _strip(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: CarbonSpacing.spacing05),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    headline,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.typography.body.copyWith(
                      color: t.colors.textPrimary,
                    ),
                  ),
                ),
                const SizedBox(width: CarbonSpacing.spacing03),
                SetupElapsed(startedAt: setup.startedAt),
                CarbonButton.iconOnly(
                  icon: CarbonIcon(
                    expanded ? CarbonIcons.chevronUp : CarbonIcons.chevronDown,
                  ),
                  semanticLabel: expanded
                      ? 'Hide setup details'
                      : 'View setup details',
                  onPressed: onToggle,
                ),
                // A queued chat session has no pane to carry the release, so
                // closing the strip would strand the user behind the run.
                if (!showStart)
                  CarbonButton.iconOnly(
                    icon: const CarbonIcon(CarbonIcons.close),
                    semanticLabel: 'Hide setup status',
                    onPressed: onClose,
                  )
                else
                  const SizedBox(width: CarbonSpacing.spacing03),
              ],
            ),
          ),
          if (showStart)
            Padding(
              padding: const EdgeInsets.only(left: CarbonSpacing.spacing03),
              child: CarbonButton(
                label: 'Start now',
                kind: CarbonButtonKind.ghost,
                size: CarbonButtonSize.small,
                icon: const CarbonIcon(CarbonIcons.play),
                busy: actingVerb == SessionSetupAction.skip,
                onPressed: actingVerb == null ? onStart : null,
              ),
            ),
          CarbonProgressBar(
            size: CarbonProgressBarSize.small,
            animateIndeterminate: false,
            // 0-based index: the fraction is the work already behind the
            // current step, which is the only part that is actually done.
            value: setup.stepCount > 0 ? setup.stepIndex / setup.stepCount : null,
            label: headline,
            hideLabel: true,
          ),
        ],
      ),
    );
  }

  /// The notification has no slot for a second control, so the log disclosure
  /// is its own button directly beneath it.
  Widget _buildLogDisclosure(
    BuildContext context,
    bool expanded,
    VoidCallback onToggle,
  ) => _strip(
    context,
    child: Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: CarbonSpacing.spacing05,
        vertical: CarbonSpacing.spacing02,
      ),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: CarbonButton(
          label: expanded ? 'Hide setup log' : 'View setup log',
          kind: CarbonButtonKind.ghost,
          size: CarbonButtonSize.small,
          icon: CarbonIcon(
            expanded ? CarbonIcons.chevronDown : CarbonIcons.chevronRight,
          ),
          expanded: expanded,
          onPressed: onToggle,
        ),
      ),
    ),
  );

  String _headline(SessionSetup setup, SessionSetupPhase phase) {
    final step = setup.stepCount > 0
        ? '${setup.stepIndex + 1} of ${setup.stepCount}'
        : null;
    final name = setup.stepName;
    final where = [
      ?step,
      if (name != null && name.isNotEmpty) name,
    ].join(' · ');
    final message = setup.message;
    return switch (phase) {
      SessionSetupPhase.running =>
        where.isEmpty
            ? 'Setting up workspace…'
            : 'Setting up workspace · $where',
      SessionSetupPhase.done => 'Workspace ready',
      SessionSetupPhase.failed => switch ((message, where)) {
        (final String m, _) when m.isNotEmpty => 'Setup failed — $m',
        (_, final String w) when w.isNotEmpty => 'Setup failed at $w',
        _ => 'Setup failed',
      },
      SessionSetupPhase.interrupted => "Setup didn't finish",
      SessionSetupPhase.skipped => 'Setup skipped',
      SessionSetupPhase.unknown => 'Setting up workspace…',
    };
  }

  ({String label, SessionSetupAction verb})? _endedAction(
    SessionSetupPhase phase,
  ) => switch (phase) {
    SessionSetupPhase.failed => (
      label: 'Run setup again',
      verb: SessionSetupAction.rerun,
    ),
    SessionSetupPhase.interrupted || SessionSetupPhase.skipped => (
      label: 'Run setup',
      verb: SessionSetupAction.rerun,
    ),
    _ => null,
  };

  /// What the chevron opens, under the strip: the step list, the setup
  /// transcript and, while the run is going, the cancel. Scrolls past
  /// [maxHeight] so it never takes the whole area it floats over.
  Widget _buildPanel(
    BuildContext context, {
    required SessionSetup setup,
    required bool running,
    required bool showStart,
    required SessionSetupAction? actingVerb,
    required double maxHeight,
    required TerminalTab? logTab,
    required TerminalService? terminalService,
    required VoidCallback onCancel,
    required VoidCallback onStart,
  }) {
    final t = CarbonTheme.of(context);
    return DecoratedBox(
      key: const ValueKey('setup-panel'),
      decoration: BoxDecoration(
        color: t.colors.background,
        border: Border(
          bottom: BorderSide(color: t.borderSubtle(CarbonLayer.of(context))),
        ),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (running) SetupStepLedger(setup: setup),
              _buildLog(context, logTab, terminalService),
              if (running)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: CarbonSpacing.spacing03,
                    vertical: CarbonSpacing.spacing02,
                  ),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Wrap(
                      children: [
                        CarbonButton(
                          label: 'Cancel setup',
                          kind: CarbonButtonKind.dangerGhost,
                          size: CarbonButtonSize.small,
                          icon: const CarbonIcon(CarbonIcons.close),
                          // Kept pressable while its own verb is busy: a null
                          // handler paints dimmed, which reads as a control
                          // that died under the press. Busy already swallows
                          // the tap.
                          busy: actingVerb == SessionSetupAction.cancel,
                          onPressed:
                              actingVerb == null ||
                                  actingVerb == SessionSetupAction.cancel
                              ? onCancel
                              : null,
                        ),
                        // The waiting pane under an open panel is covered, so
                        // the release has to be reachable from here.
                        if (showStart)
                          CarbonButton(
                            label: 'Start now',
                            kind: CarbonButtonKind.ghost,
                            size: CarbonButtonSize.small,
                            icon: const CarbonIcon(CarbonIcons.play),
                            busy: actingVerb == SessionSetupAction.skip,
                            onPressed: actingVerb == null ? onStart : null,
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// The setup transcript, mounted on the run's own PTY. Reachable during the
  /// run and after it — a successful setup's log is still the record of what
  /// the workspace was built from.
  Widget _buildLog(
    BuildContext context,
    TerminalTab? tab,
    TerminalService? terminalService,
  ) {
    final t = CarbonTheme.of(context);
    final height = math.min(
      _kLogHeight,
      MediaQuery.sizeOf(context).height * _kLogMaxViewportFraction,
    );
    return Container(
      // Keyed so the mounted terminal survives the strip above it gaining or
      // losing a child.
      key: const ValueKey('setup-log'),
      height: height,
      decoration: BoxDecoration(
        color: t.colors.background,
        border: Border(
          bottom: BorderSide(color: t.borderSubtle(CarbonLayer.of(context))),
        ),
      ),
      child: tab == null || terminalService == null
          // A reconnect recovers the transcript from the bridge, so this is a
          // window rather than a dead end — it must not read as one.
          ? const CarbonEmptyState.compact(heading: 'Setup log not available yet')
          : TerminalViewWrapper(tab: tab, terminalService: terminalService),
    );
  }

  void _act(String sessionId, SessionSetupAction verb) {
    // Captured before the first await: the shell rebuilds this banner away on
    // every session switch, and a `ref` read after that throws.
    final container = ref.container;
    final entryId = container.read(selectedRegistrationIdProvider);
    if (entryId == null) return;
    final ui = container.read(sessionSetupBannerUiProvider.notifier);
    // One verb in flight per session, shared with the waiting pane: they are
    // alternatives for a run only one of them can end.
    if (container
        .read(sessionSetupBannerUiProvider)
        .actingVerbs
        .containsKey(sessionId)) {
      return;
    }
    ui.setActing(sessionId, verb);
    detached(
      'SessionSetupBanner',
      'session:setup ${verb.wire} failed',
      () async {
        try {
          final result = await runSessionSetupAction(
            container,
            entryId: entryId,
            sessionId: sessionId,
            action: verb,
          );
          if (!mounted || result.ok) return;
          // The user pressed something and is owed an answer: nothing else on
          // screen changes when a setup verb is refused, so a log line alone
          // would make a refusal indistinguishable from a dropped tap. Only
          // while that session is still the one on screen, though — `detached`
          // has logged it either way, and a refusal narrated over a DIFFERENT
          // session's banner reads as that session having failed.
          if (container.read(activeSessionIdProvider) != sessionId) return;
          showAbToast(
            context,
            '${sessionSetupFailureCopy(verb)} — ${result.error}',
          );
        } finally {
          ui.setActing(sessionId, null);
        }
      },
    );
  }
}
