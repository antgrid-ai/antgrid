import 'dart:convert';
import 'dart:io' show HttpException, SocketException;

import 'package:http/http.dart' as http;

import '../models/task.dart';
import 'cookie_api_client.dart';

/// Tasks and labels over HTTPS against the account service
/// (`web/src/routes/tasks.ts`).
///
/// Tasks do NOT travel over the relay: they belong to the account, not to a
/// machine, so the list works with every dev machine offline and fails
/// entirely with the network offline. [TaskApiError.network] is the one that
/// distinguishes the two for the UI.
class TasksApi extends CookieApiClient {
  TasksApi({
    required super.licenseApiUrl,
    required super.cookieProvider,
    super.httpClient,
  });

  Future<List<Task>> listTasks({
    Set<TaskStatus>? status,
    String? projectId,
    String? assignee,
    int? limit,
  }) async {
    final query = <String, dynamic>{
      if (status != null && status.isNotEmpty)
        'status': status.map((s) => s.wire).toList(growable: false),
      'projectId': ?projectId,
      'assignee': ?assignee,
      if (limit != null) 'limit': '$limit',
    };
    final body = await _send(
      'GET',
      _uri('/tasks', query),
      subject: _Subject.task,
    );
    final raw = body['tasks'];
    if (raw is! List) return const [];
    return raw.map(Task.fromJson).whereType<Task>().toList(growable: false);
  }

  Future<Task> getTask(int number) async {
    final body = await _send(
      'GET',
      _uri('/tasks/$number'),
      subject: _Subject.task,
    );
    return _task(body);
  }

