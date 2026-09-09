/// Dart mirror of the account service's task shapes (`web/src/routes/tasks.ts`).
///
/// A task is addressed by [Task.number] and nothing else: the server never puts
/// a task uuid on the wire, so there is deliberately no id field here to start
/// addressing one by. A label is the exception — its uuid IS its only handle,
/// because the attach/detach/set verbs take nothing else.
library;

/// Antgrid's own vocabulary, not a provider passthrough. Mirrors
/// `TaskStatusSchema` in `web/src/models/task.ts` — a status one side can
/// produce and the other cannot store is dropped silently.
enum TaskStatus {
  open('open', 'Open'),
  inProgress('in_progress', 'In progress'),
  blocked('blocked', 'Blocked'),
  done('done', 'Done'),
  cancelled('cancelled', 'Cancelled');

  const TaskStatus(this.wire, this.label);

  final String wire;
  final String label;

  static TaskStatus? fromWire(Object? raw) {
    for (final s in TaskStatus.values) {
      if (s.wire == raw) return s;
    }
    return null;
  }

  /// The two statuses that close a task. The server derives `closedAt` from
  /// this same split, so a client filter that disagrees would show a "not done"
  /// task carrying a close date.
  bool get isClosed => this == TaskStatus.done || this == TaskStatus.cancelled;
}

/// Null until the task is linked to a provider issue. `unlinked` is a
/// tombstone: the external identity stays on the row so the UI can still name
/// the issue the task used to be.
enum TaskSyncState {
  pending('pending'),
  synced('synced'),
  conflict('conflict'),
  unlinked('unlinked');

  const TaskSyncState(this.wire);

  final String wire;

  static TaskSyncState? fromWire(Object? raw) {
    for (final s in TaskSyncState.values) {
      if (s.wire == raw) return s;
    }
    return null;
  }
}

/// Who a task is on. Only [TaskMemberAssignee] is writable over HTTP — the
/// external arm is a read-only snapshot of a provider identity, written by the
/// import path and by nothing a client can reach.
sealed class TaskAssignee {
  const TaskAssignee();

  static TaskAssignee? fromJson(Object? raw) {
    if (raw is! Map) return null;
    return switch (raw['kind']) {
      'member' when raw['userId'] is String => TaskMemberAssignee(
        raw['userId'] as String,
      ),
      'external' when raw['externalId'] is String && raw['login'] is String =>
        TaskExternalAssignee(
          externalId: raw['externalId'] as String,
          login: raw['login'] as String,
          avatarUrl: raw['avatarUrl'] is String
              ? raw['avatarUrl'] as String
              : null,
        ),
      _ => null,
    };
  }

  /// Null where the arm has no writable spelling, which the request builder
  /// treats as "do not send".
  Map<String, Object?>? toJson();
}

class TaskMemberAssignee extends TaskAssignee {
  const TaskMemberAssignee(this.userId);

  final String userId;

  @override
  Map<String, Object?> toJson() => {'kind': 'member', 'userId': userId};

  @override
  bool operator ==(Object other) =>
      other is TaskMemberAssignee && other.userId == userId;

  @override
  int get hashCode => userId.hashCode;
}

class TaskExternalAssignee extends TaskAssignee {
  const TaskExternalAssignee({
    required this.externalId,
    required this.login,
    this.avatarUrl,
  });

  final String externalId;
  final String login;
  final String? avatarUrl;

  @override
  Map<String, Object?>? toJson() => null;

  @override
  bool operator ==(Object other) =>
      other is TaskExternalAssignee && other.externalId == externalId;

  @override
  int get hashCode => externalId.hashCode;
}

class TaskLabel {
  const TaskLabel({
    required this.id,
    required this.name,
    required this.color,
    this.projectId,
    this.description,
  });

  /// Six hex digits, no leading `#` — the provider's own spelling, kept
  /// verbatim so a round trip to GitHub does not rewrite it. Chosen against a
  /// near-white surface, which is why nothing renders it as a fill.
  final String color;
  final String id;
  final String name;

  /// Null for an account-wide label; set for one scoped to a project, which is
  /// what `LABEL_OUT_OF_SCOPE` refuses a cross-project attach on.
  final String? projectId;
  final String? description;

