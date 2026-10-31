import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/agent_work_status.dart';
import '../models/project_catalog.dart';
import '../models/recent_session_row.dart';
import '../models/session_target.dart';
import '../widgets/new_session/picker_sources.dart';
import 'control_plane.dart';
import 'machine_directory.dart';
import 'new_session_picker.dart';
import 'project_index.dart';
import 'projects.dart';
import 'value_controller.dart';

/// The project the New Session canvas is showing, as a [ProjectGroup.key].
/// Null shows every recent session instead.
final selectedProjectGroupProvider =
    NotifierProvider<ValueController<String?>, String?>(
      () => ValueController(null),
    );

/// The machine card the user narrowed the project panel to, or null for all
/// of them. Cleared whenever a different project is opened.
final projectMachineFilterProvider =
    NotifierProvider<ValueController<String?>, String?>(
      () => ValueController(null),
    );

/// The open project under the current scope. Null when nothing is open, or the
/// project is no longer known at all.
final selectedProjectViewProvider = Provider<ProjectView?>((ref) {
  final key = ref.watch(selectedProjectGroupProvider);
  if (key == null) return null;
  for (final v in ref.watch(projectViewsProvider)) {
    if (v.group.key == key) return v;
  }
  return null;
});

/// "On 3 machines · 2 running · 1 needs you" — the project panel's subline.
String projectSummaryLine(ProjectView view) {
  final machines = view.machines.length;
  final parts = [
    'On $machines machine${machines == 1 ? '' : 's'}',
    if (view.liveCount > 0) '${view.liveCount} running',
    if (view.needsYouCount > 0)
      '${view.needsYouCount} need${view.needsYouCount == 1 ? 's' : ''} you',
    if (view.hiddenMachines.isNotEmpty)
      '${view.hiddenMachines.length} hidden by scope',
  ];
  return parts.join(' · ');
}

/// One run of sessions under a header in the project panel.
@immutable
class ProjectSessionGroup {
  const ProjectSessionGroup({
    required this.label,
    required this.rows,
    this.bucket,
  });

  final String label;
  final List<RecentSessionRow> rows;

  /// Set when grouped by status, so the header can tint the needs-you run.
  final SessionBucket? bucket;
}

/// How the project panel (and the Recent list) groups sessions.
enum SessionGrouping { status, machine, agent }

/// Group [rows] (already most-recent first) for the project panel. Pure.
///
/// By status the order is fixed — Needs you, Running, Done — because what
/// waits on the user leads however old it is. By machine it follows the
/// machine directory; by agent, the most recently used agent leads.
List<ProjectSessionGroup> groupProjectSessions({
  required List<RecentSessionRow> rows,
  required SessionGrouping by,
  required AgentWorkStatus Function(RecentSessionRow) statusOf,
  required List<MachineInfo> machines,
  required String Function(RecentSessionRow) agentOf,
}) {
  switch (by) {
    case SessionGrouping.status:
      const labels = {
        SessionBucket.needsYou: 'Needs you',
        SessionBucket.running: 'Running',
        SessionBucket.done: 'Done',
      };
      return [
        for (final bucket in SessionBucket.values)
          if (rows.where((r) => sessionBucket(statusOf(r)) == bucket).toList()
              case final inBucket when inBucket.isNotEmpty)
            ProjectSessionGroup(
              label: labels[bucket]!,
              rows: inBucket,
              bucket: bucket,
            ),
      ];
    case SessionGrouping.machine:
      return [
        for (final m in machines)
          if (rows.where((r) => machineIdOf(r.origin) == m.id).toList()
              case final onMachine when onMachine.isNotEmpty)
            ProjectSessionGroup(label: m.name, rows: onMachine),
      ];
    case SessionGrouping.agent:
      final byAgent = <String, List<RecentSessionRow>>{};
      for (final r in rows) {
        (byAgent[agentOf(r)] ??= []).add(r);
      }
      // Insertion order is first appearance in a most-recent-first list, which
      // is already "most recently used agent first".
      return [
        for (final e in byAgent.entries)
          ProjectSessionGroup(label: e.key, rows: e.value),
      ];
  }
}

/// What a machine card says about one copy of the project.
@immutable
class MachineCardInfo {
  const MachineCardInfo({
    required this.machine,
    required this.member,
    required this.sessionCount,
    required this.worktreeCount,
  });

  final MachineInfo machine;
  final ProjectMember member;
  final int sessionCount;

  /// Isolated checkouts in use on this machine, counted from its sessions:
  /// the only worktree evidence the app holds for a project it is not focused
  /// on.
  final int worktreeCount;
}

/// One card per in-scope machine holding [view]'s project. Pure.
List<MachineCardInfo> machineCardsFor(ProjectView view) {
  final cards = <MachineCardInfo>[];
  for (final m in view.machines) {
    for (final member in view.members) {
      if (member.machineId != m.id) continue;
      var sessions = 0;
      final checkouts = <String>{};
      for (final r in view.sessions) {
        if (r.origin.registrationId != member.entryId) continue;
        sessions++;
        if (r.session.checkoutKind != 'main') {
          checkouts.add(r.session.checkoutId);
        }
      }
      cards.add(
        MachineCardInfo(
          machine: m,
          member: member,
          sessionCount: sessions,
          worktreeCount: checkouts.length,
        ),
      );
    }
  }
  return cards;
}

/// How the project panel groups its sessions; Status by default, so what
/// waits on the user is at the top.
final projectGroupingProvider =
    NotifierProvider<ValueController<SessionGrouping>, SessionGrouping>(
      () => ValueController(SessionGrouping.status),
    );

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

/// Open [view]'s panel on the New Session canvas, with the composer already
/// pointed at its default machine.
void openProjectPanel(ProviderContainer ref, ProjectView view) {
  enterNewSession(ref);
  if (ref.read(selectedProjectGroupProvider) != view.group.key) {
    ref.read(projectMachineFilterProvider.notifier).set(null);
  }
  ref.read(selectedProjectGroupProvider.notifier).set(view.group.key);
  final machineId = defaultComposerMachine(view);
  if (machineId == null) return;
  for (final m in view.members) {
    if (m.machineId == machineId) {
      selectComposerMember(ref, m);
      return;
    }
  }
}

/// Back to every recent session.
void closeProjectPanel(ProviderContainer ref) {
  ref.read(selectedProjectGroupProvider.notifier).set(null);
  ref.read(projectMachineFilterProvider.notifier).set(null);
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