  /// [publish] is required and always sent, never defaulted: the route rejects
  /// a create with the field missing, so a build that forgot it fails instead
  /// of guessing — and guessing here means a private note becoming a public
  /// issue. [publishRepoId] names the destination when the task's project
  /// resolves more than one target.
  Future<Task> createTask({
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
    final res = await _send(
      'POST',
      _uri('/tasks'),
      subject: _Subject.task,
      payload: {
        'title': title,
        'body': ?body,
        if (status != null) 'status': status.wire,
        'priority': ?priority,
        'projectId': ?projectId,
        'assignee': ?assignee?.toJson(),
        'labelIds': ?labelIds,
        'publish': publish,
        'publishRepoId': ?publishRepoId,
      },
    );
    return _task(res);
  }

  /// Publishes an existing task: the server links it to [repoId] and queues
  /// the issue create in one transaction. [repoId] may be omitted only when
  /// the task's project resolves exactly one target.
  Future<Task> publishTask({required int number, String? repoId}) async {
    final res = await _send(
      'POST',
      _uri('/tasks/$number/publish'),
      subject: _Subject.task,
      payload: {'repoId': ?repoId},
    );
    return _task(res);
  }

  /// Stops the two syncing. The issue is left untouched, and the external
  /// identity stays on the row as a tombstone — which is what lets a later
  /// publish name the issue that already exists.
  Future<Task> unlinkTask({required int number}) async {
    final res = await _send(
      'POST',
      _uri('/tasks/$number/unlink'),
      subject: _Subject.task,
      payload: const {},
    );
    return _task(res);
  }

  /// Where a task filed against [projectId] could be published. Empty when the
  /// project has no repo the account may push to — which is the whole reason
  /// the publish affordances are absent rather than disabled.
  Future<List<TaskPublishTarget>> listPublishTargets({
    required String projectId,
  }) async {
    final body = await _send(
      'GET',
      _uri('/tasks/publish-targets', {'projectId': projectId}),
      subject: _Subject.task,
    );
    final raw = body['targets'];
    if (raw is! List) return const [];
    return raw
        .map(TaskPublishTarget.fromJson)
        .whereType<TaskPublishTarget>()
        .toList(growable: false);
  }

  Future<Task> updateTask(int number, TaskPatch patch) async {
    final res = await _send(
      'PATCH',
      _uri('/tasks/$number'),
      subject: _Subject.task,
      payload: patch.toJson(),
    );
    return _task(res);
  }

  /// Reorder: the task lands between the two neighbours, each named by its own
  /// number. Both null puts it at the head of the list.
  Future<Task> moveTask(
    int number, {
    int? previousNumber,
    int? nextNumber,
  }) async {
    final res = await _send(
      'POST',
      _uri('/tasks/$number/move'),
      subject: _Subject.task,
      payload: {'previousNumber': previousNumber, 'nextNumber': nextNumber},
    );
    return _task(res);
  }

  Future<void> deleteTask(int number) async {
    await _send('DELETE', _uri('/tasks/$number'), subject: _Subject.task);
  }

  Future<Task> attachLabel(int number, String labelId) async {
    final res = await _send(
      'POST',
      _uri('/tasks/$number/labels'),
      subject: _Subject.task,
      payload: {'labelId': labelId},
    );
    return _task(res);
  }

  Future<Task> detachLabel(int number, String labelId) async {
    final res = await _send(
      'DELETE',
      _uri('/tasks/$number/labels/$labelId'),
      subject: _Subject.task,
    );
    return _task(res);
  }

  /// Replaces the whole set in one write, which is what a multi-select editor
  /// commits — attach/detach exist for the single-chip paths.
  Future<Task> setLabels(int number, List<String> labelIds) async {
    final res = await _send(
      'PUT',
      _uri('/tasks/$number/labels'),
      subject: _Subject.task,
      payload: {'labelIds': labelIds},
    );
    return _task(res);
  }

  /// Settles one field an import could not reconcile. `local` restores the
  /// edit that was set aside, `remote` keeps what the provider sent.
  ///
  /// [field] is a conflict field's wire spelling, or the literal `labels` for
  /// the dropped-label marker — which only takes `remote`, because a label
  /// restored here would still be absent on the provider with nothing to push
  /// it back. A field already settled answers [TaskApiError.notConflicted].
  Future<Task> resolveConflict({
    required int number,
    required String field,
    required String take,
  }) async {
    final res = await _send(
      'POST',
      _uri('/tasks/$number/conflict/resolve'),
      subject: _Subject.task,
      payload: {'field': field, 'take': take},
    );
    return _task(res);
  }

  /// Starts sending one field again after Antgrid stopped, and queues the value
  /// the provider never took.
  ///
  /// [field] is the wire spelling the block was reported under. A field that is
  /// already getting through — cleared elsewhere, or accepted by the provider
  /// since the page was drawn — answers [TaskApiError.notBlocked].
  Future<Task> clearPushBlock({
    required int number,
    required String field,
  }) async {
    final res = await _send(
      'POST',
      _uri('/tasks/$number/push-block/clear'),
      subject: _Subject.task,
      payload: {'field': field},
    );
    return _task(res);
  }

  /// The projects a task can be filed against.
  ///
  /// Not under `/tasks`: a project is account state the bridge writes bindings
  /// against, and this reads the same rows. It lives on this client because the
  /// task surfaces are the only thing in the app that needs it.
  Future<List<TaskProject>> listProjects() async {
    final body = await _send(
      'GET',
      _uri('/account/projects'),
      subject: _Subject.task,
    );
    final raw = body['projects'];
    if (raw is! List) return const [];
    return raw
        .map(TaskProject.fromJson)
        .whereType<TaskProject>()
        .toList(growable: false);
  }

  Future<List<TaskLabel>> listLabels({String? projectId}) async {
    final body = await _send(
      'GET',
      _uri('/labels', {'projectId': ?projectId}),
      subject: _Subject.label,
    );
    final raw = body['labels'];
    if (raw is! List) return const [];
    return raw
        .map(TaskLabel.fromJson)
        .whereType<TaskLabel>()
        .toList(growable: false);
  }

  /// Get-or-create: a label is identified by its name, so two clients naming
  /// `bug` mean one label and the second gets 200 with the row it meant.
  Future<TaskLabel> createLabel({
    required String name,
    required String color,
    String? description,
    String? projectId,
  }) async {
    final res = await _send(
      'POST',
      _uri('/labels'),
      subject: _Subject.label,
      payload: {
        'name': name,
        'color': color,
        'description': ?description,
        'projectId': ?projectId,
      },
    );
    final label = TaskLabel.fromJson(res['label']);
    if (label == null) {
      throw const TaskApiException(
        TaskApiError.unknown,
        'The account service answered with a label this app could not read.',
      );
    }
    return label;
  }

  Future<void> deleteLabel(String id) async {
    await _send('DELETE', _uri('/labels/$id'), subject: _Subject.label);
  }

  Uri _uri(String path, [Map<String, dynamic>? query]) {
    final uri = Uri.parse('$licenseApiUrl$path');
    if (query == null || query.isEmpty) return uri;
    return uri.replace(queryParameters: query);
  }

  Task _task(Map<String, Object?> body) {
    final task = Task.fromJson(body['task']);
    if (task == null) {
      throw const TaskApiException(
        TaskApiError.unknown,
        'The account service answered with a task this app could not read.',
      );
    }
    return task;
  }

  Future<Map<String, Object?>> _send(
    String method,
    Uri uri, {
    required _Subject subject,
    Map<String, Object?>? payload,
  }) async {
    final cookie = await cookieProvider();
    if (cookie == null || cookie.isEmpty) {
      throw TaskApiException(
        TaskApiError.unauthenticated,
        _message(TaskApiError.unauthenticated, subject),
      );
    }
    final request = http.Request(method, uri)
      ..headers['cookie'] = cookie
      ..headers['accept'] = 'application/json';
    if (payload != null) {
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode(payload);
    }

    http.Response res;
    try {
      res = await http.Response.fromStream(await client.send(request));
    } on SocketException catch (e) {
      throw TaskApiException(
        TaskApiError.network,
        _message(TaskApiError.network, subject),
        detail: e.message,
      );
    } on HttpException catch (e) {
      throw TaskApiException(
        TaskApiError.network,
        _message(TaskApiError.network, subject),
        detail: e.message,
      );
    } on http.ClientException catch (e) {
      throw TaskApiException(
        TaskApiError.network,
        _message(TaskApiError.network, subject),
        detail: e.message,
      );
    }

    final decoded = _decode(res.body);
    if (res.statusCode >= 200 && res.statusCode < 300) return decoded;
    throw _refusal(res.statusCode, decoded, subject);
  }

  Map<String, Object?> _decode(String body) {
    if (body.isEmpty) return const {};
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, Object?> ? decoded : const {};
    } catch (_) {
      return const {};
    }
  }
}

