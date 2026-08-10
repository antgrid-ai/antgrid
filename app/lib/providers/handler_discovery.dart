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
final handlerAwayAttentionSinceProvider =
    NotifierProvider<HandlerAwayAttentionSinceNotifier, DateTime?>(
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

/// The composed away-moment signal for the focused session. `nowMinuteProvider`
/// is the "now" heartbeat: the hint appearing up to a minute late is fine and
/// avoids a dedicated timer.
final handlerAwayHintProvider = Provider<bool>((ref) {
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
  // Same pre-arm coverage derivation as HandlerHeaderControl: an absent
  // per-session tool resolves to the project default, as the bridge's own
  // thunk does.
  final agent = entry?.tool ?? handlerState.defaultTool;
  final agentObservable = handlerObservableFromCatalog(
    ref.watch(agentCatalogProvider),
    agent,
    chat: entry?.mode == 'chat',
  );
  final now =
      ref.watch(nowMinuteProvider).value ??
      ref.read(handlerAwayNowFnProvider)();
  return handlerAwayHintVisible(
    status: status,
    attentionSince: ref.watch(handlerAwayAttentionSinceProvider),
    now: now,
    sessionArmed: handlerState.sessions.containsKey(activeId),
    agentObservable: agentObservable,
    firstRun: ref.watch(firstRunProvider),
  );
});
