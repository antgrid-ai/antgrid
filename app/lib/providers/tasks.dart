import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/agent_work_status.dart';
import '../models/session_entry.dart';
import '../models/task.dart';
import '../services/tasks_api.dart';
import 'auth.dart';
import 'sessions.dart'
    show activeSessionOrCachedProvider, selectableSessionsProvider;

/// Task state for the account-level list and the detail beside it.
///
/// Tasks are ACCOUNT-scoped and arrive over HTTPS from the web service — never
/// through the relay. That is the property the list exists to show: it works
/// with every dev machine offline, and not at all with the network offline.
/// Only *running* a task needs a live bridge.

final tasksApiProvider = Provider<TasksApi>((ref) {
  final auth = ref.read(authServiceProvider);
  return TasksApi(
    licenseApiUrl: ref.read(licenseApiUrlProvider),
    cookieProvider: () => auth.storage.readCookie(),
  );
});

/// Named scopes, not a query builder: triaging a long list is one keystroke,
/// not a filter expression.
enum TaskScope {
  mine('Mine'),
  running('Running'),
  unassigned('Unassigned'),
  allOpen('All open'),
  done('Done');

  const TaskScope(this.label);

  final String label;
}

/// Rows one list fetch asks for. Pinned to the `/tasks` route's own maximum —
/// anything larger is refused there, and anything smaller silently truncates a
/// set the client is about to narrow further.
const int kTaskListPageSize = 500;

const Set<TaskStatus> kOpenStatuses = {
  TaskStatus.open,
  TaskStatus.inProgress,
  TaskStatus.blocked,
};

/// The part of a filter the SERVER can answer. Split out with value equality so
/// typing in the in-view filter box, or toggling a label, never refetches —
/// only a change the server would answer differently does.
class TaskQuery {
  const TaskQuery({this.statuses = const {}, this.projectId, this.assignee});

  final Set<TaskStatus> statuses;
  final String? projectId;

  /// A member's user id, or the literal `me`, which the server resolves against
  /// the caller.
  final String? assignee;

  @override
  bool operator ==(Object other) =>
      other is TaskQuery &&
      other.projectId == projectId &&
      other.assignee == assignee &&
      other.statuses.length == statuses.length &&
      other.statuses.containsAll(statuses);

  @override
  int get hashCode =>
      Object.hash(projectId, assignee, Object.hashAllUnordered(statuses));
}

class TaskFilter {
  const TaskFilter({
    this.scope = TaskScope.allOpen,
    this.statuses = const {},
    this.projectId,
    this.assignee,
    this.labelIds = const {},
    this.query = '',
  });

  final TaskScope scope;

  /// Status chips layered on top of the scope. Empty means "whatever the scope
  /// implies".
  final Set<TaskStatus> statuses;
  final String? projectId;
  final String? assignee;

  /// Multiple labels are ANDed, matching GitHub — which is what anyone who has
  /// filtered issues expects.
  final Set<String> labelIds;

  /// The in-view text filter. Applied on the client: the list route has no
  /// text search.
  final String query;

  bool get hasNarrowingFilters =>
      statuses.isNotEmpty ||
      projectId != null ||
      assignee != null ||
      labelIds.isNotEmpty ||
      query.trim().isNotEmpty;

  /// Statuses the scope itself implies, before any chip narrows them.
  Set<TaskStatus> get scopeStatuses => switch (scope) {
    TaskScope.mine => kOpenStatuses,
    // The server has no notion of a live run, so the widest honest query is
    // "in progress"; [visibleTasksProvider] narrows it to tasks that actually
    // have a run.
    TaskScope.running => const {TaskStatus.inProgress},
    TaskScope.unassigned => kOpenStatuses,
    TaskScope.allOpen => kOpenStatuses,
    TaskScope.done => const {TaskStatus.done, TaskStatus.cancelled},
  };

  /// The statuses a row must hold to survive this filter, once the scope and
  /// any chips laid over it are both applied. Chips that fall entirely outside
  /// the scope replace it rather than emptying the list.
  Set<TaskStatus> get effectiveStatuses => statuses.isEmpty
      ? scopeStatuses
      : statuses.intersection(scopeStatuses).isEmpty
      ? statuses
      : statuses.intersection(scopeStatuses);

