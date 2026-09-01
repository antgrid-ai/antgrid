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
