import 'dart:async';
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

/// How often the collapsed strip re-reads the setup terminal's tail.
///
/// Sampled on a timer rather than by listening to the terminal controller:
/// a controller with no listener skips its snapshot rebuild on every byte
/// (`_refreshSnapshot`'s `hasListeners` guard), so subscribing from a strip
/// that shows ONE line would make the whole provisioning run pay a full
/// formatter pass per output frame. Polling puts a ceiling on that cost that
/// does not move with how chatty the install is.
const Duration _kTailPollInterval = Duration(milliseconds: 750);

/// Tail sampling stops at the newest line the strip can show; a `bun install`
/// progress bar redraws a single row far wider than the strip.
const int _kTailMaxChars = 240;

/// Expanded-log height. Capped against the viewport as well, so the log never
/// swallows a phone screen the agent is also on.
const double _kLogHeight = 220.0;
const double _kLogMaxViewportFraction = 0.35;

/// Provisioning state for the workspace the active session runs in.
///
/// Renders nothing for every shared session and every bridge that does not
/// report `setup`, so the common path costs one provider read and a
/// zero-sized box.
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
  Timer? _tailTimer;
  String? _tailTerminalId;
  String? _tail;

  /// The run [_tail] was sampled from. A rerun resets the transcript, so a
  /// carried-over line would describe work that is no longer happening.
  String? _runKey;

  @override
  void dispose() {
    _tailTimer?.cancel();
    super.dispose();
  }

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
      _syncTail(null, null);
      return const SizedBox.shrink();
    }

    final runKey = '$sessionId|${setup.startedAt}';
    final uiController = ref.read(sessionSetupBannerUiProvider.notifier);
    if (phase == SessionSetupPhase.running) uiController.noteRunning(runKey);
    // A success this app never saw coming is history, not news; one finished
    // while the panel was unmounted goes unannounced.
    if (ui.hiddenRunKeys.contains(runKey) ||
        (phase == SessionSetupPhase.done && !uiController.sawRunning(runKey))) {
      _syncTail(null, null);
      return const SizedBox.shrink();
    }

    // The pane below is already this same transcript, full height, while a
    // start is queued behind the run (`_ProvisioningSessionState`), so the
    // strip's own copies of it stand down — derived off the wire rather than
    // the banner and the pane having to know about each other.
    //
    // ONLY in terminal mode. A chat session renders `AgentTranscriptView` in
    // that slot (`agent_panel.dart`) and mounts no pane at all, so standing
    // down there leaves a four-minute install with no output on screen
    // anywhere — the run would be a headline and a rule and nothing else.
    final session = ref.watch(activeSessionProvider);
    final queued = sessionStartQueued(setup);
    final paneOwnsTranscript = queued && session?.mode != 'chat';
    // Folded into `expanded` so the log, the tail and the disclosure can never
    // disagree about it; a rerun re-queues a start, and the expansion set is
    // per session and outlives the run that was expanded — which is also why
    // the state itself is dropped rather than only masked.
    final expanded = ui.expandedSessionId == sessionId && !paneOwnsTranscript;
    if (paneOwnsTranscript) {
      ref
          .read(sessionSetupBannerUiProvider.notifier)
          .collapseIfExpanded(sessionId);
    }
    if (phase == SessionSetupPhase.done && !expanded) {
      ref
          .read(sessionSetupBannerUiProvider.notifier)
          .hideSuccessAfterDelay(runKey);
    }

    final running = phase == SessionSetupPhase.running;
    final terminalId = setup.terminalId;
    // While the log is open the tail is on screen in full; sampling it twice
    // would only pay the formatter again for a line the user is already
    // reading.
    _syncTail(
      running && !expanded && !paneOwnsTranscript ? terminalId : null,
      runKey,
    );

    // The agent is ALREADY working in a tree this run has not finished
    // building: `startAgent: immediate`, or a start the user released by hand.
    // A different claim from the queued wait — the commands it is about to run
    // can fail for a reason that is not its fault — so it gets the warning tone
    // and the one action left that means anything. Derived from the live run
    // plus the session's own `running` rather than from a mode flag: both
    // routes reach the identical situation, and only this surface reports it.
    final agentLive = running && (session?.running ?? false);

    final tail = _runKey == runKey ? _tail : null;
    // Resolved here rather than in the builder below: `ref.watch` is only
    // legal while this State builds, and the builder can rebuild on its own.
    final terminalService = expanded
        ? serviceWhenReady(ref, terminalServiceProvider)
        : null;
    final logTab = expanded && terminalId != null
        ? ref.watch(terminalStateProvider).value?.tabs[terminalId]
        : null;
    final action = _action(phase, agentLive, paneOwnsTranscript);
    final acting = ui.actingSessionIds.contains(sessionId);
    final headline = _headline(setup, phase, agentLive);
    void toggle() => ref
        .read(sessionSetupBannerUiProvider.notifier)
        .toggleExpanded(sessionId, runKey);

    // One scope for the whole column, at a position that never moves: the
    // strip, the notification and the log frame all read the Carbon theme,
    // while the terminal the log mounts paints itself.
    return AbCarbonScope(
      child: Builder(
        builder: (context) {
          // A run still going has nothing to dismiss to — the banner is the
          // only account of why the agent has not started yet — so it is a
          // readout, not a notification. Once the agent is already up the
          // headline is a claim about the tree it is working in, which is what
          // a notification is for; the readout follows beneath it.
          final asNotification = !running || agentLive;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (asNotification)
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
                  onClose: running
                      ? null
                      : () => ref
                            .read(sessionSetupBannerUiProvider.notifier)
                            .hide(runKey),
                  closeLabel: 'Dismiss',
                )
              else
                _buildRunningStrip(
                  context,
                  headline: headline,
                  setup: setup,
                  tail: tail,
                  expanded: expanded,
                  action: action,
                  acting: acting,
                  showDisclosure: !paneOwnsTranscript,
                  onToggle: toggle,
                  onAct: action == null
                      ? null
                      : () => _act(sessionId, action.verb),
                ),
              if (asNotification && (!paneOwnsTranscript || running))
                _buildBelowNotification(
                  context,
                  headline: headline,
                  setup: setup,
                  running: running,
                  tail: tail,
                  expanded: expanded,
                  showDisclosure: !paneOwnsTranscript,
                  onToggle: toggle,
                ),
              if (expanded) _buildLog(context, logTab, terminalService),
            ],
          );
        },
      ),
    );
  }

  CarbonNotificationKind _kind(SessionSetupPhase phase) => switch (phase) {
    SessionSetupPhase.failed => CarbonNotificationKind.error,
    // A live agent over a half-built tree is the same claim as an interrupted
    // run: what it does next may fail for a reason that is not its fault.
    SessionSetupPhase.interrupted ||
    SessionSetupPhase.running => CarbonNotificationKind.warning,
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
      child: SizedBox(
        width: double.infinity,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: CarbonSpacing.spacing05,
            vertical: CarbonSpacing.spacing02,
          ),
          child: child,
        ),
      ),
    );
  }

  /// The measure; [SetupElapsed] is the clock beside it.
  ///
  /// The elapsed reading is what separates a slow step from a hung one — a
  /// four-minute `bun install` prints nothing for most of its run, and the
  /// bar alone does not move either.
  ///
  /// Never animated: it sits beside live output, where a perpetual sweep is
  /// motion nobody asked for.
  Widget _progressBar(String headline, SessionSetup setup) => CarbonProgressBar(
    size: CarbonProgressBarSize.small,
    animateIndeterminate: false,
    // 0-based index: the fraction is the work already behind the current
    // step, which is the only part that is actually done.
    value: setup.stepCount > 0 ? setup.stepIndex / setup.stepCount : null,
    label: headline,
    hideLabel: true,
  );

  Widget _buildRunningStrip(
    BuildContext context, {
    required String headline,
    required SessionSetup setup,
    required String? tail,
    required bool expanded,
    required ({String label, SessionSetupAction verb})? action,
    required bool acting,
    required bool showDisclosure,
    required VoidCallback onToggle,
    required VoidCallback? onAct,
  }) {
    final t = CarbonTheme.of(context);
    return _strip(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: CarbonSpacing.spacing02,
                  ),
                  child: Text(
                    headline,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: t.typography.body.copyWith(
                      color: t.colors.textPrimary,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: CarbonSpacing.spacing03),
              SetupElapsed(startedAt: setup.startedAt),
              // No disclosure while the pane below is already the transcript:
              // the chevron would mount a SECOND view of the same terminal
              // directly above the first.
              if (showDisclosure)
                CarbonButton.iconOnly(
                  icon: CarbonIcon(
                    expanded
                        ? CarbonIcons.chevronDown
                        : CarbonIcons.chevronRight,
                  ),
                  semanticLabel: expanded ? 'Hide setup log' : 'View setup log',
                  onPressed: onToggle,
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: CarbonSpacing.spacing02),
            child: _progressBar(headline, setup),
          ),
          if (tail != null) _tailLine(t, tail),
          if (action != null)
            CarbonButton(
              label: action.label,
              kind: CarbonButtonKind.ghost,
              size: CarbonButtonSize.small,
              onPressed: acting ? null : onAct,
            ),
        ],
      ),
    );
  }

  /// What sits under the notification: the log disclosure, and while the run
  /// is still going the measure, the clock and the newest line. The
  /// notification has no slot for a second control, so the disclosure is its
  /// own button directly beneath it.
  Widget _buildBelowNotification(
    BuildContext context, {
    required String headline,
    required SessionSetup setup,
    required bool running,
    required String? tail,
    required bool expanded,
    required bool showDisclosure,
    required VoidCallback onToggle,
  }) {
    final t = CarbonTheme.of(context);
    return _strip(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showDisclosure)
            CarbonButton(
              label: expanded ? 'Hide setup log' : 'View setup log',
              kind: CarbonButtonKind.ghost,
              size: CarbonButtonSize.small,
              icon: CarbonIcon(
                expanded ? CarbonIcons.chevronDown : CarbonIcons.chevronRight,
              ),
              expanded: expanded,
              onPressed: onToggle,
            ),
          if (running) ...[
            Padding(
              padding: const EdgeInsets.symmetric(
                vertical: CarbonSpacing.spacing02,
              ),
              child: Row(
                children: [
                  Expanded(child: _progressBar(headline, setup)),
                  const SizedBox(width: CarbonSpacing.spacing03),
                  SetupElapsed(startedAt: setup.startedAt),
                ],
              ),
            ),
            if (tail != null) _tailLine(t, tail),
          ],
        ],
      ),
    );
  }

  /// The newest output line, in code type. A named step alone leaves a
  /// four-minute install looking hung; the line that keeps changing is what
  /// says otherwise.
  Widget _tailLine(CarbonThemeData t, String tail) => Padding(
    padding: const EdgeInsets.only(bottom: CarbonSpacing.spacing02),
    child: Text(
      tail,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: t.typography.code.copyWith(color: t.colors.textHelper),
    ),
  );

  String _headline(
    SessionSetup setup,
    SessionSetupPhase phase,
    bool agentLive,
  ) {
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
      // "Preparing" is a promise the agent is waiting on. Once it is not, the
      // headline has to name what the user is actually looking at: a session
      // they can type into, over a workspace that is still being built.
      SessionSetupPhase.running when agentLive =>
        where.isEmpty
            ? 'Workspace still installing…'
            : 'Workspace still installing — $where',
      SessionSetupPhase.running =>
        where.isEmpty ? 'Preparing workspace…' : 'Preparing workspace — $where',
      SessionSetupPhase.done => 'Workspace ready',
      SessionSetupPhase.failed => switch ((message, where)) {
        (final String m, _) when m.isNotEmpty => 'Setup failed — $m',
        (_, final String w) when w.isNotEmpty => 'Setup failed at $w',
        _ => 'Setup failed',
      },
      SessionSetupPhase.interrupted => "Setup didn't finish",
      SessionSetupPhase.skipped => 'Setup skipped',
      SessionSetupPhase.unknown => 'Preparing workspace…',
    };
  }

  ({String label, SessionSetupAction verb})? _action(
    SessionSetupPhase phase,
    bool agentLive,
    bool paneOwnsTranscript,
  ) {
    // The pane below offers both verbs already, and its copies are the ones
    // sized for a decision — two `Start agent now` buttons 100px apart are not
    // alternatives but a race, since only one of them can end the run and each
    // tracks its own in-flight state.
    if (paneOwnsTranscript) return null;
    return switch (phase) {
      // Releasing an agent that is already up is meaningless, so the live case
      // gets the one verb still worth offering: end the install holding the
      // tree the agent is working in.
      SessionSetupPhase.running when agentLive => (
        label: 'Cancel setup',
        verb: SessionSetupAction.cancel,
      ),
      // Named for what it does rather than for the `skip` verb underneath: it
      // releases the queued agent start and leaves the run going — the "the
      // deps are already cached" case, which is the common one. Nothing about
      // the run itself is skipped, which is what the old label claimed.
      SessionSetupPhase.running => (
        label: 'Start agent now',
        verb: SessionSetupAction.skip,
      ),
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
    container
        .read(sessionSetupBannerUiProvider.notifier)
        .setActing(sessionId, true);
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
          container
              .read(sessionSetupBannerUiProvider.notifier)
              .setActing(sessionId, false);
        }
      },
    );
  }

  /// Starts, retargets or stops the tail sampler. Called from `build`, which
  /// only ever schedules a timer here — the sample itself lands on a later
  /// frame.
  void _syncTail(String? terminalId, String? runKey) {
    if (runKey != _runKey) {
      _runKey = runKey;
      _tail = null;
    }
    if (terminalId == null || terminalId != _tailTerminalId) {
      _tailTimer?.cancel();
      _tailTimer = null;
      _tailTerminalId = terminalId;
      if (terminalId == null) {
        // Dropped with the sampler, not just on a run change: `runKey` is
        // stable across a run's own settle, so clearing only there would
        // freeze the last polled line under "Workspace ready" forever — and
        // render it again directly above the transcript the user just
        // expanded, which is the duplicate this sampler exists to avoid.
        _tail = null;
        return;
      }
    }
    if (_tailTimer != null) return;
    _tailTimer = Timer.periodic(
      _kTailPollInterval,
      (_) => _sampleTail(terminalId),
    );
  }

  void _sampleTail(String terminalId) {
    if (!mounted) return;
    final tabs = ref.read(terminalStateProvider).value?.tabs;
    final tab = tabs?[terminalId];
    if (tab == null) return;
    String? newest;
    final lines = tab.ghostty.lines;
    for (var i = lines.length - 1; i >= 0; i--) {
      final line = lines[i].trim();
      if (line.isNotEmpty) {
        newest = line.length > _kTailMaxChars
            ? line.substring(line.length - _kTailMaxChars)
            : line;
        break;
      }
    }
    if (newest == null || newest == _tail) return;
    setState(() => _tail = newest);
  }
}