  /// Deliberately WIDER than this filter: the fetched list is a single shared
  /// store, and the drawer's per-project task nodes partition the same rows.
  /// A query narrowed to the surface's scope would empty every one of those
  /// nodes the moment someone picked "Mine" — so the open set is always
  /// fetched, and scope, assignee and project narrowing all run on the client
  /// in [visibleTasksProvider] instead.
  ///
  /// Only a CLOSED status widens it beyond the open set, and only while such a
  /// chip is held: task history is unbounded and must not be pulled by default.
  TaskQuery get serverQuery =>
      TaskQuery(statuses: {...kOpenStatuses, ...effectiveStatuses});

  TaskFilter copyWith({
    TaskScope? scope,
    Set<TaskStatus>? statuses,
    Object? projectId = kUnset,
    Object? assignee = kUnset,
    Set<String>? labelIds,
    String? query,
  }) => TaskFilter(
    scope: scope ?? this.scope,
    statuses: statuses ?? this.statuses,
    projectId: identical(projectId, kUnset)
        ? this.projectId
        : projectId as String?,
    assignee: identical(assignee, kUnset) ? this.assignee : assignee as String?,
    labelIds: labelIds ?? this.labelIds,
    query: query ?? this.query,
  );
}

class TaskFilterController extends Notifier<TaskFilter> {
  @override
  TaskFilter build() => const TaskFilter();

  /// Switching scope drops the status chips: they were narrowing a different
  /// set, and carrying them across is how a scope lands empty for no visible
  /// reason.
  void setScope(TaskScope scope) =>
      state = state.copyWith(scope: scope, statuses: const {});

  void toggleStatus(TaskStatus status) {
    final next = {...state.statuses};
    if (!next.add(status)) next.remove(status);
    state = state.copyWith(statuses: next);
  }

  void toggleLabel(String labelId) {
    final next = {...state.labelIds};
    if (!next.add(labelId)) next.remove(labelId);
    state = state.copyWith(labelIds: next);
  }

  void setProject(String? projectId) =>
      state = state.copyWith(projectId: projectId);

  void setAssignee(String? assignee) =>
      state = state.copyWith(assignee: assignee);

  void setQuery(String query) => state = state.copyWith(query: query);

  void clearFilters() => state = TaskFilter(scope: state.scope);
}

final taskFilterProvider = NotifierProvider<TaskFilterController, TaskFilter>(
  TaskFilterController.new,
);

final taskQueryProvider = Provider<TaskQuery>(
  (ref) => ref.watch(taskFilterProvider).serverQuery,
);

final taskListProvider = AsyncNotifierProvider<TaskListController, List<Task>>(
  TaskListController.new,
);

/// The list is the store: every mutation writes through it, so the detail view
/// and the row can never disagree about a task.
///
/// Writes are optimistic with rollback, because sync to a provider is
/// asynchronous by design and a field must never block on a round trip. A
/// failed write restores the previous list AND publishes the reason to
/// [taskMutationErrorProvider] — a silent snap-back is indistinguishable from a
/// mis-tap.
class TaskListController extends AsyncNotifier<List<Task>> {
  TasksApi get _api => ref.read(tasksApiProvider);

  @override
  Future<List<Task>> build() async {
    final query = ref.watch(taskQueryProvider);
    return _api.listTasks(
      status: query.statuses,
      projectId: query.projectId,
      assignee: query.assignee,
      // Ask for the route's ceiling, not its default: every narrowing the
      // server used to do now runs on the client (see [TaskFilter.serverQuery]),
      // so a page cut to the default 100 is a page the client then filters down
      // to a partial — a project node missing rows, or a "Done" scope rendering
      // empty because the first 100 by sortKey were all open. Still a cap, not
      // pagination: the list has no paging affordance to carry a second page.
      limit: kTaskListPageSize,
    );
  }

  /// Refetch through the provider rather than assigning state directly, so the
  /// previous list is retained under the reload — a refresh must not blank a
  /// list the user is reading down.
  Future<void> refresh() async {
    ref.invalidateSelf();
    try {
      await future;
    } catch (_) {
      // The failure is already on `state` as an AsyncError; rethrowing here
      // would only crash whichever detached callback asked for the refresh.
    }
  }

