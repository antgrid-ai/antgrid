import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/project_catalog.dart';
import '../models/session_target.dart';
import '../widgets/new_session/picker_sources.dart';
import 'control_plane.dart';
import 'new_session_picker.dart';
import 'project_index.dart';
import 'projects.dart';

/// The composer target naming [member].
///
/// [running] says whether the project's core is already up on that machine;
/// a wrong `false` costs a redundant start, a wrong `true` a failed open, so
/// callers that do not know pass false.
PickerProject pickerProjectFor(
  ProjectMember member, {
  required String? folder,
  required bool running,
}) {
  if (member.machineId == kLocalMachineKey) {
    return PickerProject(
      id: member.projectId,
      name: member.name,
      detail: folder ?? '',
      isLocal: true,
    );
  }
  return PickerProject(
    id: RemoteProject(
      machineUuid: member.machineId,
      projectId: member.projectId,
    ).registrationId,
    name: member.name,
    detail: '',
    isLocal: false,
    machineUuid: member.machineId,
    projectId: member.projectId,
    running: running,
  );
}

/// Point the New Session composer at [member]: its machine as the source and
/// its project as the target.
void selectComposerMember(ProviderContainer ref, ProjectMember member) {
  String? folder;
  var running = false;
  if (member.machineId == kLocalMachineKey) {
    for (final p in ref.read(projectsProvider)) {
      if (p.projectId == member.projectId) folder = p.folder;
    }
  } else {
    // Peek only: reading a member that does not exist yet would dial it.
    final cp = controlPlaneStateProvider(member.machineId);
    if (ref.exists(cp)) {
      for (final ap in ref.read(cp).value?.projects ?? const []) {
        if (ap.projectId == member.projectId) running = ap.running;
      }
    }
  }
  final target = pickerProjectFor(member, folder: folder, running: running);
  ref
      .read(selectedSourceIdProvider.notifier)
      .set(
        member.machineId == kLocalMachineKey
            ? 'local'
            : 'machine:${member.machineId}',
      );
  ref.read(selectedTargetProjectProvider.notifier).set(target);
}

/// Point the New Session composer at [view]'s project, on the machine
/// [defaultComposerMachine] picks. Leaves the composer alone when no machine
/// holding it is online: a target on a dead machine could only fail to start.
void pointComposerAtProject(ProviderContainer ref, ProjectView view) {
  final machineId = defaultComposerMachine(view);
  if (machineId == null) return;
  for (final m in view.members) {
    if (m.machineId == machineId) {
      selectComposerMember(ref, m);
      return;
    }
  }
}

/// The merged project the composer's target belongs to, if any.
final composerProjectViewProvider = Provider<ProjectView?>((ref) {
  final target = ref.watch(selectedTargetProjectProvider);
  if (target == null) return null;
  for (final v in ref.watch(projectViewsProvider)) {
    for (final m in v.group.members) {
      if (m.entryId == target.id) return v;
    }
  }
  return null;
});
