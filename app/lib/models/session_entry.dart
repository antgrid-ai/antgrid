import 'package:flutter/foundation.dart';

import 'agent_work_status.dart';

/// Provisioning of an isolated session's own checkout (`worktree.setup` in the
/// project's `antgrid.yaml`).
///
/// Orthogonal to [SessionEntry.checkoutState], which answers "is this workspace
/// usable" and stays `ready` for the whole run — this answers "has provisioning
/// finished". That split is what makes Skip meaningful: the tree is fine, the
/// dependencies are not there yet.
///
/// [state] is carried as the raw wire string, matching the other bridge-owned
/// vocabularies on [SessionEntry]: the bridge may widen it, and a value this
/// build cannot name must degrade at the render site rather than be lost here.
/// Known values: `running`, `done`, `failed`, `skipped`, `interrupted`.
class SessionSetup {
  final String state;

  /// 0-based, the current step while running and the last one afterwards.
  final int stepIndex;
  final int stepCount;
  final String? stepName;

  /// Every step's name, in plan order — the ledger's only source, since
  /// [stepName] names the current one alone. Empty for a state recovered from
  /// disk, which knows how many steps ran but not what they were called, and
  /// for a bridge that predates the field; a ledger with no names renders
  /// nothing rather than a column of blanks.
  final List<String> stepNames;

  /// The setup transcript's terminal. The only handle on that log, and the name
  /// every list filters by: the setup PTY is typed neither `agent` nor
  /// `service`, and the ad-hoc terminal list selects by EXCLUDING those two —
  /// so untyped reads there as "a user terminal" unless it is dropped by id
  /// (`terminal_list_view.dart`).
  final String? terminalId;
  final int? exitCode;

  /// One-line failure summary.
  final String? message;

  /// A start is queued behind this run. The bridge replies `ok` to a
  /// `session:start` it queues, so this — not the reply — is how the app tells
  /// "queued" from "started".
  final bool pendingStart;
  final int startedAt;
  final int? finishedAt;

  const SessionSetup({
    required this.state,
    required this.stepIndex,
    required this.stepCount,
    required this.startedAt,
    this.stepName,
    this.stepNames = const [],
    this.terminalId,
    this.exitCode,
    this.message,
    this.pendingStart = false,
    this.finishedAt,
  });

  Map<String, dynamic> toJson() => {
    'state': state,
    'stepIndex': stepIndex,
    'stepCount': stepCount,
    if (stepName != null) 'stepName': stepName,
    if (stepNames.isNotEmpty) 'stepNames': stepNames,
    if (terminalId != null) 'terminalId': terminalId,
    if (exitCode != null) 'exitCode': exitCode,
    if (message != null) 'message': message,
    'pendingStart': pendingStart,
    'startedAt': startedAt,
    if (finishedAt != null) 'finishedAt': finishedAt,
  };

  factory SessionSetup.fromJson(Map<String, dynamic> j) => SessionSetup(
    // `as String?`, like every sibling: [listFromJson] has no per-element
    // guard, so one entry whose `setup` arrived without a state would throw
    // the WHOLE session list away rather than degrade its own row. An empty
    // state is a name no build can resolve, which is what
    // [SessionSetupPhase.unknown] is for.
    state: j['state'] as String? ?? '',
    stepIndex: (j['stepIndex'] as num?)?.toInt() ?? 0,
    stepCount: (j['stepCount'] as num?)?.toInt() ?? 0,
    stepName: j['stepName'] as String?,
    stepNames:
        (j['stepNames'] as List?)?.whereType<String>().toList(growable: false) ??
        const [],
    terminalId: j['terminalId'] as String?,
    exitCode: (j['exitCode'] as num?)?.toInt(),
    message: j['message'] as String?,
    pendingStart: j['pendingStart'] as bool? ?? false,
    startedAt: (j['startedAt'] as num?)?.toInt() ?? 0,
    finishedAt: (j['finishedAt'] as num?)?.toInt(),
  );