  /// Pull one task the current query did not return — a deep link, or a task
  /// whose status just moved it out of the view the user is standing in.
  Future<Task?> ensureLoaded(int number) async {
    final existing = state.value?.where((t) => t.number == number).firstOrNull;
    if (existing != null) return existing;
    try {
      final task = await _api.getTask(number);
      _upsert(task);
      return task;
    } on TaskApiException catch (e) {
      _fail(e, null);
      return null;
    }
  }

  /// [publish] has no default here either: every caller is a form that showed
  /// the user a switch, and a parameter with a default is how a build that
  /// never drew one starts creating public issues.
  Future<Task?> create({
    required String title,
    required bool publish,
    String? publishRepoId,
    String? body,
    TaskStatus? status,
    int? priority,
    String? projectId,
    TaskAssignee? assignee,
    List<String>? labelIds,
  }) async {
    try {
      final task = await _api.createTask(
        title: title,
        publish: publish,
        publishRepoId: publishRepoId,
        body: body,
        status: status,
        priority: priority,
        projectId: projectId,
        assignee: assignee,
        labelIds: labelIds,
      );
      _upsert(task);
      _clearError();
      return task;
    } on TaskApiException catch (e) {
      _fail(e, null);
      return null;
    }
  }

  /// Named `patchTask`, not `update`: `AsyncNotifier` already owns `update`,
  /// and shadowing it is a compile error the analyzer does not report.
  Future<Task?> patchTask(int number, TaskPatch patch, {Task? optimistic}) {
    return _write(
      number,
      optimistic: optimistic,
      call: () => _api.updateTask(number, patch),
      retry: () => patchTask(number, patch, optimistic: optimistic),
    );
  }

  Future<Task?> setStatus(int number, TaskStatus status) {
    final current = _find(number);
    return patchTask(
      number,
      TaskPatch(status: status),
      optimistic: current?.copyWith(status: status),
    );
  }

  Future<Task?> setTitle(int number, String title) {
    final current = _find(number);
    return patchTask(
      number,
      TaskPatch(title: title),
      optimistic: current?.copyWith(title: title),
    );
  }

  Future<Task?> setBody(int number, String body) {
    final current = _find(number);
    return patchTask(
      number,
      TaskPatch(body: body),
      optimistic: current?.copyWith(body: body),
    );
  }

  Future<Task?> setPriority(int number, int? priority) {
    final current = _find(number);
    return patchTask(
      number,
      TaskPatch(priority: priority),
      optimistic: current?.copyWith(priority: priority),
    );
  }

  /// Single-select and replacing, unlike labels: the account stores one
  /// assignee and never pushes it to a provider, so swapping it here cannot
  /// unassign anyone in a real repo and needs no ceremony.
  Future<Task?> setAssignee(int number, TaskAssignee? assignee) {
    final current = _find(number);
    return patchTask(
      number,
      TaskPatch(assignee: assignee),
      optimistic: current?.copyWith(assignee: assignee),
    );
  }

  Future<Task?> setProject(int number, String? projectId) {
    final current = _find(number);
    return patchTask(
      number,
      TaskPatch(projectId: projectId),
      optimistic: current?.copyWith(projectId: projectId),
    );
  }

  Future<Task?> attachLabel(int number, TaskLabel label) {
    final current = _find(number);
    return _write(
      number,
      optimistic: current == null || current.labels.contains(label)
          ? null
          : current.copyWith(labels: [...current.labels, label]),
      call: () => _api.attachLabel(number, label.id),
      retry: () => attachLabel(number, label),
    );
  }

  Future<Task?> detachLabel(int number, TaskLabel label) {
    final current = _find(number);
    return _write(
      number,
      optimistic: current?.copyWith(
        labels: current.labels
            .where((l) => l.id != label.id)
            .toList(growable: false),
      ),
      call: () => _api.detachLabel(number, label.id),
      retry: () => detachLabel(number, label),
    );
  }

  Future<Task?> setLabels(int number, List<TaskLabel> labels) {
    final current = _find(number);
    return _write(
      number,
      optimistic: current?.copyWith(labels: labels),
      call: () => _api.setLabels(
        number,
        labels.map((l) => l.id).toList(growable: false),
      ),
      retry: () => setLabels(number, labels),
    );
  }