/// Every refusal the task and label routes can answer with, plus the two
/// carrier-level failures the routes never see. Mapped exhaustively so a status
/// code never reaches a person.
enum TaskApiError {
  unauthenticated,
  noAccount,
  notFound,
  invalidTitle,
  projectNotFound,
  assigneeNotMember,
  labelNotFound,
  labelOutOfScope,
  neighboursOutOfOrder,
  notConflicted,
  localValueUnreadable,
  notBlocked,
  labelsLocalUnsupported,
  publishNotAvailable,
  publishRepoAmbiguous,
  publishRepoNotFound,
  publishRequiresSession,
  alreadyLinked,
  notLinked,
  invalidLabelName,
  invalidLabelColor,
  badRequest,
  network,
  server,
  unknown,
}

class TaskApiException implements Exception {
  const TaskApiException(
    this.error,
    this.message, {
    this.statusCode,
    this.labelId,
    this.userId,
    this.detail,
  });

  final TaskApiError error;

  /// Ready to render. Every construction site fills this from [_message], so
  /// no caller has to decide what a code means to a person.
  final String message;
  final int? statusCode;

  /// Carried by `LABEL_NOT_FOUND` / `LABEL_OUT_OF_SCOPE` so the caller can drop
  /// the offending chip rather than reloading the whole set.
  final String? labelId;

  /// Carried by `ASSIGNEE_NOT_MEMBER`.
  final String? userId;

  /// Transport-level text, for logs. Never shown.
  final String? detail;

  /// The one refusal worth an automatic retry: everything else is a decision
  /// the server already made and will make again.
  bool get isRetryable =>
      error == TaskApiError.network || error == TaskApiError.server;

  @override
  String toString() => 'TaskApiException(${error.name}): $message';
}

