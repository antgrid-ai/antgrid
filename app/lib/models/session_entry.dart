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

/// The Capability Card as it travels ON a membership, flattened: the OS the
/// member machine runs and the repo of the one project the membership is for.
///
/// Hand-mirrors the bridge `SessionMemberCardSchema` (`bridge/src/protocol.ts`),
/// which nests the six values as `{ os: {name, version, arch}, repo: {label,
/// remote, branch} }` — the wire shape lives in [toJson]/[fromJson] alone, and
/// the two groups are flat here because every reader wants a value, not a group.
///
/// Every field is nullable, top to bottom: the bridge that fills the card
/// already produces nulls for a project that is not a repo, and a machine that
/// could not answer must still be able to join. A card is what the lead's agent
/// is TOLD about its new peer, never something either side acts on.
///
/// [repoRemote] is the bridge's normalised credential-free `host[:port]/path`
/// match key, never a raw remote URL — the value is rendered into an agent's
/// prompt.
class SessionMemberCard {
  final String? osName;
  final String? osVersion;
  final String? osArch;
  final String? repoLabel;
  final String? repoRemote;
  final String? repoBranch;

  const SessionMemberCard._({
    this.osName,
    this.osVersion,
    this.osArch,
    this.repoLabel,
    this.repoRemote,
    this.repoBranch,
  });

  /// Clamps every value to the length the lead bridge refuses above, because a
  /// card is display metadata and a membership is not: an over-long branch name
  /// must cost its own tail, never the machine the user was joining.
  factory SessionMemberCard({
    String? osName,
    String? osVersion,
    String? osArch,
    String? repoLabel,
    String? repoRemote,
    String? repoBranch,
  }) => SessionMemberCard._(
    osName: _bounded(osName, _kMaxOsName),
    osVersion: _bounded(osVersion, _kMaxOsVersion),
    osArch: _bounded(osArch, _kMaxOsArch),
    repoLabel: _bounded(repoLabel, _kMaxRepoLabel),
    repoRemote: _bounded(repoRemote, _kMaxRepoRemote),
    repoBranch: _bounded(repoBranch, _kMaxRepoBranch),
  );

  /// A card that carries nothing, which is the same answer as no card at all —
  /// so nothing serialises an empty group and [fromJson] resolves one to null.
  bool get isEmpty =>
      osName == null &&
      osVersion == null &&
      osArch == null &&
      repoLabel == null &&
      repoRemote == null &&
      repoBranch == null;

  Map<String, dynamic> toJson() => {
    if (osName != null || osVersion != null || osArch != null)
      'os': {
        if (osName != null) 'name': osName,
        if (osVersion != null) 'version': osVersion,
        if (osArch != null) 'arch': osArch,
      },
    if (repoLabel != null || repoRemote != null || repoBranch != null)
      'repo': {
        if (repoLabel != null) 'label': repoLabel,
        if (repoRemote != null) 'remote': repoRemote,
        if (repoBranch != null) 'branch': repoBranch,
      },
  };

  /// Null for anything that is not a card with a value in it — a missing key, a
  /// non-map, a group of the wrong shape, a leaf that is not a string. The card
  /// is the least load-bearing thing on a membership, so a malformed one costs
  /// itself and never the member it arrived on.
  static SessionMemberCard? fromJson(Object? raw) {
    if (raw is! Map) return null;
    String? leaf(Object? group, String key) {
      if (group is! Map) return null;
      final v = group[key];
      return v is String && v.isNotEmpty ? v : null;
    }

    final os = raw['os'];
    final repo = raw['repo'];
    final card = SessionMemberCard(
      osName: leaf(os, 'name'),
      osVersion: leaf(os, 'version'),
      osArch: leaf(os, 'arch'),
      repoLabel: leaf(repo, 'label'),
      repoRemote: leaf(repo, 'remote'),
      repoBranch: leaf(repo, 'branch'),
    );
    return card.isEmpty ? null : card;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionMemberCard &&
          other.osName == osName &&
          other.osVersion == osVersion &&
          other.osArch == osArch &&
          other.repoLabel == repoLabel &&
          other.repoRemote == repoRemote &&
          other.repoBranch == repoBranch;

  @override
  int get hashCode =>
      Object.hash(osName, osVersion, osArch, repoLabel, repoRemote, repoBranch);
}

/// Hand-mirrored from the `.max()` on each leaf of the bridge
/// `SessionMemberCardSchema`, which is what actually refuses the record.
const int _kMaxOsName = 60;
const int _kMaxOsVersion = 200;
const int _kMaxOsArch = 30;
const int _kMaxRepoLabel = 120;
const int _kMaxRepoRemote = 300;
const int _kMaxRepoBranch = 250;

String? _bounded(String? value, int max) {
  if (value == null || value.isEmpty) return null;
  return value.length <= max ? value : value.substring(0, max);
}

/// Address of one session in a multi-machine session — the machine, project and
/// session that identify it, plus the labels a row renders with and the
/// Capability Card of the machine it names.
///
/// Hand-mirrors the bridge `SessionMemberRefSchema` (`bridge/src/protocol.ts`)
/// per the package convention that the Dart side mirrors the TS Zod schemas by
/// hand. The labels are carried rather than looked up because this rides every
/// `session:updated` frame and is rendered by rows served from the persisted
/// cache, which can resolve no other machine's names at all; the bridge bounds
/// their length for the same reason.
///
/// [card] rides along for the harder version of that reason: no bridge can read
/// another machine, so what the peer answered about itself at join time is the
/// only description of it the lead will ever hold. It reaches one reader — the
/// lead's agent, told what machine just joined it — and is fenced as data there,
/// because a hostname or a repo path in a WRAPPER would read as a grant.
class SessionMemberRef {
  /// The account device uuid, which is how the app addresses a machine — never
  /// a relay slot id or a hostname.
  final String machineId;
  final String projectId;
  final String sessionId;
  final String? machineLabel;
  final String? projectLabel;
  final String? sessionName;

  /// What the machine answered about itself when the membership was made. Null
  /// against a machine that could not answer and against a carrier predating
  /// the field; both are the same "no card" a reader must render.
  final SessionMemberCard? card;

  const SessionMemberRef({
    required this.machineId,
    required this.projectId,
    required this.sessionId,
    this.machineLabel,
    this.projectLabel,
    this.sessionName,
    this.card,
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
    if (card != null) 'card': card!.toJson(),
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
      card: SessionMemberCard.fromJson(j['card']),
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
          other.sessionName == sessionName &&
          other.card == card;

  @override
  int get hashCode => Object.hash(
    machineId,
    projectId,
    sessionId,
    machineLabel,
    projectLabel,
    sessionName,
    card,
  );
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
  );

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
          other.setup == setup;

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
  ]);
}