  /// Settles one field both sides edited, or acknowledges the dropped labels
  /// with `field: 'labels'`.
  ///
  /// The one write here with no optimistic arm: taking either side also clears
  /// that field's marker, and clearing the last one moves the task out of the
  /// conflict sync state — three changes the server derives together, so
  /// guessing them locally would flash a row the reply contradicts.
  Future<Task?> resolveConflict(
    int number, {
    required String field,
    required String take,
  }) {
    return _write(
      number,
      optimistic: null,
      call: () =>
          _api.resolveConflict(number: number, field: field, take: take),
      retry: () => resolveConflict(number, field: field, take: take),
    );
  }

  /// Starts sending one field again after the account service stopped.
  ///
  /// No optimistic arm, for the same reason [resolveConflict] has none: the
  /// server drops the marker and queues the push together, and a task that
  /// looks unblocked here while the call is refused is a value the user
  /// believes is on its way.
  Future<Task?> clearPushBlock(int number, {required String field}) {
    return _write(
      number,
      optimistic: null,
      call: () => _api.clearPushBlock(number: number, field: field),
      retry: () => clearPushBlock(number, field: field),
    );
  }

  /// Creates the GitHub issue for a task that already exists. [repoId] may be
  /// omitted only when the task's project resolves exactly one target.
  ///
  /// No optimistic arm, and this is the write that can least afford one: the
  /// server links the repo, moves the task to `pending` and clears any
  /// identity a previous link left, all in one transaction. A task that reads
  /// as published while the call was refused is the worst lie this surface can
  /// tell — the user believes something is public that is not.
  Future<Task?> publish(int number, {String? repoId}) {
    return _write(
      number,
      optimistic: null,
      call: () => _api.publishTask(number: number, repoId: repoId),
      retry: () => publish(number, repoId: repoId),
    );
  }

  /// Stops syncing a linked task, leaving the issue alone.
  ///
  /// No optimistic arm, for the same reason [publish] has none: the state the
  /// row would show is a claim about what Antgrid will do to a public issue
  /// from now on, and it must come from the server that made the decision.
  Future<Task?> unlink(int number) {
    return _write(
      number,
      optimistic: null,
      call: () => _api.unlinkTask(number: number),
      retry: () => unlink(number),
    );
  }

  /// Reorder against the two rows the task lands between. Both null sends it to
  /// the head of the list.
  Future<Task?> move(int number, {int? previousNumber, int? nextNumber}) {
    return _write(
      number,
      optimistic: null,
      call: () => _api.moveTask(
        number,
        previousNumber: previousNumber,
        nextNumber: nextNumber,
      ),
      retry: () =>
          move(number, previousNumber: previousNumber, nextNumber: nextNumber),
      // The server re-keys the row, so the list order it answers with is the
      // only correct one — predicting it locally would show a position the
      // next fetch contradicts.
      refetchAfter: true,
    );
  }

  Future<bool> delete(int number) async {
    final snapshot = state.value;
    if (snapshot != null) {
      state = AsyncData(
        snapshot.where((t) => t.number != number).toList(growable: false),
      );
    }
    try {
      await _api.deleteTask(number);
      _clearError();
      return true;
    } on TaskApiException catch (e) {
      if (snapshot != null) state = AsyncData(snapshot);
      _fail(e, () => delete(number));
      return false;
    }
  }

  Future<Task?> _write(
    int number, {
    required Task? optimistic,
    required Future<Task> Function() call,
    required Future<void> Function() retry,
    bool refetchAfter = false,
  }) async {
    // Rolled back per task, not by restoring the whole list: two rows edited in
    // quick succession are two independent writes, and putting a whole snapshot
    // back would revert the one that succeeded along with the one that failed.
    final previous = _find(number);
    if (optimistic != null) _upsert(optimistic);
    try {
      final task = await call();
      _upsert(task);
      _clearError();
      if (refetchAfter) await refresh();
      return task;
    } on TaskApiException catch (e) {
      if (optimistic != null) {
        if (previous != null) {
          _upsert(previous);
        } else {
          _remove(number);
        }
      }
      _fail(e, retry);
      return null;
    }
  }

  Task? _find(int number) =>
      state.value?.where((t) => t.number == number).firstOrNull;