  SessionSetup copyWith({
    String? state,
    int? stepIndex,
    int? stepCount,
    String? stepName,
    List<String>? stepNames,
    String? terminalId,
    int? exitCode,
    String? message,
    bool? pendingStart,
    int? startedAt,
    int? finishedAt,
  }) => SessionSetup(
    state: state ?? this.state,
    stepIndex: stepIndex ?? this.stepIndex,
    stepCount: stepCount ?? this.stepCount,
    stepName: stepName ?? this.stepName,
    stepNames: stepNames ?? this.stepNames,
    terminalId: terminalId ?? this.terminalId,
    exitCode: exitCode ?? this.exitCode,
    message: message ?? this.message,
    pendingStart: pendingStart ?? this.pendingStart,
    startedAt: startedAt ?? this.startedAt,
    finishedAt: finishedAt ?? this.finishedAt,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionSetup &&
          other.state == state &&
          other.stepIndex == stepIndex &&
          other.stepCount == stepCount &&
          other.stepName == stepName &&
          listEquals(other.stepNames, stepNames) &&
          other.terminalId == terminalId &&
          other.exitCode == exitCode &&
          other.message == message &&
          other.pendingStart == pendingStart &&
          other.startedAt == startedAt &&
          other.finishedAt == finishedAt;

  @override
  int get hashCode => Object.hash(
    state,
    stepIndex,
    stepCount,
    stepName,
    Object.hashAll(stepNames),
    terminalId,
    exitCode,
    message,
    pendingStart,
    startedAt,
    finishedAt,
  );
}

/// Address of one session in a multi-machine session — the machine, project and
/// session that identify it, plus the labels a row renders with.
///
/// Hand-mirrors the bridge `SessionMemberRefSchema` (`bridge/src/protocol.ts`)
/// per the package convention that the Dart side mirrors the TS Zod schemas by
/// hand. The labels are carried rather than looked up because this rides every
/// `session:updated` frame and is rendered by rows served from the persisted
/// cache, which can resolve no other machine's names at all; the bridge bounds
/// their length for the same reason.
class SessionMemberRef {
  /// The account device uuid, which is how the app addresses a machine — never
  /// a relay slot id or a hostname.
  final String machineId;
  final String projectId;
  final String sessionId;
  final String? machineLabel;
  final String? projectLabel;
  final String? sessionName;

  const SessionMemberRef({
    required this.machineId,
    required this.projectId,
    required this.sessionId,
    this.machineLabel,
    this.projectLabel,
    this.sessionName,
  });

  /// Identity across the three ids that address a member — the same triple the
  /// bridge keys its record and release on, so two refs for one session compare
  /// equal however their labels have drifted.
  String get key => '$machineId/$projectId/$sessionId';

  Map<String, dynamic> toJson() => {
    'machineId': machineId,
    'projectId': projectId,
    'sessionId': sessionId,
    if (machineLabel != null) 'machineLabel': machineLabel,
    if (projectLabel != null) 'projectLabel': projectLabel,
    if (sessionName != null) 'sessionName': sessionName,
  };

