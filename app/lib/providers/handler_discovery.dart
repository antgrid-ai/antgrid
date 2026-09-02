import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/agent_work_status.dart';
import '../models/handler_state.dart';
import '../storage/first_run_store.dart';
import 'agent_catalog.dart';
import 'agent_transport.dart';
import 'first_run.dart';
import 'now_ticker.dart';
import 'project_work_status.dart';
import 'providers.dart';
import 'sessions.dart';

/// How long the focused session must sit blocked in `attention` before the
/// away-moment hint offers Handler. Long enough that the user has plausibly
/// walked away; a user actively answering never sees it.
const kHandlerAwayHintAfter = Duration(minutes: 5);

/// Whether the away-moment Handler hint should show, as a pure derivation so
/// the full condition matrix is testable without a container.
///
/// `agentObservable != false`: never hint Handler at a session it has said it
/// cannot watch. `!handlerArmedOnce`: discovery accomplished retires the hint
/// forever; `!handlerAwayHintDismissed` is the user's explicit kill.
bool handlerAwayHintVisible({
  required AgentWorkStatus? status,
  required DateTime? attentionSince,
  required DateTime now,
  required bool sessionArmed,
  required bool? agentObservable,
  required FirstRunState firstRun,
}) {
  return status == AgentWorkStatus.attention &&
      attentionSince != null &&
      now.difference(attentionSince) >= kHandlerAwayHintAfter &&
      !sessionArmed &&
      agentObservable != false &&
      !firstRun.handlerArmedOnce &&
      !firstRun.handlerAwayHintDismissed;
}

/// Injectable clock for [handlerAwayAttentionSinceProvider] — tests override
/// this instead of the timestamps being frozen at real `DateTime.now()`.
final handlerAwayNowFnProvider = Provider<DateTime Function()>(
  (_) => DateTime.now,
);

/// When the FOCUSED session entered `attention`; null while it isn't there.
/// Leaving attention or switching the active session resets the clock —
/// switching onto a session already blocked restarts it from now, since we
/// cannot know how long it has been waiting on someone who wasn't looking.
///
/// autoDispose is load-bearing: this watches autoDispose providers
/// (sessionWorkStatusProvider), and a keep-alive watcher would pin those —
/// and, through [handlerAwayHintProvider], the minute ticker — alive for the
/// process lifetime, defeating their documented teardown contracts.
final handlerAwayAttentionSinceProvider =
    NotifierProvider.autoDispose<HandlerAwayAttentionSinceNotifier, DateTime?>(
      HandlerAwayAttentionSinceNotifier.new,
    );

class HandlerAwayAttentionSinceNotifier extends Notifier<DateTime?> {
  // Instance fields, not `state`, carry the fact across dependency-triggered
  // rebuilds: the notifier instance persists for the element's lifetime, and
  // build() must be able to tell "still the same attention spell" from
  // "entered it just now".
  String? _lastSessionId;
  DateTime? _since;

  @override
  DateTime? build() {
    final nowFn = ref.watch(handlerAwayNowFnProvider);
    final activeId = ref.watch(activeSessionIdProvider);
    final entryId = ref.watch(selectedRegistrationIdProvider);
    final entry = ref.watch(activeSessionProvider);
    AgentWorkStatus? status;
    if (activeId != null && entryId != null) {
      status = ref.watch(
        sessionWorkStatusProvider((
          entryId: entryId,
          sessionId: activeId,
          running: entry?.running ?? false,
        )),
      );
    }
    final sessionChanged = activeId != _lastSessionId;
    _lastSessionId = activeId;
    if (activeId == null || status != AgentWorkStatus.attention) {
      _since = null;
    } else if (sessionChanged || _since == null) {
      _since = nowFn();
    }
    return _since;
  }
}

/// Pre-arm Handler coverage for the FOCUSED session: the catalog's per-agent
/// prediction, resolved through the same tool fallback as the bridge's own
/// thunk (an absent per-session tool means the project default). ONE provider
/// so the header shield, the away hint, and the explainer can never answer the
/// coverage question differently for the same session.
/// [judgeCapable] is null when the catalog has never described the tool that
/// would judge — which is [agent] until the session's own judge pick names
/// another. [observable] is null under the same condition for [agent] itself,
/// so a session whose judge is picked and whose agent is undescribed can answer
/// one and not the other.
typedef FocusedSessionCoverage = ({
  String? agent,
  String? agentLabel,
  bool? observable,
  bool? judgeCapable,
});

final focusedSessionCoverageProvider =
    Provider.autoDispose<FocusedSessionCoverage>((ref) {
      final entry = ref.watch(activeSessionProvider);
      final handlerState =
          ref.watch(handlerStateProvider).value ?? const HandlerState.initial();
      final agent = entry?.tool ?? handlerState.defaultTool;
      final catalog = ref.watch(agentCatalogProvider);
      // The judge the bridge would actually run, not the session's agent: once
      // a pick exists, warning about the agent's own headless reach describes a
      // judge that is not going to be used.
      // Sourced through focusedSessionOrNull, never the handlerService facade:
      // this provider is watched, and the facade throws in the windows where a
      // project session is still resolving.
      final judge = entry == null
          ? agent
          : focusedSessionOrNull(ref)
                    ?.handlerService
                    .lastKnownSettings(entry.id)
                    ?.tool ??
                agent;
      return (
        agent: agent,
        agentLabel: catalog[agent]?.label,
        observable: handlerObservableFromCatalog(
          catalog,
          agent,
          chat: entry?.mode == 'chat',
        ),
        // The bridge's own second question, asked the same way: a session
        // resolves its judge as `storedJudge ?? the session's own tool`
        // (observabilityFor, bridge/src/handler/engine.ts). Both halves are
        // mirrored above, so this predicts rather than approximates — and an
        // armed session reports its own answer regardless, which is what this
        // one has to agree with before the arm.
        judgeCapable: catalog[judge]?.judgeCapable,
      );
    });

/// The composed away-moment signal for the focused session. `nowMinuteProvider`
/// is the "now" heartbeat: the hint appearing up to a minute late is fine and
/// avoids a dedicated timer.
///
/// autoDispose, and the retired-flags check runs FIRST: between them, the
/// minute ticker (and the status derivation behind it) tears down both when no
/// hint surface is mounted and for every user who has ever armed — instead of
/// re-deriving once a minute for the rest of the process.
final handlerAwayHintProvider = Provider.autoDispose<bool>((ref) {
  final firstRun = ref.watch(firstRunProvider);
  if (firstRun.handlerArmedOnce || firstRun.handlerAwayHintDismissed) {
    return false;
  }
  final activeId = ref.watch(activeSessionIdProvider);
  final entryId = ref.watch(selectedRegistrationIdProvider);
  if (activeId == null || entryId == null) return false;
  final entry = ref.watch(activeSessionProvider);
  final status = ref.watch(
    sessionWorkStatusProvider((
      entryId: entryId,
      sessionId: activeId,
      running: entry?.running ?? false,
    )),
  );
  final handlerState =
      ref.watch(handlerStateProvider).value ?? const HandlerState.initial();
  final now =
      ref.watch(nowMinuteProvider).value ??
      ref.read(handlerAwayNowFnProvider)();
  return handlerAwayHintVisible(
    status: status,
    attentionSince: ref.watch(handlerAwayAttentionSinceProvider),
    now: now,
    sessionArmed: handlerState.sessions.containsKey(activeId),
    agentObservable: ref.watch(focusedSessionCoverageProvider).observable,
    firstRun: firstRun,
  );
});