  static TaskLabel? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final name = raw['name'];
    if (id is! String || name is! String) return null;
    return TaskLabel(
      id: id,
      name: name,
      color: raw['color'] is String ? raw['color'] as String : '',
      projectId: raw['projectId'] is String ? raw['projectId'] as String : null,
      description: raw['description'] is String
          ? raw['description'] as String
          : null,
    );
  }

  @override
  bool operator ==(Object other) => other is TaskLabel && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// One field both sides edited between two syncs. The provider's value is what
/// the task holds now; [localValue] is the edit that was set aside and can be
/// restored from the detail sheet.
///
/// [remoteValue] for `body` is provider prose — on a public repo, written by a
/// stranger — and is NOT covered by the untrusted-body mitigation that
/// `source` plus the external columns drive on [Task.body]. Nothing may route
/// it into a launch brief or any other text an agent reads as instruction; it
/// exists to be shown to a person choosing between two versions.
class TaskConflictField {
  const TaskConflictField({
    required this.field,
    required this.localValue,
    required this.remoteValue,
    this.at,
  });

  /// The wire spelling (`title`, `body`, `status`, `assignee`), which is also
  /// what the resolve route takes — so a field this app has no renderer for is
  /// still resolvable, and is kept rather than dropped.
  final String field;

  /// Typed per [field] by the server and left dynamic here on purpose: one
  /// class covers four unrelated shapes, and a per-field type would only move
  /// the switch from the renderer into the parser.
  final Object? localValue;
  final Object? remoteValue;

  /// When the two edits were found to disagree. Null on a payload whose stamp
  /// this app could not read.
  final DateTime? at;

  static TaskConflictField? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final field = raw['field'];
    if (field is! String || field.isEmpty) return null;
    return TaskConflictField(
      field: field,
      localValue: raw['localValue'],
      remoteValue: raw['remoteValue'],
      at: _date(raw['at']),
    );
  }
}

/// What an import could not reconcile on one task.
///
/// Everything here is data loss shaped: [fields] is what the provider
/// overwrote, [labelRemoveWins] is what got dropped. Labels never put a task in
/// the conflict sync state on their own — one side removed a label the other
/// still had, which has one honest outcome — so this can be non-null on a task
/// whose [Task.syncState] is `synced`.
class TaskConflict {
  const TaskConflict({this.fields = const [], this.labelRemoveWins = const []});

  final List<TaskConflictField> fields;

  /// Labels dropped because one side removed them while the other still had
  /// them. Names, not ids: the label may no longer exist to have an id.
  final List<String> labelRemoveWins;

  /// Nothing to show parses as null rather than as an empty block — an
  /// acknowledged conflict and a conflict that never happened read the same to
  /// a person, so they must render the same.
  static TaskConflict? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final fields = raw['fields'] is List
        ? (raw['fields'] as List)
              .map(TaskConflictField.fromJson)
              .whereType<TaskConflictField>()
              .toList(growable: false)
        : const <TaskConflictField>[];
    final labels = raw['labelRemoveWins'] is List
        ? (raw['labelRemoveWins'] as List)
              .whereType<String>()
              .toList(growable: false)
        : const <String>[];
    if (fields.isEmpty && labels.isEmpty) return null;
    return TaskConflict(fields: fields, labelRemoveWins: labels);
  }
}

/// One field Antgrid stopped sending outward.
///
/// A push that comes back accepted while changing nothing on the provider is
/// counted, and past a threshold the field stops being sent at all. That has no
/// expiry by design — a timer would restart the loop the count exists to stop —
/// so the only way back is the action beside this entry.
class TaskPushBlockedField {
  const TaskPushBlockedField({
    required this.field,
    required this.reason,
    required this.count,
    this.lastAt,
  });

  /// The wire spelling (`title`, `body`, `status`, `labels`), which is also what
  /// the clear route takes — so a field this app has no name for can still be
  /// started again, and is kept rather than dropped.
  final String field;

  /// The server's own sentence about what the provider did with the value.
  /// Shown verbatim: it is the only account of why this field stopped moving.
  final String reason;

  /// How many pushes came back having changed nothing.
  final int count;

  /// The last of them. Null on a payload whose stamp this app could not read.
  final DateTime? lastAt;

