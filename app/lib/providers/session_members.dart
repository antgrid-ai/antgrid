import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/session_entry.dart';
import '../models/session_target.dart';
import '../services/account_agents_api.dart';
import '../util/device_id.dart';
import 'account_agents.dart';
import 'agent_transport.dart';
import 'device_provisioning.dart';
import 'open_target_session.dart';
import 'providers.dart';
import 'recent_agents.dart';
import 'sessions.dart';

/// The registration id that addresses [member]'s project — the id every focus,
/// transport and service lookup in the app is keyed by.
///
/// A member ref names a MACHINE and a project; the app names a local project by
/// its bare id and a remote one by the compound `<machineUuid>.<projectId>`, so
/// the mapping turns entirely on whether the ref points at this device. A null
/// [localMachineId] (mobile, where there is no local host, or a keychain read
/// still in flight) resolves everything as remote, which is correct there and
/// self-corrects once the uuid lands.
String memberRegistrationId(
  SessionMemberRef member, {
  required String? localMachineId,
}) => member.machineId == localMachineId
    ? member.projectId
    : '${member.machineId}.${member.projectId}';

/// The address of the session currently on screen, as a member ref.
///
/// The anchor for every derivation below: which tab is current, whether the
/// viewed row is a lead or a peer, and what to record when the user removes a
/// member are all answered by comparing against this. Null while no session is
/// in focus, and on a local target whose device uuid has not resolved yet.
///
/// Reads [activeSessionOrCachedProvider] for the id and name alone — both fixed
/// for the life of a session — so a peer tab still identifies itself while its
/// project's live list is re-subscribing.
///
/// Deliberately card-less. A [SessionMemberRef.card] is what one machine
/// ANSWERED about itself as it joined another, and this ref is derived from the
/// session on screen rather than from a membership — the row that recorded the
/// join is the only place that answer lives.
final viewedSessionRefProvider = Provider<SessionMemberRef?>((ref) {
  final target = ref.watch(selectedTargetProvider);
  final session = ref.watch(activeSessionOrCachedProvider);
  if (target == null || session == null) return null;
  final machineId = switch (target) {
    LocalProject() => ref.watch(localDeviceUuidProvider).value,
    RemoteProject(:final machineUuid) => machineUuid,
    RemoteTarget(:final agentDeviceId) => baseDeviceUuid(agentDeviceId),
  };
  if (machineId == null || machineId.isEmpty) return null;
  return SessionMemberRef(
    machineId: machineId,
    projectId: baseProjectId(target.registrationId),
    sessionId: session.id,
    sessionName: session.name,
  );
});

/// The machines of one multi-machine session, in tab order: the LEAD first,
/// then its active members. Empty for a session that works alone.
///
/// One session viewed from two places (§7.5) yields the same strip, which is
/// what lets the peer's own project show the whole session rather than an
/// unexplained row: a lead row emits `[self, ...activeMembers]`, a peer row
/// emits `[lead, self]`. A lead whose members have all been released emits
/// nothing — the record stays on the row as history, but the session is working
/// alone again.
///
/// Released and `released-delete-refused` members are excluded by
/// [SessionMember.isActive]; a peer marked orphaned still appears, because an
/// absence is not a verdict (D11) and the session is still a member of one.
final visibleMemberTabsProvider = Provider<List<SessionMemberRef>>((ref) {
  final self = ref.watch(viewedSessionRefProvider);
  if (self == null) return const [];
  final session = ref.watch(activeSessionOrCachedProvider);
  if (session == null) return const [];
  final memberOf = session.memberOf;
  if (memberOf != null) return [memberOf.ref, self];
  final active = [
    for (final m in session.members)
      if (m.isActive) m.ref,
  ];
  if (active.isEmpty) return const [];
  return [self, ...active];
});