/// What the failing call was about, which is all that separates "that task no
/// longer exists" from "that label no longer exists" on a shared 404.
enum _Subject { task, label }

TaskApiException _refusal(
  int status,
  Map<String, Object?> body,
  _Subject subject,
) {
  final code = body['error'];
  final labelId = body['labelId'] is String ? body['labelId'] as String : null;
  final userId = body['userId'] is String ? body['userId'] as String : null;
  final error = switch ((status, code)) {
    (401, _) => TaskApiError.unauthenticated,
    // Above the bare 403 arm: publishing refuses a device credential with its
    // own code, and "you are not a member of this account" is the wrong
    // sentence for a carrier the route will not take.
    (_, 'PUBLISH_REQUIRES_SESSION') => TaskApiError.publishRequiresSession,
    // Membership is the only other thing 403 can mean here — the routes carry
    // no subscription gate, so there is no paid arm to confuse it with.
    (403, _) => TaskApiError.noAccount,
    // Above the bare 404 arm, not with the other code arms below it:
    // `PUBLISH_REPO_NOT_FOUND` answers 404, and "that task no longer exists"
    // is the wrong sentence for a repo that stopped qualifying.
    (_, 'PUBLISH_NOT_AVAILABLE') => TaskApiError.publishNotAvailable,
    (_, 'PUBLISH_REPO_AMBIGUOUS') => TaskApiError.publishRepoAmbiguous,
    (_, 'PUBLISH_REPO_NOT_FOUND') => TaskApiError.publishRepoNotFound,
    (_, 'ALREADY_LINKED') => TaskApiError.alreadyLinked,
    (_, 'NOT_LINKED') => TaskApiError.notLinked,
    (404, _) => TaskApiError.notFound,
    (_, 'INVALID_TITLE') => TaskApiError.invalidTitle,
    (_, 'PROJECT_NOT_FOUND') => TaskApiError.projectNotFound,
    (_, 'ASSIGNEE_NOT_MEMBER') => TaskApiError.assigneeNotMember,
    (_, 'LABEL_NOT_FOUND') => TaskApiError.labelNotFound,
    (_, 'LABEL_OUT_OF_SCOPE') => TaskApiError.labelOutOfScope,
    (_, 'NEIGHBOURS_OUT_OF_ORDER') => TaskApiError.neighboursOutOfOrder,
    (_, 'NOT_CONFLICTED') => TaskApiError.notConflicted,
    (_, 'LOCAL_VALUE_UNREADABLE') => TaskApiError.localValueUnreadable,
    (_, 'NOT_BLOCKED') => TaskApiError.notBlocked,
    (_, 'LABELS_LOCAL_UNSUPPORTED') => TaskApiError.labelsLocalUnsupported,
    (_, 'INVALID_LABEL_NAME') => TaskApiError.invalidLabelName,
    (_, 'INVALID_LABEL_COLOR') => TaskApiError.invalidLabelColor,
    (400, _) => TaskApiError.badRequest,
    _ when status >= 500 => TaskApiError.server,
    _ => TaskApiError.unknown,
  };
  return TaskApiException(
    error,
    _message(error, subject),
    statusCode: status,
    labelId: labelId,
    userId: userId,
  );
}