  static TaskPushBlockedField? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final field = raw['field'];
    if (field is! String || field.isEmpty) return null;
    return TaskPushBlockedField(
      field: field,
      reason: raw['reason'] is String ? raw['reason'] as String : '',
      count: raw['count'] is num ? (raw['count'] as num).toInt() : 0,
      lastAt: _date(raw['lastAt']),
    );
  }
}

/// Everything on one task that stopped syncing outward.
class TaskPushBlock {
  const TaskPushBlock({this.fields = const []});

  final List<TaskPushBlockedField> fields;

  /// Nothing blocked parses as null rather than as an empty block, for the
  /// reason [TaskConflict.fromJson] does the same: a task whose values are all
  /// reaching the provider must carry no marker at all.
  static TaskPushBlock? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final fields = raw['fields'] is List
        ? (raw['fields'] as List)
              .map(TaskPushBlockedField.fromJson)
              .whereType<TaskPushBlockedField>()
              .toList(growable: false)
        : const <TaskPushBlockedField>[];
    if (fields.isEmpty) return null;
    return TaskPushBlock(fields: fields);
  }
}

/// Distinguishes "leave this field alone" from "set it to null" in a patch.
/// Three of the update body's fields are both nullable and optional, and the
/// server reads the difference — absent leaves the assignee, `null` unassigns.
const Object kUnset = _Unset();

class _Unset {
  const _Unset();
}

class Task {
  const Task({
    required this.number,
    required this.title,
    required this.body,
    required this.status,
    required this.sortKey,
    required this.source,
    required this.createdBy,
    required this.createdAt,
    required this.updatedAt,
    this.priority,
    this.projectId,
    this.assignee,
    this.otherAssignees = const [],
    this.labels = const [],
    this.externalProvider,
    this.externalId,
    this.externalKey,
    this.externalUrl,
    this.syncState,
    this.conflict,
    this.pushBlocked,
    this.closedAt,
    String? displayId,
  }) : _displayId = displayId;

  final int number;
  final String title;
  final String body;
  final TaskStatus status;
  final int? priority;
  final String? projectId;
  final String sortKey;

  /// Where the task was born: `local`, or a provider key once import ships.
  /// Anything but `local` means the body was written outside this account and
  /// is untrusted input to an agent.
  final String source;
  final TaskAssignee? assignee;

  /// The assignees the provider holds that [assignee] could not: Antgrid keeps
  /// one, GitHub allows ten, and the server hands over the rest with the chosen
  /// one already removed. Read-only in every direction — the assignee never
  /// pushes, so this is a statement about the provider, not about Antgrid, and
  /// nothing here can be edited or cleared from this app. Empty for a local
  /// task, for an import with at most one assignee, and for a snapshot taken
  /// before the field existed.
  final List<TaskAssignee> otherAssignees;
  final List<TaskLabel> labels;
  final String? externalProvider;

  /// The provider's opaque id. Stable across a rename, and never shown to a
  /// user — [externalKey] is the readable half of the same identity.
  final String? externalId;

  /// How the provider names the issue to a human (`acme/relay#12`). Absent on
  /// an account service older than this field, which is why every reader has
  /// to tolerate null rather than fall back to [externalId].
  final String? externalKey;
  final String? externalUrl;
  final TaskSyncState? syncState;

  /// What the last sync could not reconcile, or null when there is nothing to
  /// settle. Not derivable from [syncState]: the conflict state survives until
  /// every field is resolved, and a label drop carries no sync state at all.
  final TaskConflict? conflict;

  /// What stopped reaching the provider, or null when everything on this task
  /// is getting through. Independent of [conflict] and of [syncState]: a task
  /// whose last import agreed with us can still hold a value the provider keeps
  /// declining, and does not sit in the conflict state for it.
  final TaskPushBlock? pushBlocked;

  final String createdBy;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? closedAt;

  bool get isLocal => source == 'local';

  /// Server-formatted (`displayId`), because the prefix belongs to the server:
  /// `web/src/tasks/display-id.ts` owns both spellings and the route resolves
  /// either, so a client that built the string itself would be a second place
  /// to change the day an account picks its own prefix. The fallback covers
  /// only an account service older than that field.
  final String? _displayId;

