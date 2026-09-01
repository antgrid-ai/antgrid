import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_empty_state.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_inline_banner.dart';
import '../design/widgets/ab_progress_rule.dart';
import '../design/widgets/ab_snack_bar.dart';
import '../models/session_entry.dart';
import '../models/terminal_models.dart';
import '../providers/agent_transport.dart';
import '../providers/providers.dart';
import '../providers/session_setup.dart';
import '../providers/sessions.dart';
import '../util/detached.dart';
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
    if (ui.hiddenRunKeys.contains(runKey)) {
      _syncTail(null, null);
      return const SizedBox.shrink();
    }

    // The pane below is already this same transcript, full height, while a
    // start is queued behind the run (`_ProvisioningSessionState`), so the
    // strip's own two copies of it stand down — derived off the same wire field
    // rather than the banner and the pane having to know about each other.
    // Folded into `expanded` so the log, the tail and the disclosure can never
    // disagree about it; a rerun re-queues a start, and the expansion set is
    // per session and outlives the run that was expanded.
    final queued = sessionStartQueued(setup);
    final expanded = ui.expandedSessionId == sessionId && !queued;
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
    _syncTail(running && !expanded && !queued ? terminalId : null, runKey);

    // The agent is ALREADY working in a tree this run has not finished
    // building: `startAgent: immediate`, or a start the user released by hand.
    // A different claim from the queued wait — the commands it is about to run
    // can fail for a reason that is not its fault — so it gets the warning tone
    // and the one action left that means anything. Derived from the live run
    // plus the session's own `running` rather than from a mode flag: both
    // routes reach the identical situation, and only this surface reports it.
    final agentLive = running && (ref.watch(activeSessionProvider)?.running ?? false);

    final colors = context.antgrid;
    final tone = switch (phase) {
      SessionSetupPhase.failed ||
      SessionSetupPhase.interrupted => colors.warning,
      SessionSetupPhase.running =>
        agentLive ? colors.warning : colors.textSecondary,
      _ => colors.textMuted,
    };
    final tail = _runKey == runKey ? _tail : null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AbInlineBanner(
          text: _headline(setup, phase, agentLive),
          color: tone,
          trailing: _buildActions(
            sessionId,
            runKey,
            phase,
            expanded,
            queued,
            agentLive,
          ),
        ),
        if (running) _buildProgress(setup),
        if (tail != null) _buildTail(context, tail),
        if (expanded) _buildLog(context, terminalId),
      ],
    );
  }

  /// The measure and the clock, on their own line rather than in the banner's
  /// trailing row: the headline already names a step and would be squeezed off
  /// a phone by anything else competing for that width.
  ///
  /// The elapsed reading is what separates a slow step from a hung one — a
  /// four-minute `bun install` prints nothing for most of its run, and the
  /// rule alone does not move either.
  Widget _buildProgress(SessionSetup setup) {
    final colors = context.antgrid;
    return Container(
      color: colors.bgElevated,
      padding: const EdgeInsets.symmetric(
        horizontal: AbTokens.space12,
        vertical: AbTokens.space2,
      ),
      child: Row(
        children: [
          Expanded(
            child: AbProgressRule(
              // 0-based index: the fraction is the work already behind the
              // current step, which is the only part that is actually done.
              fraction: setup.stepCount > 0
                  ? setup.stepIndex / setup.stepCount
                  : null,
            ),
          ),
          const SizedBox(width: AbTokens.space8),
          SetupElapsed(startedAt: setup.startedAt, color: colors.textMuted),
        ],
      ),
    );
  }

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

  Widget _buildActions(
    String sessionId,
    String runKey,
    SessionSetupPhase phase,
    bool expanded,
    bool queued,
    bool agentLive,
  ) {
    final action = switch (phase) {
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
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (action != null) ...[
          const SizedBox(width: AbTokens.space8),
          AbButton(
            label: action.label,
            compact: true,
            onTap:
                ref
                    .read(sessionSetupBannerUiProvider)
                    .actingSessionIds
                    .contains(sessionId)
                ? null
                : () => _act(sessionId, action.verb),
          ),
        ],
        const SizedBox(width: AbTokens.space4),
        // No disclosure while the pane below is already the transcript: the
        // chevron would mount a SECOND view of the same terminal directly above
        // the first.
        if (!queued)
          AbIconButton(
            icon: expanded ? AbIcons.chevronDown : AbIcons.chevronRight,
            tooltip: expanded ? 'Hide setup log' : 'View setup log',
            onTap: () => ref
                .read(sessionSetupBannerUiProvider.notifier)
                .toggleExpanded(sessionId, runKey),
          ),
        // A run still going has nothing to dismiss to — the banner is the only
        // account of why the agent has not started yet.
        if (phase != SessionSetupPhase.running)
          AbIconButton(
            icon: AbIcons.close,
            tooltip: 'Dismiss',
            onTap: () =>
                ref.read(sessionSetupBannerUiProvider.notifier).hide(runKey),
          ),
      ],
    );
  }

  /// The newest output line, in mono. A named step alone leaves a four-minute
  /// install looking hung; the line that keeps changing is what says otherwise.
  Widget _buildTail(BuildContext context, String tail) {
    final colors = context.antgrid;
    return Container(
      decoration: BoxDecoration(
        color: colors.bgElevated,
        border: Border(bottom: BorderSide(color: colors.borderSubtle)),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AbTokens.space12,
        vertical: AbTokens.space6,
      ),
      width: double.infinity,
      child: Text(
        tail,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AbTokens.monoStyle(
          fontSize: AbTokens.fontXxs,
          color: colors.textMuted,
        ),
      ),
    );
  }

  /// The setup transcript, mounted on the run's own PTY. Reachable during the
  /// run and after it — a successful setup's log is still the record of what
  /// the workspace was built from.
  Widget _buildLog(BuildContext context, String? terminalId) {
    final colors = context.antgrid;
    final terminalService = serviceWhenReady(ref, terminalServiceProvider);
    final tabs =
        ref.watch(terminalStateProvider).value?.tabs ??
        const <String, TerminalTab>{};
    final tab = terminalId == null ? null : tabs[terminalId];
    final height = math.min(
      _kLogHeight,
      MediaQuery.sizeOf(context).height * _kLogMaxViewportFraction,
    );
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: colors.bgDeepest,
        border: Border(bottom: BorderSide(color: colors.borderSubtle)),
      ),
      child: tab == null || terminalService == null
          // A reconnect recovers the transcript from the bridge, so this is a
          // window rather than a dead end — it must not read as one.
          ? const AbEmptyState.compact(title: 'Setup log not available yet')
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
          showAbSnackBar(
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