String _message(TaskApiError error, _Subject subject) => switch (error) {
  TaskApiError.unauthenticated =>
    'Your Antgrid session has expired. Sign in again to reach your tasks.',
  TaskApiError.noAccount =>
    'This sign-in belongs to no Antgrid account yet, so it has no tasks. '
        'Ask an owner to invite you, or create an account.',
  TaskApiError.notFound => switch (subject) {
    _Subject.task => 'That task no longer exists — it may have been deleted.',
    _Subject.label => 'That label no longer exists — it may have been deleted.',
  },
  TaskApiError.invalidTitle =>
    'A task needs a title: 1 to 500 characters, and not only spaces.',
  TaskApiError.projectNotFound =>
    'That project is not in this account. Pick another, or leave the task '
        'unfiled.',
  TaskApiError.assigneeNotMember =>
    'That person is not an active member of this account, so the task cannot '
        'be assigned to them.',
  TaskApiError.labelNotFound =>
    'That label was deleted while you were editing. Reopen the label picker to '
        'see the current set.',
  TaskApiError.labelOutOfScope =>
    'That label belongs to a different project, so it cannot go on this task.',
  TaskApiError.neighboursOutOfOrder =>
    'The list changed underneath the drag. Refresh and move the task again.',
  TaskApiError.notConflicted =>
    'That difference was already settled — somewhere else, or on another '
        'device. The task above is the version that won.',
  TaskApiError.localValueUnreadable =>
    'The version that was set aside can no longer be read, so it cannot be '
        'restored. Keeping the imported one is the only way out of this '
        'difference.',
  TaskApiError.notBlocked =>
    'That field is already being sent again — it was started somewhere else, '
        'or on another device. The task above is the current version.',
  // Unreachable from this app — the dropped-label line offers one action, and
  // it is the accepted one. Mapped anyway: this enum is what stops a status
  // code reaching a person.
  TaskApiError.labelsLocalUnsupported =>
    'A dropped label cannot be restored from here — it would sit on this task '
        'and not on the issue. Add it back through the label picker instead.',
  TaskApiError.publishNotAvailable =>
    'This task has nowhere to go on GitHub. It needs to be filed against a '
        'project, and that project needs a connected repo Antgrid may write '
        'to.',
  TaskApiError.publishRepoAmbiguous =>
    'This project is connected to more than one repo, so pick the one the '
        'issue should be created in.',
  TaskApiError.publishRepoNotFound =>
    'That repo is no longer one this project can publish to — the connection '
        'may have been removed, or writing to it turned off.',
  // Unreachable from this app, which signs in with a session cookie. Mapped
  // anyway, for the reason every arm here is: an unmapped code reaches a person
  // as a status number.
  TaskApiError.publishRequiresSession =>
    'Publishing has to be done from a signed-in Antgrid session, not from a '
        'connected device or agent.',
  TaskApiError.alreadyLinked =>
    'This task is already on GitHub. Open the issue rather than publishing a '
        'second one.',
  TaskApiError.notLinked =>
    'This task is not linked to GitHub, so there is nothing to unlink. It may '
        'have been unlinked already, or on another device.',
  TaskApiError.invalidLabelName =>
    'A label name has to be 1 to 50 characters.',
  TaskApiError.invalidLabelColor =>
    'A label colour has to be six hex digits, like `d73a4a`.',
  TaskApiError.badRequest =>
    'The account service rejected that change as malformed. Nothing was saved.',
  TaskApiError.network =>
    'Tasks come from the Antgrid account service over the internet, not from '
        'your machines — check your connection and retry.',
  TaskApiError.server =>
    'The account service failed on that request. Nothing was saved; try again.',
  TaskApiError.unknown =>
    'The account service answered in a way this app did not expect.',
};

/// A partial write to one task.
///
/// Nullable fields default to [kUnset] rather than null because the server
/// reads the difference: an absent `assignee` leaves the assignee alone, a null
/// one unassigns. A plain nullable parameter cannot say both.
class TaskPatch {
  const TaskPatch({
    this.title,
    this.body,
    this.status,
    this.priority = kUnset,
    this.projectId = kUnset,
    this.assignee = kUnset,
    this.labelIds,
  });

  final String? title;
  final String? body;
  final TaskStatus? status;

  /// `int?` or [kUnset].
  final Object? priority;

  /// `String?` or [kUnset]. Null unfiles the task from its project.
  final Object? projectId;

  /// `TaskAssignee?` or [kUnset]. Null unassigns.
  final Object? assignee;
  final List<String>? labelIds;

  bool get isEmpty => toJson().isEmpty;

  Map<String, Object?> toJson() => {
    'title': ?title,
    'body': ?body,
    if (status != null) 'status': status!.wire,
    if (!identical(priority, kUnset)) 'priority': priority,
    if (!identical(projectId, kUnset)) 'projectId': projectId,
    if (!identical(assignee, kUnset))
      'assignee': (assignee as TaskAssignee?)?.toJson(),
    'labelIds': ?labelIds,
  };
}