  /// The display key everywhere in the UI. Mono, never sans — it is data.
  String get ref => _displayId ?? 'ANT-$number';

  static Task? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final number = raw['number'];
    final status = TaskStatus.fromWire(raw['status']);
    if (number is! int || status == null) return null;
    return Task(
      number: number,
      title: raw['title'] is String ? raw['title'] as String : '',
      body: raw['body'] is String ? raw['body'] as String : '',
      status: status,
      priority: raw['priority'] is num ? (raw['priority'] as num).toInt() : null,
      projectId: raw['projectId'] is String ? raw['projectId'] as String : null,
      sortKey: raw['sortKey'] is String ? raw['sortKey'] as String : '',
      source: raw['source'] is String ? raw['source'] as String : 'local',
      assignee: TaskAssignee.fromJson(raw['assignee']),
      otherAssignees: raw['otherAssignees'] is List
          ? (raw['otherAssignees'] as List)
                .map(TaskAssignee.fromJson)
                .whereType<TaskAssignee>()
                .toList(growable: false)
          : const [],
      labels: raw['labels'] is List
          ? (raw['labels'] as List)
                .map(TaskLabel.fromJson)
                .whereType<TaskLabel>()
                .toList(growable: false)
          : const [],
      externalProvider: raw['externalProvider'] is String
          ? raw['externalProvider'] as String
          : null,
      externalId: raw['externalId'] is String
          ? raw['externalId'] as String
          : null,
      externalKey: raw['externalKey'] is String
          ? raw['externalKey'] as String
          : null,
      externalUrl: raw['externalUrl'] is String
          ? raw['externalUrl'] as String
          : null,
      syncState: TaskSyncState.fromWire(raw['syncState']),
      conflict: TaskConflict.fromJson(raw['conflict']),
      pushBlocked: TaskPushBlock.fromJson(raw['pushBlocked']),
      createdBy: raw['createdBy'] is String ? raw['createdBy'] as String : '',
      createdAt:
          _date(raw['createdAt']) ?? DateTime.fromMillisecondsSinceEpoch(0),
      updatedAt:
          _date(raw['updatedAt']) ?? DateTime.fromMillisecondsSinceEpoch(0),
      closedAt: _date(raw['closedAt']),
      displayId: raw['displayId'] is String ? raw['displayId'] as String : null,
    );
  }

  /// Nullable fields take [kUnset] rather than a `clearX` flag, so "leave it"
  /// and "set it to null" can never be asked for at once.
  Task copyWith({
    String? title,
    String? body,
    TaskStatus? status,
    Object? priority = kUnset,
    Object? projectId = kUnset,
    Object? assignee = kUnset,
    List<TaskAssignee>? otherAssignees,
    List<TaskLabel>? labels,
    String? sortKey,
    DateTime? updatedAt,
    Object? conflict = kUnset,
    Object? pushBlocked = kUnset,
    Object? closedAt = kUnset,
  }) {
    return Task(
      number: number,
      title: title ?? this.title,
      body: body ?? this.body,
      status: status ?? this.status,
      priority: identical(priority, kUnset) ? this.priority : priority as int?,
      projectId: identical(projectId, kUnset)
          ? this.projectId
          : projectId as String?,
      sortKey: sortKey ?? this.sortKey,
      source: source,
      assignee: identical(assignee, kUnset)
          ? this.assignee
          : assignee as TaskAssignee?,
      otherAssignees: otherAssignees ?? this.otherAssignees,
      labels: labels ?? this.labels,
      externalProvider: externalProvider,
      externalId: externalId,
      externalKey: externalKey,
      externalUrl: externalUrl,
      syncState: syncState,
      conflict: identical(conflict, kUnset)
          ? this.conflict
          : conflict as TaskConflict?,
      pushBlocked: identical(pushBlocked, kUnset)
          ? this.pushBlocked
          : pushBlocked as TaskPushBlock?,
      createdBy: createdBy,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      closedAt: identical(closedAt, kUnset)
          ? this.closedAt
          : closedAt as DateTime?,
      displayId: _displayId,
    );
  }
}

DateTime? _date(Object? raw) =>
    raw is String ? DateTime.tryParse(raw)?.toLocal() : null;

