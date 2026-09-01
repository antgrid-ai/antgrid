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
/// [judgeCapable] is null under exactly the same condition [observable] is —
/// both are read off one descriptor, so an agent the catalog has never
/// described answers neither question rather than half of one.
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
      return (
        agent: agent,
        agentLabel: catalog[agent]?.label,
        observable: handlerObservableFromCatalog(
          catalog,
          agent,
          chat: entry?.mode == 'chat',
        ),
        // The bridge's own second question, asked the same way: an armed
        // session resolves its judge as `storedJudge ?? the session's own tool`
        // (observabilityFor, bridge/src/handler/engine.ts). Nothing writes a
        // stored judge today, so the fallback IS the answer and the catalog
        // already holds it — this predicts, it does not approximate. Whatever
        // lands a judge picker owns keeping that true.
        judgeCapable: catalog[agent]?.judgeCapable,
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
