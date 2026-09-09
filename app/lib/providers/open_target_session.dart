import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/session_target.dart';
import '../navigation/nav_controller.dart';
import '../project/project_session_registry.dart';
import '../util/device_id.dart';
import 'agent_transport.dart';
import 'new_session_action.dart';
import 'providers.dart';
import 'sessions.dart';

/// Writes the active-session id for the project that is ALREADY focused and
/// announces the pick, returning false when [ActiveSessionId] refused the write
/// because the bridge is deleting that session.
///
/// The announcement is what clears the bridge's unread dot; a focus change that
/// skips it leaves the bridge believing this client is still on the session the
/// user left, so that one keeps its dot and the one now on screen is exempted
/// from earning another.
///
/// `focusedServiceOrNull`, never the façade: every caller reaches here from a
/// gesture handler past an await, where the focused project's `ProjectSession`
/// may be unresolved and reading the provider directly THROWS.
bool focusSessionInFocusedProject(
  ProviderContainer container,
  String sessionId,
) {
  container.read(activeSessionIdProvider.notifier).set(sessionId);
  // Read back rather than trusting the write: the guard is silent, and a caller
  // that revealed the session's surface anyway would aim the workspace at a
  // transcript nobody is going to be shown.
  if (container.read(activeSessionIdProvider) != sessionId) return false;
  focusedServiceOrNull(container, (s) => s.sessionsService)?.focus(sessionId);
  return true;
}

/// What a press on a session found — see [openTargetAndFocusSession].
enum OpenSessionOutcome {
  /// Focused, active, and the project's bridge answered.
  opened,

  /// Focused and active, but the project's session service never resolved
  /// inside the timeout: that machine is not answering right now. The surface
  /// on screen is empty rather than wrong.
  unreachable,

  /// [ActiveSessionId] refused the id, because the bridge is deleting that
  /// session. Says nothing about reachability — the bridge is right here.
  refused,
}

/// Takes the user to [sessionId] inside [registrationId], opening or warming
/// that project first when it is not the focused one. Throws whatever the
/// project open threw, with the prior focus restored.
///
/// The ordering every caller depends on lives here once: the pick is QUEUED
/// before the switch, because the new project's session list lands in stages
/// and `reconcileActiveSession`
/// otherwise takes `first` from the persisted cache and renders it in full
/// before the wire's list arrives. The suppression id rides with it — arriving
/// at a session means "show me this", never "restart this agent".
Future<OpenSessionOutcome> openTargetAndFocusSession(
  ProviderContainer container, {
  required String registrationId,
  required String sessionId,
}) async {
  if (container.read(selectedRegistrationIdProvider) != registrationId) {
    await _switchProject(container, registrationId, sessionId);
  }
  container.read(activeSessionIdProvider.notifier).set(sessionId);
  if (container.read(activeSessionIdProvider) != sessionId) {
    return OpenSessionOutcome.refused;
  }
  // [warmServiceFor], not [focusedServiceOrNull]: this is an explicit press on
  // a project that may still be resolving — which is exactly the window the
  // press exists to cross — and the id is explicit, so a focus that moved on
  // under us cannot misroute the announcement to another agent.
  final service = await warmServiceFor(
    container,
    registrationId,
    (s) => s.sessionsService,
    timeout: const Duration(seconds: 30),
  );
  service?.focus(sessionId);
  return service == null
      ? OpenSessionOutcome.unreachable
      : OpenSessionOutcome.opened;
}

/// Moves the focused target to [registrationId], restoring the prior focus and
/// the prior queued pick if the open fails.
Future<void> _switchProject(
  ProviderContainer container,
  String registrationId,
  String sessionId,
) async {
  final priorTarget = container.read(selectedTargetProvider);
  // Saved, not assumed absent: another site's queued pick is state this switch
  // is borrowing, and an open that fails owes it back untouched.
  final priorPending = container.read(pendingActiveSessionIdProvider);
  final priorSuppressed = container.read(
    pendingSessionStartSuppressedIdProvider,
  );
  container.read(pendingActiveSessionIdProvider.notifier).set(sessionId);
  container
      .read(pendingSessionStartSuppressedIdProvider.notifier)
      .set(sessionId);
  try {
    if (!registrationId.contains('.')) {
      selectProject(container, registrationId);
      return;
    }
    final machineUuid = baseDeviceUuid(registrationId);
    final projectId = baseProjectId(registrationId);
    // A warm project needs no promote round trip — its socket is already bound.
    if (container.read(projectSessionRegistryProvider).contains(
      registrationId,
    )) {
      container
          .read(selectedTargetProvider.notifier)
          .set(RemoteProject(machineUuid: machineUuid, projectId: projectId));
    } else {
      await openRemoteProjectForActivation(
        container,
        machineUuid: machineUuid,
        projectId: projectId,
      );
    }
    recordProjectFocus(container);
  } catch (_) {
    container.read(selectedTargetProvider.notifier).set(priorTarget);
    // Only OUR writes are taken back. A bootstrap that landed for another
    // project while this open ran has already consumed the queued value, and
    // writing it back would re-arm an id nothing will ever resolve.
    if (container.read(pendingActiveSessionIdProvider) == sessionId) {
      container.read(pendingActiveSessionIdProvider.notifier).set(priorPending);
    }
    if (container.read(pendingSessionStartSuppressedIdProvider) == sessionId) {
      container
          .read(pendingSessionStartSuppressedIdProvider.notifier)
          .set(priorSuppressed);
    }
    rethrow;
  }
}
