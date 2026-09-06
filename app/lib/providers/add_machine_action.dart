import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/session_entry.dart';
import '../models/session_target.dart';
import '../project/project_session_registry.dart';
import '../services/sessions_service.dart';
import 'agent_transport.dart';
import 'new_session_action.dart';
import 'open_target_session.dart';
import 'providers.dart';
import 'session_members.dart';
import 'sessions.dart';

/// What [addMachineToSession] did. Success carries the peer as the lead's row
/// now records it, so the caller can put the user on that tab without
/// re-deriving the ref; failure carries a sentence to show.
///
/// A single message rather than a code: every failure here is one the user acts
/// on by reading it — a machine that would not start, a lead that would not
/// record, or a peer session left behind that they have to remove by hand — and
/// none of them is a case any caller branches on.
///
/// [warning] is the same kind of sentence on a join that LANDED. Not folded into
/// [error]: a peer whose agent would not start is a member of this session and
/// belongs on its tab, so the caller must still be handed the ref — but the
/// machine sits idle until someone starts it, and nothing on that tab says so.
@immutable
class AddMachineOutcome {
  const AddMachineOutcome.added(SessionMemberRef this.peer, {this.warning})
    : error = null;
  const AddMachineOutcome.failed(String this.error)
    : peer = null,
      warning = null;

  final SessionMemberRef? peer;
  final String? error;
  final String? warning;

  bool get ok => peer != null;

  /// The one sentence to put in front of the user, if there is one.
  String? get message => error ?? warning;
}

/// Adds [peer]'s machine to the session [leadSessionId] leads, per §7.5.
///
/// Two bridges are written to and they cannot be written atomically, so the
/// order is the safety property: the peer's session is CREATED first and the
/// lead's record written second, because a peer session nothing points at is
/// removable and a lead record pointing at a session that was never created is
/// not. Step two failing is therefore compensated by deleting what step one
/// made — and if that compensation also fails, the leftover is named rather
/// than swallowed, because it is now the user's to clean up.
///
/// The peer's agent is started LAST, after both bridges agree, because a start
/// is the one step here that cannot be compensated: an agent that has read its
/// brief and begun work is not undone by deleting the session it ran in.
///
/// Nothing is pinned or attached here. The membership landing on the lead's row
/// is what `sessionBusLinksProvider` derives from, so the carrier and the warm-
/// project pin follow from the record alone — which is also the only reason a
/// release can undo them without commanding anything.
///
/// [peerCard] is the Capability Card the dialog already read to pre-select the
/// project, carried rather than re-read here: the lead's record is what the peer
/// machine WAS when it joined, and a second read would answer for a different
/// moment. Null joins the machine with no card, which is what an unreachable
/// card reader and an older peer bridge both produce.
///
/// [brief] is written to BOTH bridges: it is the peer's standing mandate on its
/// own machine, and the lead's record carries a copy because nothing on the lead
/// machine stores it and its agent would otherwise be told a machine joined with
/// no account of what the human asked of it.
///
/// Takes the [ProviderContainer], never a `WidgetRef`: the dialog that starts
/// this pops before it finishes, and this outlives it.
Future<AddMachineOutcome> addMachineToSession(
  ProviderContainer container, {
  required String leadRegistrationId,
  required String leadSessionId,
  required SessionMemberRef leadRef,
  required RemoteProject peer,
  required String tool,
  required String brief,
  String? model,
  String? mode,
  String? sessionName,
  String? peerMachineLabel,
  String? peerProjectLabel,
  SessionMemberCard? peerCard,
}) async {
  final priorRegistrationId = container.read(selectedRegistrationIdProvider);
  final priorSessionId = container.read(activeSessionIdProvider);

  // Warming the peer's project moves the workspace's focus as a side effect
  // ([openRemoteProjectForActivation] sets the target itself), so a flow that
  // fails halfway owes the user the view they pressed from.
  Future<void> restoreFocus() async {
    if (priorRegistrationId == null || priorSessionId == null) return;
    if (container.read(selectedRegistrationIdProvider) == priorRegistrationId) {
      return;
    }
    try {
      await openTargetAndFocusSession(
        container,
        registrationId: priorRegistrationId,
        sessionId: priorSessionId,
      );
    } catch (_) {
      // The user is looking at the peer's project with an error on screen; a
      // second failure restoring the view is not worth replacing that message.
    }
  }

  final machineName = peerMachineLabel ?? peer.machineUuid;

  // A member's project is normally already warm — the carrier pins it — so the
  // promote round trip is skipped when the registry has it, exactly as
  // `openTargetAndFocusSession` skips it.
  if (!container.read(projectSessionRegistryProvider).contains(
    peer.registrationId,
  )) {
    try {
      await openRemoteProjectForActivation(
        container,
        machineUuid: peer.machineUuid,
        projectId: peer.projectId,
      );
    } catch (e) {
      await restoreFocus();
      return AddMachineOutcome.failed('Could not reach $machineName. $e');
    }
  }

  // Longer than the default: this may be waiting on a project that has only
  // just been promoted, which is the window the whole flow exists to cross.
  final peerService = await warmServiceFor(
    container,
    peer.registrationId,
    (s) => s.sessionsService,
    timeout: const Duration(seconds: 30),
  );
  if (peerService == null) {
    await restoreFocus();
    return AddMachineOutcome.failed(
      'Could not reach $machineName. Nothing was created.',
    );
  }

  final SessionEntry? created;
  try {
    created = await peerService.create(
      name: sessionName,
      tool: tool,
      // No `model` field on `session:create` yet, so the flag rides the raw
      // args string the bridge passes to the CLI verbatim. Empty is the common
      // path and appends nothing.
      args: model == null || model.isEmpty ? null : '--model $model',
      mode: mode,
      // Always shared: the bridge refuses a `worktree` peer (D10), so the
      // dialog never offers the choice and nothing here can produce one.
      isolation: 'shared',
      memberOf: leadRef,
      brief: brief,
    );
  } catch (e) {
    await restoreFocus();
    return AddMachineOutcome.failed(
      'Could not start a session on $machineName. ${_reason(e)}',
    );
  }
  if (created == null) {
    await restoreFocus();
    return AddMachineOutcome.failed(
      'Could not start a session on $machineName. Nothing was created.',
    );
  }

  final peerRef = SessionMemberRef(
    machineId: peer.machineUuid,
    projectId: peer.projectId,
    sessionId: created.id,
    machineLabel: peerMachineLabel,
    projectLabel: peerProjectLabel,
    sessionName: created.name,
    card: peerCard,
  );

  final leadService = await warmServiceFor(
    container,
    leadRegistrationId,
    (s) => s.sessionsService,
  );
  Object? recordFailure;
  if (leadService == null) {
    recordFailure = StateError('this session is no longer reachable');
  } else {
    try {
      await leadService.memberRecord(
        sessionId: leadSessionId,
        member: peerRef,
        brief: brief.isEmpty ? null : brief,
      );
    } catch (e) {
      recordFailure = e;
    }
  }

  if (recordFailure != null) {
    final undone = await _deleteQuietly(peerService, created.id);
    // The record is withdrawn too, not just the session. A record that TIMED
    // OUT may well have landed — the bridge applies it and only the reply is
    // lost — and a membership pointing at a deleted session pins the peer's
    // project and connection for the app's lifetime with no UI able to clear
    // it. `releaseMember` is a no-op for a member that was never recorded, so
    // this costs one round trip and closes the case either way.
    final released =
        leadService == null ||
        await _releaseQuietly(leadService, leadSessionId, peerRef);
    await restoreFocus();
    if (!undone) {
      return AddMachineOutcome.failed(
        'Could not join $machineName to this session '
        '(${_reason(recordFailure)}), and the session it created could not be '
        'removed. Delete "${created.name}" on $machineName by hand.',
      );
    }
    if (!released) {
      return AddMachineOutcome.failed(
        'Could not join $machineName to this session '
        '(${_reason(recordFailure)}). The session it created was removed, but '
        'this session may still list $machineName as a member — use "Remove '
        'from session" on its tab to clear it.',
      );
    }
    return AddMachineOutcome.failed(
      'Could not join $machineName to this session '
      '(${_reason(recordFailure)}). The session it created was removed.',
    );
  }

  // The peer now has a session and a membership but no agent: `session:create`
  // and `session:start` are separate verbs and create starts nothing, while the
  // brief handed over with the create is sitting at the head of that session's
  // delivery queue waiting for a turn boundary a stopped session never reaches.
  // Nothing else supplies this start — a peer machine runs no app of its own
  // whose workspace bootstrap could adopt the session and start it.
  //
  // After the record rather than before it, so `_deleteQuietly` above keeps the
  // "created seconds ago and has never run" that its `force` rests on.
  //
  // No `initialPrompt`: the brief is already queued on the peer bridge, wrapped
  // by `renderBrief`. Passing it here would deliver the human's mandate a second
  // time and unwrapped, which is the one thing spec 5.2 forbids.
  String? startWarning;
  try {
    final started = await peerService.start(created.id, raiseRefusal: true);
    if (started == null) startWarning = _startFailed(machineName, null);
  } catch (e) {
    startWarning = _startFailed(machineName, _reason(e));
  }

  await selectMemberTab(container, peerRef);
  return AddMachineOutcome.added(peerRef, warning: startWarning);
}

