import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/ab_project.dart';
import '../models/session_target.dart';
import '../models/task.dart';
import 'agent_transport.dart' show selectedTargetProvider;
import 'control_plane.dart';
import 'drawer_expansion.dart';
import 'projects.dart';
import 'tasks.dart';

/// A task's account project and the folder on THIS machine that holds the same
/// repository, if any.
///
/// The join is `repoKey`, which the host learns for every opened folder and
/// [AbProject] persists — never the display name, which two repositories can
/// share and one repository can be checked out under differently.
class TaskProjectSource {
  const TaskProjectSource({
    required this.project,
    required this.local,
    this.remote = const [],
  });

  final TaskProject project;

  /// Null when no opened folder is this repository.
  final AbProject? local;

  /// Copies of this repository on OTHER machines of the account. Only machines
  /// the app already has open are searched — see [taskProjectResolutionProvider].
  final List<RemoteTaskProject> remote;

  /// Registration ids of every project that IS this repository: the local
  /// folder's project id, then each remote copy's compound `<uuid>.<projectId>`.
  /// Local first, because a session on this machine is the cheaper one to reach.
  List<String> get targetIds => [
    if (local != null) local!.projectId,
    for (final r in remote) r.registrationId,
  ];

  /// Whether a session could be started somewhere without cloning or opening a
  /// folder first.
  bool get reachable => targetIds.isNotEmpty;

  /// `https://host/owner/repo.git` for a repository key that names a real
  /// host, null for a `local:` key — those describe a folder on some machine,
  /// not something a clone can reach.
  String? get cloneUrl => cloneUrlForRepoKey(project.repoKey);
}

/// A project on another machine whose origin is a task's repository.
class RemoteTaskProject {
  const RemoteTaskProject({
    required this.machineUuid,
    required this.projectId,
    required this.label,
  });

  final String machineUuid;
  final String projectId;

  /// What the machine calls the project; falls back to its id.
  final String label;

  String get registrationId => RemoteProject(
    machineUuid: machineUuid,
    projectId: projectId,
  ).registrationId;
}

String? cloneUrlForRepoKey(String repoKey) {
  if (repoKey.isEmpty || repoKey.startsWith('local:')) return null;
  return 'https://$repoKey.git';
}

enum TaskProjectPhase {
  /// The task names no project, so there is nothing to resolve.
  none,

  /// The account's project list is still on its way.
  loading,

  /// The list could not be fetched, or does not contain the task's project.
  unresolved,

  resolved,
}

/// What is known about the project a task is filed against.
///
/// Distinguishes "not known YET" from "no project": collapsing them sent a task
/// for one repository into whichever project happened to be focused, because a
/// list that had not loaded read the same as a task with no project at all.
class TaskProjectResolution {
  const TaskProjectResolution._(this.phase, this.source);

  static const none = TaskProjectResolution._(TaskProjectPhase.none, null);
  static const loading = TaskProjectResolution._(
    TaskProjectPhase.loading,
    null,
  );
  static const unresolved = TaskProjectResolution._(
    TaskProjectPhase.unresolved,
    null,
  );

  factory TaskProjectResolution.resolved(TaskProjectSource source) =>
      TaskProjectResolution._(TaskProjectPhase.resolved, source);

  final TaskProjectPhase phase;
  final TaskProjectSource? source;

  /// True when the project is named but not yet known — Start must not guess.
  bool get blocksLaunch =>
      phase == TaskProjectPhase.loading || phase == TaskProjectPhase.unresolved;
}

final taskProjectResolutionProvider =
    Provider.family<TaskProjectResolution, String?>((ref, taskProjectId) {
      if (taskProjectId == null) return TaskProjectResolution.none;
      final projects = ref.watch(taskProjectsProvider);
      final list = projects.value;
      if (list == null) {
        return projects.hasError
            ? TaskProjectResolution.unresolved
            : TaskProjectResolution.loading;
      }
      final project = list.where((p) => p.id == taskProjectId).firstOrNull;
      if (project == null) return TaskProjectResolution.unresolved;
      final local = ref
          .watch(projectsProvider)
          .where((p) => p.repoKey != null && p.repoKey == project.repoKey)
          .firstOrNull;
      return TaskProjectResolution.resolved(
        TaskProjectSource(
          project: project,
          local: local,
          remote: _remoteCopies(ref, project.repoKey),
        ),
      );
    });

/// The resolved source, or null for every other phase. Callers that must tell
/// "not loaded" from "no project" read [taskProjectResolutionProvider].
final taskProjectSourceProvider = Provider.family<TaskProjectSource?, String?>(
  (ref, taskProjectId) =>
      ref.watch(taskProjectResolutionProvider(taskProjectId)).source,
);

/// The projects on other machines whose origin is [repoKey].
///
/// Searches only machines the app already holds a control-plane socket for — the
/// ones expanded in the drawer, plus the machine of a focused remote project.
/// Enumerating every machine here would dial them all from a task screen, which
/// is the connection storm the desktop's lazy control planes exist to avoid; a
/// machine the user has not opened simply is not offered until they open it.
List<RemoteTaskProject> _remoteCopies(Ref ref, String repoKey) {
  if (repoKey.isEmpty || repoKey.startsWith('local:')) return const [];
  final machines = <String>{
    // A bare uuid is a machine; a compound id (with a dot) is a project row.
    for (final id in ref.watch(expandedDrawerIdsProvider))
      if (!id.contains('.')) id,
    if (ref.watch(selectedTargetProvider) case RemoteProject(
      :final machineUuid,
    ))
      machineUuid,
  };
  return [
    for (final machine in machines)
      for (final p
          in ref.watch(controlPlaneStateProvider(machine)).value?.projects ??
              const [])
        if (p.repoKey == repoKey)
          RemoteTaskProject(
            machineUuid: machine,
            projectId: p.projectId,
            label: (p.label != null && p.label!.isNotEmpty)
                ? p.label!
                : p.projectId,
          ),
  ];
}