/// One repo a task's project can be published into.
///
/// The account service resolves these from `IntegrationRepo` — the
/// provider's own granted-repo list — never from the client-asserted
/// `Project.repoKey`. So [slug] is what the API will actually address, which
/// is why every consent surface names it instead of the project's label.
class TaskPublishTarget {
  const TaskPublishTarget({
    required this.id,
    required this.owner,
    required this.name,
    required this.visibility,
    required this.publishNewByDefault,
  });

  final String id;
  final String owner;
  final String name;

  /// The raw column (`public` / `private`). Kept verbatim rather than parsed
  /// to a bool: a spelling this build does not know must not read as
  /// "private", which is the reassuring half of the pair.
  final String visibility;

  /// Positions the create form's toggle and nothing else. The create route
  /// takes `publish` as a required boolean with no server-side default, so
  /// this hint can never become the outcome by being dropped.
  final bool publishNewByDefault;

  /// `owner/name`, as the provider spells it.
  String get slug => '$owner/$name';

  /// The sentence every publish surface owes the user. One spelling, on the
  /// model, because the create form and the confirm sheet must not disagree
  /// about who will be able to read the issue.
  String get visibilitySentence => switch (visibility) {
    'public' => 'This repo is public, so the issue will be public.',
    'private' =>
      'This repo is private, so the issue is visible to whoever can see the '
          'repo.',
    _ => 'The issue will be exactly as visible as $slug is.',
  };

  static TaskPublishTarget? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final owner = raw['owner'];
    final name = raw['name'];
    if (id is! String || owner is! String || name is! String) return null;
    return TaskPublishTarget(
      id: id,
      owner: owner,
      name: name,
      visibility: raw['visibility'] is String
          ? raw['visibility'] as String
          : '',
      publishNewByDefault: raw['publishNewByDefault'] == true,
    );
  }

  @override
  bool operator ==(Object other) => other is TaskPublishTarget && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// Whether the task's edits currently reach a provider issue.
///
/// `unlinked` is a tombstone — the external identity survives on the row — so
/// the presence of [Task.externalId] alone is not the answer.
///
/// **Narrower than the account service's own predicate**, which also counts
/// `pending`: a task whose `issue.create` is still in the outbox reads as
/// unlinked here and as linked there. So the unlink action is not offered
/// during that window even though the service would accept it and cancel the
/// queued create.
extension TaskLinkState on Task {
  bool get isLinked =>
      externalId != null && syncState != TaskSyncState.unlinked;

  /// A previous link this task was unlinked from. The confirm sheet names it,
  /// because publishing again creates a SECOND issue and the first one is
  /// still there.
  bool get hasUnlinkedIdentity =>
      externalId != null && syncState == TaskSyncState.unlinked;

  /// Whether publishing may be OFFERED — the destination is a separate
  /// question, answered by the project's targets.
  ///
  /// `pending` with no [externalId] yet is a publish already in flight, and it
  /// has to be excluded here rather than left to [isLinked], which reads only
  /// the identity the drain has not written at that point. The service refuses
  /// the second press as `ALREADY_LINKED`; withholding the button is what stops
  /// a user being shown an action whose only outcome is a refusal banner.
  bool get isPublishable => !isLinked && syncState != TaskSyncState.pending;
}

/// A project a task can be filed against.
///
/// [repoKey] is the normalized origin remote, and it is the label of last
/// resort: a display name is whatever a machine reported when it bound its
/// checkout, so a row can arrive with nothing usable in it.
class TaskProject {
  const TaskProject({
    required this.id,
    required this.repoKey,
    required this.displayName,
  });

  final String id;
  final String repoKey;
  final String displayName;

  static TaskProject? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! String || id.isEmpty) return null;
    final repoKey = raw['repoKey'] is String ? raw['repoKey'] as String : '';
    final name = raw['displayName'] is String
        ? raw['displayName'] as String
        : '';
    return TaskProject(
      id: id,
      repoKey: repoKey,
      // Never blank: this string is the only handle the picker offers, so a row
      // that arrived without one falls back to the repo it came from.
      displayName: name.isNotEmpty ? name : repoKey,
    );
  }
}