/// Which session GROUP is under view, and which of its machines the user is on.
///
/// [selected] is null on the lead's own tab, so a caller asking "is a peer
/// selected" — the kebab's Remove item above all — reads one field rather than
/// re-deriving membership. [leadRegistrationId] and [leadSessionId] address the
/// lead wherever the user currently is, which is what makes "back to the lead"
/// reachable from a peer tab whose own row knows the lead only as a ref.
class MemberViewState {
  final String leadRegistrationId;
  final String leadSessionId;
  final SessionMemberRef? selected;

  const MemberViewState({
    required this.leadRegistrationId,
    required this.leadSessionId,
    this.selected,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MemberViewState &&
          other.leadRegistrationId == leadRegistrationId &&
          other.leadSessionId == leadSessionId &&
          other.selected == selected;

  @override
  int get hashCode => Object.hash(leadRegistrationId, leadSessionId, selected);
}

/// Null unless the focused session is part of a multi-machine session.
///
/// DERIVED in `build`, not accumulated: the focused session is the truth about
/// which tab is current, and a selection this notifier merely remembered would
/// go stale the moment the user reached a session any other way — a drawer row,
/// the Recent list, a notification tap. [select] still writes, but only as an
/// optimistic value for the frames between the press and the focus actually
/// moving; the next rebuild replaces it with what the session says.
class MemberView extends Notifier<MemberViewState?> {
  @override
  MemberViewState? build() {
    final self = ref.watch(viewedSessionRefProvider);
    if (self == null) return null;
    final session = ref.watch(activeSessionOrCachedProvider);
    if (session == null) return null;
    final localMachineId = ref.watch(localDeviceUuidProvider).value;
    final memberOf = session.memberOf;
    if (memberOf != null) {
      return MemberViewState(
        leadRegistrationId: memberRegistrationId(
          memberOf.ref,
          localMachineId: localMachineId,
        ),
        leadSessionId: memberOf.ref.sessionId,
        selected: self,
      );
    }
    if (!session.members.any((m) => m.isActive)) return null;
    return MemberViewState(
      leadRegistrationId: memberRegistrationId(
        self,
        localMachineId: localMachineId,
      ),
      leadSessionId: self.sessionId,
    );
  }

  /// Records the tab the user just pressed, ahead of the focus switch it starts.
  void select(SessionMemberRef member) {
    final current = state;
    if (current == null) return;
    state = MemberViewState(
      leadRegistrationId: current.leadRegistrationId,
      leadSessionId: current.leadSessionId,
      selected: member.sessionId == current.leadSessionId ? null : member,
    );
  }
}

final memberViewProvider = NotifierProvider<MemberView, MemberViewState?>(
  MemberView.new,
);

/// Takes the user to [member]'s machine: its project becomes the focused one
/// and its session the active one.
///
/// Nothing here touches `focusedCheckoutIdProvider` — it derives from the
/// active session's own `checkoutId`, so files, git, preview, terminals and the
/// Handler follow the selected member for free, all of them being
/// checkout-scoped already.
///
/// Takes the [ProviderContainer], never a `WidgetRef`: the switch rebuilds the
/// strip that started it, and a ref read on a dead element throws.
Future<void> selectMemberTab(
  ProviderContainer container,
  SessionMemberRef member,
) async {
  // Captured before the switch, which replaces the very state it is read from.
  final probe = _leadProbe(container, member);
  container.read(memberViewProvider.notifier).select(member);
  final localMachineId = await container.read(localDeviceUuidProvider.future);
  OpenSessionOutcome outcome;
  try {
    outcome = await openTargetAndFocusSession(
      container,
      registrationId: memberRegistrationId(
        member,
        localMachineId: localMachineId,
      ),
      sessionId: member.sessionId,
    );
  } catch (_) {
    // A project that would not open is the same answer as a bridge that would
    // not resolve, and the caller still owes the user the throw.
    await _recordLeadReachability(
      container,
      probe: probe,
      localMachineId: localMachineId,
      orphaned: true,
    );
    rethrow;
  }
  await _recordLeadReachability(
    container,
    probe: probe,
    localMachineId: localMachineId,
    orphaned: outcome == OpenSessionOutcome.unreachable,
  );
}

/// The peer session whose lead this press is about to probe, or null when the
/// press is not a peer reaching for its lead.
///
/// A press on the lead tab from a member's tab is the ONLY probe of the lead
/// this app has: no bridge dials a lead, so nothing else can ever discover that
/// one has gone. [SessionMemberOf.state] would otherwise stay `active` for the
/// life of the session, which is what left the orphaned rendering unreachable.
({SessionMemberRef peer, bool wasOrphaned})? _leadProbe(
  ProviderContainer container,
  SessionMemberRef pressed,
) {
  final view = container.read(memberViewProvider);
  final peer = view?.selected;
  if (view == null || peer == null) return null;
  if (pressed.sessionId != view.leadSessionId) return null;
  final memberOf = container.read(activeSessionOrCachedProvider)?.memberOf;
  if (memberOf == null) return null;
  return (peer: peer, wasOrphaned: memberOf.isOrphaned);
}

/// Tells the PEER's own bridge what the press found out about its lead.
///
/// Sent only when the answer changed: the verb is idempotent, but the peer is
/// on the other end of a relay and a mark that says nothing new is not worth a
/// round trip on every tab switch. Failures are swallowed — the user is already
/// looking at the consequence of an unreachable machine, and a mark that could
/// not be written is not a second thing to tell them about.
Future<void> _recordLeadReachability(
  ProviderContainer container, {
  required ({SessionMemberRef peer, bool wasOrphaned})? probe,
  required String? localMachineId,
  required bool orphaned,
}) async {
  if (probe == null || probe.wasOrphaned == orphaned) return;
  final service = await warmServiceFor(
    container,
    memberRegistrationId(probe.peer, localMachineId: localMachineId),
    (s) => s.sessionsService,
  );
  if (service == null) return;
  try {
    await service.memberOrphan(
      sessionId: probe.peer.sessionId,
      orphaned: orphaned,
    );
  } catch (_) {
    // See above.
  }
}

/// Best available name for a member's machine, for a tab or a badge that has to
/// say where a session runs.
///
/// The ref's own [SessionMemberRef.machineLabel] wins wherever it exists — it is
/// what the carrier recorded at join time, and it is the only name a row served
/// from the persisted cache can have for a machine this app has never dialled.
/// Everything below it is a local lookup for the machines this install does
/// know, in the same order `buildPickerSources` resolves a machine label.
///
/// `autoDispose` is not an optimisation here. The family key is a whole
/// [SessionMemberRef], whose equality includes the labels the wire keeps
/// rewriting — a session rename lands a `!=` ref for the same machine — so a
/// retained family would leave one permanently-subscribed element behind per
/// rename, each still recomputing on every account-inventory and recent-agents
/// push.
final memberMachineLabelProvider = Provider.autoDispose
    .family<String, SessionMemberRef>((ref, member) {
  final wire = member.machineLabel?.trim();
  if (wire != null && wire.isNotEmpty) return wire;
  final inventory =
      ref.watch(accountAgentsProvider).value ?? const <InventoryAgent>[];
  for (final agent in inventory) {
    if (agent.deviceUuid != member.machineId) continue;
    final name = agent.machineName?.trim();
    if (name != null && name.isNotEmpty) return name;
  }
  for (final recent in ref.watch(recentAgentsProvider)) {
    if (baseDeviceUuid(recent.agentDeviceId) != member.machineId) continue;
    final name = recent.hostMachineName?.trim();
    if (name != null && name.isNotEmpty) return name;
  }
  if (ref.watch(localDeviceUuidProvider).value == member.machineId) {
    return 'This machine';
  }
  // A uuid is a poor name but a true one, and shortened it still tells two
  // unnamed machines apart — which is the whole job of a tab label.
  return member.machineId.length <= _kShortMachineIdChars
      ? member.machineId
      : member.machineId.substring(0, _kShortMachineIdChars);
});

const int _kShortMachineIdChars = 8;