/// Said when the join landed but the agent behind it did not come up. Names the
/// remedy, because the session IS on its tab and the user's next move is to
/// press start there rather than to add the machine again.
String _startFailed(String machineName, String? reason) =>
    '$machineName joined this session, but its agent did not start'
    '${reason == null ? '' : ' ($reason)'}. '
    'Open its tab and start it.';

/// Best-effort undo of the peer session this flow created.
///
/// `force: true` because there is nothing to protect: the session was created
/// seconds ago by this flow and has never run, so a dirty-workspace preflight
/// can only be answering about work that was already there. False means the
/// session is still on the peer's machine and the caller owes the user its
/// name.
Future<bool> _deleteQuietly(SessionsService service, String sessionId) async {
  try {
    await service.delete(sessionId, force: true);
    return true;
  } catch (_) {
    return false;
  }
}

/// Best-effort withdrawal of the membership record this flow may have written.
///
/// Idempotent by construction on the bridge (`releaseMember` returns the entry
/// untouched for a member it does not hold), so it is safe to send even when
/// the record demonstrably never landed — which is exactly the case that cannot
/// be told apart from a reply that was lost.
Future<bool> _releaseQuietly(
  SessionsService service,
  String sessionId,
  SessionMemberRef member,
) async {
  try {
    await service.memberRelease(sessionId: sessionId, member: member);
    return true;
  } catch (_) {
    return false;
  }
}

String _reason(Object error) =>
    error is SessionOperationException ? error.toString() : '$error';

/// The Add flow as a value, so the dialog that drives it can be tested without
/// a bridge on either machine.
typedef AddMachineFn =
    Future<AddMachineOutcome> Function(
      ProviderContainer container, {
      required String leadRegistrationId,
      required String leadSessionId,
      required SessionMemberRef leadRef,
      required RemoteProject peer,
      required String tool,
      required String brief,
      String? model,
      String? mode,
      String? sessionName,
      String? peerMachineLabel,
      String? peerProjectLabel,
      SessionMemberCard? peerCard,
    });

final addMachineActionProvider = Provider<AddMachineFn>(
  (ref) => addMachineToSession,
);