  /// Null when any of the three ids is missing or empty. A ref that cannot be
  /// addressed is not a member, and the caller drops that element rather than
  /// the row containing it.
  static SessionMemberRef? fromJson(Map<String, dynamic> j) {
    final machineId = j['machineId'];
    final projectId = j['projectId'];
    final sessionId = j['sessionId'];
    if (machineId is! String || machineId.isEmpty) return null;
    if (projectId is! String || projectId.isEmpty) return null;
    if (sessionId is! String || sessionId.isEmpty) return null;
    return SessionMemberRef(
      machineId: machineId,
      projectId: projectId,
      sessionId: sessionId,
      machineLabel: j['machineLabel'] as String?,
      projectLabel: j['projectLabel'] as String?,
      sessionName: j['sessionName'] as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionMemberRef &&
          other.machineId == machineId &&
          other.projectId == projectId &&
          other.sessionId == sessionId &&
          other.machineLabel == machineLabel &&
          other.projectLabel == projectLabel &&
          other.sessionName == sessionName;

  @override
  int get hashCode => Object.hash(
    machineId,
    projectId,
    sessionId,
    machineLabel,
    projectLabel,
    sessionName,
  );
}

const Set<String> _kMemberRoles = {'lead', 'peer'};
const Set<String> _kMemberStates = {
  'active',
  'released',
  'released-delete-refused',
};
const Set<String> _kMemberOfStates = {'active', 'orphaned'};

/// One member of a session led on THIS machine — an entry of
/// [SessionEntry.members], carried only on a lead's row.
///
/// Both halves of a membership are recorded by the lead's app, never by one
/// bridge calling another: a bridge cannot observe a session on a different
/// machine, so every field here is a fact the carrier stated.
///
/// A released member stays on the row as history, which is why [state] carries
/// three values rather than a boolean — a peer removed cleanly and a peer whose
/// delete was refused are different records, and the second is the one the user
/// still has work to do about.
class SessionMember {
  final SessionMemberRef ref;

  /// `peer` today. Carried because leadership can move between members, and a
  /// record written before that move has to survive it.
  final String role;
  final int joinedAt;
  final String state;
  final int? releasedAt;

  /// The peer bridge's refusal code, as the lead's app relayed it. Free text,
  /// bounded on the wire — never a code this build switches on.
  final String? releaseReason;

  const SessionMember({
    required this.ref,
    required this.joinedAt,
    this.role = 'peer',
    this.state = 'active',
    this.releasedAt,
    this.releaseReason,
  });

  /// Only an active member is part of the session now; a released one is the
  /// record of one that was.
  bool get isActive => state == 'active';

  Map<String, dynamic> toJson() => {
    ...ref.toJson(),
    'role': role,
    'joinedAt': joinedAt,
    'state': state,
    if (releasedAt != null) 'releasedAt': releasedAt,
    if (releaseReason != null) 'releaseReason': releaseReason,
  };

  /// Null when the element carries no addressable ref, so one malformed member
  /// costs its own entry and not the session row it sits on. An unrecognised
  /// `role` or `state` falls back to the default instead of being dropped: the
  /// bridge owns both vocabularies and may widen them, and losing the entry
  /// would lose a machine the user is working on.
  static SessionMember? fromJson(Map<String, dynamic> j) {
    final ref = SessionMemberRef.fromJson(j);
    if (ref == null) return null;
    final role = j['role'];
    final state = j['state'];
    return SessionMember(
      ref: ref,
      role: role is String && _kMemberRoles.contains(role) ? role : 'peer',
      joinedAt: (j['joinedAt'] as num?)?.toInt() ?? 0,
      state: state is String && _kMemberStates.contains(state)
          ? state
          : 'active',
      releasedAt: (j['releasedAt'] as num?)?.toInt(),
      releaseReason: j['releaseReason'] as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionMember &&
          other.ref == ref &&
          other.role == role &&
          other.joinedAt == joinedAt &&
          other.state == state &&
          other.releasedAt == releasedAt &&
          other.releaseReason == releaseReason;

  @override
  int get hashCode =>
      Object.hash(ref, role, joinedAt, state, releasedAt, releaseReason);
}

/// The session on another machine that leads this one — [SessionEntry.memberOf],
/// carried only on a peer's row.
///
/// [state] is `orphaned` when the lead did not answer. Only the app ever sets
/// it: a peer's bridge cannot reach the lead's machine, so the absence is
/// something the carrier observed and then told it. Nothing is deleted on the
/// word of that absence — an orphaned row stands until the lead answers again
/// (which clears the mark) or the user removes it.
class SessionMemberOf {
  final SessionMemberRef ref;

  /// `lead`, for the same reason [SessionMember.role] exists: the field outlives
  /// a leadership move.
  final String role;
  final int joinedAt;
  final String state;
  final int? orphanedAt;

  const SessionMemberOf({
    required this.ref,
    required this.joinedAt,
    this.role = 'lead',
    this.state = 'active',
    this.orphanedAt,
  });

  bool get isOrphaned => state == 'orphaned';

  Map<String, dynamic> toJson() => {
    ...ref.toJson(),
    'role': role,
    'joinedAt': joinedAt,
    'state': state,
    if (orphanedAt != null) 'orphanedAt': orphanedAt,
  };

  /// Null on an unaddressable ref; an unrecognised `state` falls back to
  /// `active`, matching [SessionMember.fromJson] — the row is still a member of
  /// something, and the badge says the weaker true thing.
  static SessionMemberOf? fromJson(Map<String, dynamic> j) {
    final ref = SessionMemberRef.fromJson(j);
    if (ref == null) return null;
    final state = j['state'];
    return SessionMemberOf(
      ref: ref,
      joinedAt: (j['joinedAt'] as num?)?.toInt() ?? 0,
      state: state is String && _kMemberOfStates.contains(state)
          ? state
          : 'active',
      orphanedAt: (j['orphanedAt'] as num?)?.toInt(),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionMemberOf &&
          other.ref == ref &&
          other.role == role &&
          other.joinedAt == joinedAt &&
          other.state == state &&
          other.orphanedAt == orphanedAt;

  @override
  int get hashCode => Object.hash(ref, role, joinedAt, state, orphanedAt);
}

class SessionEntry {
  final String id;
  final String name;
  final int createdAt;
  final int lastUsedAt;
  final bool archived;
  final bool running;

  /// True from the moment the bridge's delete for this session passes its
  /// dirty/unpushed preflight until the row is removed — the 3–15s window of
  /// PTY teardown and `git worktree remove` the app otherwise has no signal
  /// for. A refused delete never sets it, so it is safe to act on: a row that
  /// carries it is already being taken apart.
  ///
  /// Transient live state, never durable metadata: the bridge does not persist
  /// it, and [CachedSessionsStore] strips it both entering the cache and on the
  /// way to disk. Only the live session list carries it. A restored `true`
  /// would be a row stuck pending with nothing left alive to clear it.
  final bool deleting;
  final String? tool;
  final String? command;
  final bool forkSupported;

  /// The session this one was forked from, or null for every session that was
  /// not. Provenance, not a link: the source may since have been renamed,
  /// archived or deleted, so nothing may resolve it and render its name.
  final String? forkedFromSessionId;
  final String? args;
  final String mode;
  final String approvalPolicy;

  /// False when this session's agent-native conversation can no longer be
  /// resumed, so a mode switch would silently start a fresh one. Deliberately
  /// NOT "can this session switch mode" — that also depends on the tool having
  /// a chat driver, which arrives separately as `chatCapable` on `agent:tools`
  /// and must stay separable: missing history HIDES the mode control, an agent
  /// without a driver DISABLES the Chat cell.
  final bool agentSessionResumable;

  /// This session's own work status, folded per session on the bridge from the
  /// notifications this slot fired. Null when the bridge doesn't report it (an
  /// older build, or the disk-only peek, which has no runtime to reduce) —
  /// callers must treat null as "unknown", never as idle-and-safe.
  ///
  /// Advisory only. The bridge cannot tell a genuine mid-turn block from a
  /// post-turn idle nudge, so this may louden a confirmation but must never
  /// gate one.
  final AgentWorkStatus? workStatus;
  final String? agentSessionId;
  final String checkoutId;
  final String checkoutKind;
  final String? checkoutBranch;
  final String checkoutState;
  final bool sharedWorkspace;
  final int workspaceMemberCount;

  /// Null for every shared session, for a bridge predating the feature, and for
  /// an isolated session whose project declares no `worktree.setup` — all three
  /// mean "nothing to report", which is today's behaviour exactly.
  final SessionSetup? setup;

  /// The sessions on other machines that this one leads. Empty for every
  /// ordinary session — the field is absent on the wire rather than an empty
  /// array, so a row that never joined a multi-machine session parses exactly
  /// as it did before the feature existed.
  ///
  /// Carries released members as well as active ones: the list is the record of
  /// the whole session, and only [SessionMember.isActive] entries are part of it
  /// now. Read it BEFORE deleting the lead, because it dies with the row.
  final List<SessionMember> members;

  /// The session on another machine that leads this one, or null when this
  /// session leads itself. A row never carries both this and [members]: a peer
  /// cannot lead.
  final SessionMemberOf? memberOf;

  const SessionEntry({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.lastUsedAt,
    required this.archived,
    required this.running,
    this.deleting = false,
    this.tool,
    this.command,
    this.forkSupported = false,
    this.forkedFromSessionId,
    this.args,
    this.mode = 'terminal',
    this.approvalPolicy = 'default',
    this.agentSessionResumable = true,
    this.workStatus,
    this.agentSessionId,
    this.checkoutId = 'main',
    this.checkoutKind = 'main',
    this.checkoutBranch,
    this.checkoutState = 'ready',
    this.sharedWorkspace = false,
    this.workspaceMemberCount = 1,
    this.setup,
    this.members = const [],
    this.memberOf,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'createdAt': createdAt,
    'lastUsedAt': lastUsedAt,
    'archived': archived,
    'running': running,
    // Emitted only when true, matching the other optional fields: it is
    // transient, so an explicit `false` would be noise on every row.
    if (deleting) 'deleting': true,
    if (tool != null) 'tool': tool,
    if (command != null) 'command': command,
    if (forkSupported) 'forkSupported': true,
    if (forkedFromSessionId != null) 'forkedFromSessionId': forkedFromSessionId,
    if (args != null) 'args': args,
    'mode': mode,
    'approvalPolicy': approvalPolicy,
    'agentSessionResumable': agentSessionResumable,
    if (workStatus != null) 'workStatus': workStatus!.name,
    if (agentSessionId != null) 'agentSessionId': agentSessionId,
    'checkoutId': checkoutId,
    'checkoutKind': checkoutKind,
    if (checkoutBranch != null) 'checkoutBranch': checkoutBranch,
    'checkoutState': checkoutState,
    if (sharedWorkspace) 'sharedWorkspace': true,
    if (workspaceMemberCount > 1) 'workspaceMemberCount': workspaceMemberCount,
    if (setup != null) 'setup': setup!.toJson(),
    if (members.isNotEmpty)
      'members': [for (final m in members) m.toJson()],
    if (memberOf != null) 'memberOf': memberOf!.toJson(),
  };

  factory SessionEntry.fromJson(Map<String, dynamic> j) => SessionEntry(
    id: j['id'] as String,
    name: j['name'] as String,
    createdAt: (j['createdAt'] as num).toInt(),
    lastUsedAt: (j['lastUsedAt'] as num).toInt(),
    archived: j['archived'] as bool,
    // `running` is process-lifetime state, absent from disk-only sources (the
    // control-plane peek and the persisted cache both omit/strip it); default
    // false rather than throwing.
    running: j['running'] as bool? ?? false,
    // False on absence, and that direction is deliberate: every disk-only
    // source (the cache, the control-plane peek) and any bridge predating the
    // flag say nothing, while a wrong `true` strands the row inert forever.
    deleting: j['deleting'] as bool? ?? false,
    tool: j['tool'] as String?,
    command: j['command'] as String?,
    forkSupported: j['forkSupported'] as bool? ?? false,
    forkedFromSessionId: j['forkedFromSessionId'] as String?,
    args: j['args'] as String?,
    mode: j['mode'] as String? ?? 'terminal',
    approvalPolicy: j['approvalPolicy'] as String? ?? 'default',
    // Optimistic on absence, matching the bridge schema's default: a stale
    // `true` only lets the mode control show for a conversation that turns out
    // to be gone, while a wrong `false` would hide it outright.
    agentSessionResumable: j['agentSessionResumable'] as bool? ?? true,
    // Null on absence, and on any value this build doesn't know: a status the
    // app can't name is not a status it should act on.
    workStatus: AgentWorkStatus.fromWire(j['workStatus']),
    agentSessionId: j['agentSessionId'] as String?,
    checkoutId: j['checkoutId'] as String? ?? 'main',
    checkoutKind: j['checkoutKind'] as String? ?? 'main',
    checkoutBranch: j['checkoutBranch'] as String?,
    checkoutState: j['checkoutState'] as String? ?? 'ready',
    sharedWorkspace: j['sharedWorkspace'] as bool? ?? false,
    workspaceMemberCount: (j['workspaceMemberCount'] as num?)?.toInt() ?? 1,
    setup: switch (j['setup']) {
      final Map<String, dynamic> m => SessionSetup.fromJson(m),
      _ => null,
    },
    members: _membersFromJson(j['members']),
    memberOf: switch (j['memberOf']) {
      final Map<String, dynamic> m => SessionMemberOf.fromJson(m),
      _ => null,
    },
  );

  /// Parse a wire `members` array, dropping any element that is not an
  /// addressable member. One malformed entry costs its own row and not the
  /// session's whole member list — the same discipline [listFromJson] applies
  /// one level up.
  static List<SessionMember> _membersFromJson(Object? raw) {
    if (raw is! List) return const [];
    final out = <SessionMember>[];
    for (final e in raw) {
      if (e is! Map) continue;
      final m = SessionMember.fromJson(e.cast<String, dynamic>());
      if (m != null) out.add(m);
    }
    return out;
  }

  /// Parse a JSON array of session maps, skipping any non-map element. Shared by
  /// the control-plane peek and the live sessions service so the two decoders
  /// never drift.
  static List<SessionEntry> listFromJson(List<dynamic>? raw) => [
    for (final s in raw ?? const [])
      if (s is Map<String, dynamic>) SessionEntry.fromJson(s),
  ];

  SessionEntry copyWith({
    String? name,
    int? lastUsedAt,
    bool? archived,
    bool? running,
    bool? deleting,
    SessionSetup? setup,
    List<SessionMember>? members,
    SessionMemberOf? memberOf,

    /// Drop the provisioning state instead of carrying it over. Never pass this
    /// together with [setup] — the two are contradictory answers to the same
    /// field.
    bool clearSetup = false,
  }) => SessionEntry(
    id: id,
    name: name ?? this.name,
    createdAt: createdAt,
    lastUsedAt: lastUsedAt ?? this.lastUsedAt,
    archived: archived ?? this.archived,
    running: running ?? this.running,
    deleting: deleting ?? this.deleting,
    tool: tool,
    command: command,
    forkSupported: forkSupported,
    forkedFromSessionId: forkedFromSessionId,
    args: args,
    mode: mode,
    approvalPolicy: approvalPolicy,
    agentSessionResumable: agentSessionResumable,
    workStatus: workStatus,
    agentSessionId: agentSessionId,
    checkoutId: checkoutId,
    checkoutKind: checkoutKind,
    checkoutBranch: checkoutBranch,
    checkoutState: checkoutState,
    sharedWorkspace: sharedWorkspace,
    workspaceMemberCount: workspaceMemberCount,
    setup: clearSetup ? null : (setup ?? this.setup),
    members: members ?? this.members,
    memberOf: memberOf ?? this.memberOf,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionEntry &&
          other.id == id &&
          other.name == name &&
          other.createdAt == createdAt &&
          other.lastUsedAt == lastUsedAt &&
          other.archived == archived &&
          other.running == running &&
          other.deleting == deleting &&
          other.tool == tool &&
          other.command == command &&
          other.forkSupported == forkSupported &&
          other.forkedFromSessionId == forkedFromSessionId &&
          other.args == args &&
          other.mode == mode &&
          other.approvalPolicy == approvalPolicy &&
          other.agentSessionResumable == agentSessionResumable &&
          other.workStatus == workStatus &&
          other.agentSessionId == agentSessionId &&
          other.checkoutId == checkoutId &&
          other.checkoutKind == checkoutKind &&
          other.checkoutBranch == checkoutBranch &&
          other.checkoutState == checkoutState &&
          other.sharedWorkspace == sharedWorkspace &&
          other.workspaceMemberCount == workspaceMemberCount &&
          other.setup == setup &&
          listEquals(other.members, members) &&
          other.memberOf == memberOf;

  @override
  // hashAll, not hash: the field list is past Object.hash's 20-argument ceiling.
  int get hashCode => Object.hashAll([
    id,
    name,
    createdAt,
    lastUsedAt,
    archived,
    running,
    deleting,
    tool,
    command,
    forkSupported,
    forkedFromSessionId,
    args,
    mode,
    approvalPolicy,
    agentSessionResumable,
    workStatus,
    agentSessionId,
    checkoutId,
    checkoutKind,
    checkoutBranch,
    checkoutState,
    sharedWorkspace,
    workspaceMemberCount,
    setup,
    Object.hashAll(members),
    memberOf,
  ]);
}