  void _upsert(Task task) {
    final current = state.value ?? const <Task>[];
    final index = current.indexWhere((t) => t.number == task.number);
    if (index < 0) {
      state = AsyncData([task, ...current]);
      return;
    }
    final next = [...current];
    next[index] = task;
    state = AsyncData(next);
  }

  void _remove(int number) {
    final current = state.value;
    if (current == null) return;
    state = AsyncData(
      current.where((t) => t.number != number).toList(growable: false),
    );
  }

  void _fail(TaskApiException error, Future<void> Function()? retry) {
    ref
        .read(taskMutationErrorProvider.notifier)
        .set(TaskMutationFailure(error: error, retry: retry));
  }

  void _clearError() => ref.read(taskMutationErrorProvider.notifier).set(null);
}

/// A write that was rolled back, with the reason and — where retrying is
/// meaningful — the same call again.
class TaskMutationFailure {
  const TaskMutationFailure({required this.error, this.retry});

  final TaskApiException error;
  final Future<void> Function()? retry;
}

class TaskMutationErrorController extends Notifier<TaskMutationFailure?> {
  @override
  TaskMutationFailure? build() => null;

  void set(TaskMutationFailure? failure) => state = failure;
}

final taskMutationErrorProvider =
    NotifierProvider<TaskMutationErrorController, TaskMutationFailure?>(
      TaskMutationErrorController.new,
    );

/// The rows actually rendered: the fetched set narrowed by everything the
/// server could not answer — the unassigned scope, label ANDing, the in-view
/// text filter, and whether a run is live.
final visibleTasksProvider = Provider<AsyncValue<List<Task>>>((ref) {
  final tasks = ref.watch(taskListProvider);
  final filter = ref.watch(taskFilterProvider);
  final runs = ref.watch(taskRunPresenceProvider);
  // Resolved here rather than inside the predicate: `me` is the signed-in
  // user's id, and the scope means nothing until it is known. `me` is also
  // accepted as an explicit assignee because [TaskQuery] documents that
  // spelling and the server used to be the one resolving it.
  final myUserId = ref.watch(currentUserProvider).value?.userId;
  final explicitAssignee = filter.assignee == 'me' ? myUserId : filter.assignee;
  final wantedAssignee =
      explicitAssignee ?? (filter.scope == TaskScope.mine ? myUserId : null);
  // The signed-in id is what "mine" MEANS, and the server no longer narrows by
  // it. Answering the empty list until it is known is the only honest option:
  // matching nothing shows everyone's tasks under "Mine".
  final mineUnresolved =
      wantedAssignee == null &&
      (filter.scope == TaskScope.mine || filter.assignee != null);

  return tasks.whenData((list) {
    if (mineUnresolved) return const <Task>[];
    final query = filter.query.trim().toLowerCase();
    final statuses = filter.effectiveStatuses;
    return list
        .where((task) {
          // Status, project and assignee moved here when the store's query was
          // widened to keep the drawer's per-project nodes whole — see
          // [TaskFilter.serverQuery]. The server no longer narrows any of them.
          if (!statuses.contains(task.status)) return false;
          if (filter.projectId != null && task.projectId != filter.projectId) {
            return false;
          }
          if (wantedAssignee != null) {
            final a = task.assignee;
            if (a is! TaskMemberAssignee || a.userId != wantedAssignee) {
              return false;
            }
          }
          if (filter.scope == TaskScope.unassigned && task.assignee != null) {
            return false;
          }
          if (filter.scope == TaskScope.running &&
              !runs.containsKey(task.number)) {
            return false;
          }
          if (filter.labelIds.isNotEmpty) {
            final ids = task.labels.map((l) => l.id).toSet();
            if (!ids.containsAll(filter.labelIds)) return false;
          }
          if (query.isNotEmpty) {
            final haystack =
                '${task.ref} ${task.title} ${task.body} '
                '${task.labels.map((l) => l.name).join(' ')}';
            if (!haystack.toLowerCase().contains(query)) return false;
          }
          return true;
        })
        .toList(growable: false)
      ..sort(_bySortKey);
  });
});

