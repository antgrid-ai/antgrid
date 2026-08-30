import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/session_entry.dart';
import '../services/sessions_service.dart';
import 'providers.dart';
import 'sessions.dart';

export '../services/sessions_service.dart' show SessionSetupAction;

/// What a surface may claim about an isolated session's provisioning run.
///
/// [unknown] is the answer for a `SessionSetup.state` this build cannot name,
/// and it is load-bearing rather than defensive, mirroring
/// `sessionCheckoutHealth`: the bridge owns that vocabulary and may widen it,
/// so an unrecognised value must degrade to the weakest true statement instead
/// of being read as either finished or still going.
enum SessionSetupPhase { running, done, failed, skipped, interrupted, unknown }

/// How long a successful setup confirmation remains above the agent surface.
const Duration kSessionSetupSuccessHold = Duration(seconds: 3);

/// Ephemeral presentation state that must outlive an AgentPanel mount.
///
/// The panel is intentionally absent while the context pane is full-width.
/// Keeping this state in the banner would resurrect dismissed results and
/// re-enable setup actions whenever the user returned to the agent.
class SessionSetupBannerUiState {
  const SessionSetupBannerUiState({
    this.hiddenRunKeys = const <String>{},
    this.expandedSessionId,
    this.actingSessionIds = const <String>{},
  });

  final Set<String> hiddenRunKeys;
  final String? expandedSessionId;
  final Set<String> actingSessionIds;
}

class SessionSetupBannerUiController
    extends Notifier<SessionSetupBannerUiState> {
  final Map<String, Timer> _successTimers = <String, Timer>{};

  @override
  SessionSetupBannerUiState build() {
    ref.onDispose(() {
      for (final timer in _successTimers.values) {
        timer.cancel();
      }
    });
    return const SessionSetupBannerUiState();
  }

  void hide(String runKey) {
    _successTimers.remove(runKey)?.cancel();
    state = SessionSetupBannerUiState(
      hiddenRunKeys: {...state.hiddenRunKeys, runKey},
      expandedSessionId: state.expandedSessionId,
      actingSessionIds: state.actingSessionIds,
    );
  }

  void toggleExpanded(String sessionId, String runKey) {
    _successTimers.remove(runKey)?.cancel();
    state = SessionSetupBannerUiState(
      hiddenRunKeys: state.hiddenRunKeys,
      expandedSessionId: state.expandedSessionId == sessionId
          ? null
          : sessionId,
      actingSessionIds: state.actingSessionIds,
    );
  }

  void setActing(String sessionId, bool acting) {
    final next = {...state.actingSessionIds};
    if (acting) {
      next.add(sessionId);
    } else {
      next.remove(sessionId);
    }
    state = SessionSetupBannerUiState(
      hiddenRunKeys: state.hiddenRunKeys,
      expandedSessionId: state.expandedSessionId,
      actingSessionIds: next,
    );
  }

  void hideSuccessAfterDelay(String runKey) {
    if (state.hiddenRunKeys.contains(runKey) ||
        _successTimers.containsKey(runKey)) {
      return;
    }
    _successTimers[runKey] = Timer(kSessionSetupSuccessHold, () {
      _successTimers.remove(runKey);
      hide(runKey);
    });
  }
}

final sessionSetupBannerUiProvider =
    NotifierProvider<SessionSetupBannerUiController, SessionSetupBannerUiState>(
      SessionSetupBannerUiController.new,
    );

SessionSetupPhase sessionSetupPhase(SessionSetup? setup) =>
    switch (setup?.state) {
      'running' => SessionSetupPhase.running,
      'done' => SessionSetupPhase.done,
      'failed' => SessionSetupPhase.failed,
      'skipped' => SessionSetupPhase.skipped,
      'interrupted' => SessionSetupPhase.interrupted,
      _ => SessionSetupPhase.unknown,
    };

/// Outcome of a [runSessionSetupAction]. Mirrors [SessionModeResult]: the
/// banner is the only surface these verbs have, so a refusal has to arrive with
/// something to render rather than collapsing to a bare failure.
typedef SessionSetupResult = ({bool ok, String? error});

/// Setup state for [sessionId], or null when the session has none — every
/// shared session, a bridge predating the feature, and an isolated session
/// whose project declares no `worktree.setup` block.
///
/// A thin projection of the live session list and nothing more: the bridge owns
/// this state and pushes every transition on `session:updated`, so no surface
/// may hold its own copy or optimistically advance it.
///
/// Deliberately sourced from [freshSessionsStateProvider] alone, never the
/// persisted cache — which carries no `setup` by design, since a stored
/// `running` would restore with nothing alive to finish it and paint a
/// permanent "preparing" banner (`cached_sessions_store.dart`).
///
/// `autoDispose`, unlike most families here: those are keyed by a bounded
/// entryId or projectId, while this one is keyed by sessionId and read once per
/// rendered row of a cross-project Recent list. Kept alive, every session id
/// ever scrolled past — deleted ones included — would leave a provider behind,
/// each re-running its scan of the list on every `session:updated`.
final sessionSetupProvider = Provider.autoDispose.family<SessionSetup?, String>(
  (ref, sessionId) {
    final state = ref.watch(freshSessionsStateProvider);
    if (state == null) return null;
    for (final s in state.sessions) {
      if (s.id == sessionId) return s.setup;
    }
    return null;
  },
);

/// [sessionSetupProvider] for the session the workspace is showing.
final activeSessionSetupProvider = Provider.autoDispose<SessionSetup?>((ref) {
  final id = ref.watch(activeSessionIdProvider);
  if (id == null) return null;
  return ref.watch(sessionSetupProvider(id));
});

/// Whether an agent start is waiting on [sessionId]'s setup to finish.
///
/// Read off the entry rather than remembered from the `session:start` reply:
/// the bridge answers `ok` to a start it has only queued, so the reply cannot
/// tell the two apart and the entry is the only honest source.
final sessionStartQueuedProvider = Provider.autoDispose.family<bool, String>((
  ref,
  sessionId,
) {
  return sessionStartQueued(ref.watch(sessionSetupProvider(sessionId)));
});

/// [sessionStartQueuedProvider]'s predicate, for the callers holding an entry
/// straight off `session:list` rather than a provider.
///
/// Load-bearing wherever a stopped session is auto-started: a queued session
/// reports `running: false` for the whole setup run, so `running` alone reads
/// as "needs starting" and sends a SECOND `session:start`. That one carries no
/// `initialPrompt`, and it replaces the queued one the user actually typed.
bool sessionStartQueued(SessionSetup? setup) => setup?.pendingStart ?? false;

/// Sends `session:setup` for [sessionId] in [entryId] and reports what came
/// back.
///
/// Acknowledges the VERB only. The run itself takes minutes and reports through
/// `session:updated`, so a caller must render from [sessionSetupProvider] and
/// never from this future — awaiting the run here would lapse the service's
/// pending-reply timeout on every project with real provisioning to do.
///
/// Keyed on an explicit [entryId], and warmed rather than read, for the reasons
/// in [warmServiceFor]: this is a button press, and the windows where the
/// focused project's services are momentarily absent are exactly the ones the
/// button exists to recover from.
///
/// Never throws — a refusal, a dropped reply and an unreachable project all
/// come back as `ok: false` with a line to show. The callers are `void` tap
/// handlers, where an escaping rejection would reach
/// `PlatformDispatcher.onError` as a fatal.
Future<SessionSetupResult> runSessionSetupAction(
  ProviderContainer container, {
  required String entryId,
  required String sessionId,
  required SessionSetupAction action,
}) async {
  final service = await warmServiceFor(
    container,
    entryId,
    (s) => s.sessionsService,
  );
  if (service == null) {
    return (ok: false, error: 'This project isn\'t connected right now.');
  }
  try {
    await service.setup(sessionId, action);
    return (ok: true, error: null);
  } on SessionOperationException catch (e) {
    return (ok: false, error: e.message ?? e.errorCode);
  } on TimeoutException {
    return (
      ok: false,
      error: 'The machine didn\'t answer. Setup may still be running.',
    );
  } on StateError {
    // The project's services were torn down under the request (a host restart,
    // an LRU eviction). Nothing was necessarily lost on the bridge, so this
    // says what is known rather than claiming the action failed.
    return (ok: false, error: 'This project reconnected. Try again.');
  }
}