/// `sortKey` is a fractional-index string, so lexicographic order IS list
/// order. Number descending is the tiebreak for rows that predate a key.
int _bySortKey(Task a, Task b) {
  final byKey = a.sortKey.compareTo(b.sortKey);
  return byKey != 0 ? byKey : b.number.compareTo(a.number);
}

final selectedTaskNumberProvider =
    NotifierProvider<SelectedTaskController, int?>(SelectedTaskController.new);

class SelectedTaskController extends Notifier<int?> {
  @override
  int? build() => null;

  void select(int? number) => state = number;
}

final selectedTaskProvider = Provider<Task?>((ref) {
  final number = ref.watch(selectedTaskNumberProvider);
  if (number == null) return null;
  return ref
      .watch(taskListProvider)
      .value
      ?.where((t) => t.number == number)
      .firstOrNull;
});

final taskLabelsProvider = FutureProvider<List<TaskLabel>>((ref) async {
  return ref.watch(tasksApiProvider).listLabels();
});

/// Where a task filed against this project could be published.
///
/// Keyed by project uuid rather than by task number: the answer is a property
/// of the project's integration, so the create form — which has no task yet —
/// and an existing task's confirm sheet read the same list. An empty list, and
/// a load that failed, both mean the publish affordance is ABSENT: a dead
/// button on an irreversible action reads as a broken one.
final taskPublishTargetsProvider =
    FutureProvider.family<List<TaskPublishTarget>, String>((ref, projectId) {
      return ref
          .watch(tasksApiProvider)
          .listPublishTargets(projectId: projectId);
    });

/// A live run against a task: the highest-value thing this list can show.
///
/// [AgentWorkStatus.attention] means the agent is blocked on a permission or a
/// question and is waiting on a person — visible from the row, without opening
/// anything.
class TaskRunPresence {
  const TaskRunPresence({
    required this.status,
    this.agentKey,
    this.sessionName,
    this.machineName,
  });

  final AgentWorkStatus status;

  /// Registry key for the brand mark, per `agentCatalogProvider`'s contract:
  /// a key nothing has described renders as unknown, never as a default agent.
  final String? agentKey;
  final String? sessionName;
  final String? machineName;
}

/// The task's live session in the CURRENTLY FOCUSED project, or null.
///
/// A task's own `projectId` is an account uuid with no route to an app
/// project id (see `task_launcher.dart`'s own doc), so a task's session can
/// only ever have been created in whichever project was focused when Start
/// was pressed (`AppTaskLauncher.start`) — there is nowhere else to look.
/// A task run from a different Antgrid install, or in a project this one
/// does not currently have open, is simply not visible here.
final taskSessionProvider = Provider.family<SessionEntry?, int>((
  ref,
  taskNumber,
) {
  for (final session in ref.watch(selectableSessionsProvider)) {
    if (session.running && session.taskRef?.number == taskNumber) {
      return session;
    }
  }
  return null;
});

/// Live runs keyed by task number, derived from [taskSessionProvider] for
/// every session the focused project currently has running. A session's own
/// `workStatus` is advisory and may still be null moments after it starts —
/// [AgentWorkStatus.working] is the honest default for "running, nothing to
/// report yet", never a state this map omits the session for.
final taskRunPresenceProvider = Provider<Map<int, TaskRunPresence>>((ref) {
  return {
    for (final session in ref.watch(selectableSessionsProvider))
      if (session.running && session.taskRef != null)
        session.taskRef!.number: TaskRunPresence(
          status: session.workStatus ?? AgentWorkStatus.working,
          agentKey: session.tool,
          sessionName: session.name,
        ),
  };
});

/// The task the currently ACTIVE session was launched for, or null.
///
/// `taskRef` is fixed for the life of a session (set once at creation), so
/// [activeSessionOrCachedProvider] — which documents that same read-only-fixed
/// contract — is enough here without needing the live stream. Read by the Git
/// tab so a task's own session shows which task its changes belong to; a
/// session created outside a task, or a `taskRef` naming a task this list has
/// not fetched, both read as null (the "no run" case, never a broken link).
final focusedSessionTaskProvider = Provider<Task?>((ref) {
  final taskRef = ref.watch(activeSessionOrCachedProvider)?.taskRef;
  if (taskRef == null) return null;
  final tasks = ref.watch(taskListProvider).value ?? const <Task>[];
  for (final task in tasks) {
    if (task.number == taskRef.number) return task;
  }
  return null;
});

/// Every open task in the account, regardless of project — what the sidebar's
/// permanent Tasks entry counts. `null` while the account-wide fetch has not
/// landed yet, so the badge can stay absent instead of flashing a false zero.
final openTaskCountProvider = Provider<int?>((ref) {
  final tasks = ref.watch(taskListProvider).value;
  if (tasks == null) return null;
  return tasks.where((t) => !t.status.isClosed).length;
});

/// Starts an agent session from a task.
///
/// The other half of the seam: the detail header renders its primary action
/// from whether this resolves, and explains itself when it does not, so
/// wiring the launch is an override here rather than an edit to the detail.
abstract class TaskLauncher {
  /// Why launching is unavailable right now, or null when it is available.
  /// Rendered verbatim, so it must name the reason — never "unavailable".
  String? unavailableReason(Task task);

  Future<void> start(Task task);
}

final taskLauncherProvider = Provider<TaskLauncher?>((ref) => null);

/// The account's projects, as the task surfaces see them.
///
/// A different namespace from the app's own `AbProject` ids, which are
/// per-machine: this is the `projectId` uuid a task actually carries, and the
/// only thing a publish destination can be resolved from.
final taskProjectsProvider = FutureProvider<List<TaskProject>>((ref) async {
  return ref.watch(tasksApiProvider).listProjects();
});

/// Repository identity → the account project filed against it.
///
/// The join the drawer needs: a project row knows its `repoKey` (the host folds
/// it from the origin remote), a task knows its account `projectId`, and
/// `projects_account_repo_key` makes the pair 1:1 within an account — so this
/// map can never be ambiguous.
///
/// A repoKey absent from this map means the account has no project bound to it
/// yet, which is not the same as having no tasks: the binding is reported by
/// the bridge when a project opens, so a folder never opened since the feature
/// landed simply has nowhere to join to.
final taskProjectIdByRepoKeyProvider = Provider<Map<String, String>>((ref) {
  final projects = ref.watch(taskProjectsProvider).value ?? const [];
  return {
    for (final project in projects)
      if (project.repoKey.isNotEmpty) project.repoKey: project.id,
  };
});

/// The OPEN tasks filed against one account project, in list order.
///
/// A partition of [taskListProvider], never its own fetch. One store is what
/// keeps the optimistic write-through in [TaskListController] coherent — N
/// per-project stores could disagree about a task the moment one of them wrote
/// — and it costs the drawer no round trip at all. [TaskFilter.serverQuery] is
/// kept wide enough that this partition is whole whatever the surface is
/// filtered to.
///
/// Closed tasks are dropped: this backs a navigation peek, and a tree that
/// accumulates every finished task stops being scannable.
final openTasksForProjectProvider = Provider.family<List<Task>, String>((
  ref,
  projectId,
) {
  final tasks = ref.watch(taskListProvider).value ?? const [];
  return tasks
      .where((t) => t.projectId == projectId && !t.status.isClosed)
      .toList(growable: false)
    ..sort(_bySortKey);
});

/// Project uuid → display name.
///
/// Synchronous because three widgets label a task with it while rendering a
/// list; a load still in flight or refused answers the empty map, and those
/// callers fall back to the short uuid in mono rather than inventing a name.
final taskProjectNamesProvider = Provider<Map<String, String>>((ref) {
  final projects = ref.watch(taskProjectsProvider).value ?? const [];
  return {for (final project in projects) project.id: project.displayName};
});

/// Someone a task can be assigned to.
class TaskAssigneeCandidate {
  const TaskAssigneeCandidate({
    required this.userId,
    required this.displayName,
  });

  final String userId;
  final String displayName;
}

/// Who the assignee picker may offer.
///
/// Just the signed-in user today, which is the whole truth: the account service
/// has no members-list route, so there is no way to name a teammate without
/// guessing a user id — and a guess is what `ASSIGNEE_NOT_MEMBER` refuses.
final taskAssigneeCandidatesProvider = Provider<List<TaskAssigneeCandidate>>((
  ref,
) {
  final user = ref.watch(currentUserProvider).value;
  if (user == null) return const [];
  return [TaskAssigneeCandidate(userId: user.userId, displayName: user.email)];
});
