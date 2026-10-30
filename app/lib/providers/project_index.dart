import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../demo/demo_identity.dart';
import '../models/ab_project.dart';
import '../models/agent_work_status.dart';
import '../models/project_catalog.dart';
import '../models/recent_session_row.dart';
import 'demo_mode.dart';
import 'machine_catalog.dart';
import 'machine_directory.dart';
import 'project_work_status.dart';
import 'projects.dart';
import 'recent_sessions.dart';

/// One copy of a project, on one machine.
@immutable
class ProjectMember {
  const ProjectMember({
    required this.machineId,
    required this.entryId,
    required this.projectId,
    required this.name,
    this.gitRemote,
  });

  /// [kLocalMachineKey] or the bare machine uuid.
  final String machineId;

  /// The drawer/cache key the rest of the app opens it by: the bare projectId
  /// for a local project, `<uuid>.<projectId>` for a remote one.
  final String entryId;
  final String projectId;
  final String name;
  final String? gitRemote;

  @override
  bool operator ==(Object other) =>
      other is ProjectMember &&
      other.machineId == machineId &&
      other.entryId == entryId &&
      other.projectId == projectId &&
      other.name == name &&
      other.gitRemote == gitRemote;

  @override
  int get hashCode => Object.hash(machineId, entryId, projectId, name, gitRemote);
}

/// One project as the project-first views show it: every machine's copy of
/// the same repository, merged.
@immutable
class ProjectGroup {
  const ProjectGroup({
    required this.key,
    required this.name,
    required this.members,
  });

  /// Stable across launches: `git:<remote>` for a project with a known origin,
  /// `name:<lowercased name>` otherwise.
  final String key;
  final String name;
  final List<ProjectMember> members;
}

/// The machine a Recent row lives on, as a machine-directory id.
String machineIdOf(RecentOrigin origin) =>
    origin.machineUuid ?? kLocalMachineKey;

/// Every copy of every project the app knows about, one member per
/// machine-project pair. Pure, so it unit-tests directly.
///
/// A machine with a [catalogs] entry is described by that alone: its bridge
/// listed exactly what it holds. A machine without one — never connected since
/// this build, the norm right after an upgrade — falls back to what the cache
/// has seen of it: advert [labels] and the projects behind cached sessions.
/// Members on a machine not in [machineIds] are dropped, so a machine removed
/// from the account takes its projects with it.
List<ProjectMember> collectProjectMembers({
  required List<AbProject> locals,
  required Map<String, List<CatalogProject>> catalogs,
  required Map<String, String> labels,
  required Iterable<RecentOrigin> sessionOrigins,
  required Set<String> machineIds,
}) {
  final members = <String, ProjectMember>{};
  void add(ProjectMember m) => members.putIfAbsent(m.entryId, () => m);

  if (machineIds.contains(kLocalMachineKey)) {
    final localRemotes = {
      for (final p in catalogs[kLocalMachineKey] ?? const <CatalogProject>[])
        if (p.gitRemoteProbed) p.projectId: p.gitRemote,
    };
    for (final p in locals) {
      add(
        ProjectMember(
          machineId: kLocalMachineKey,
          entryId: p.projectId,
          projectId: p.projectId,
          name: p.displayName,
          gitRemote: localRemotes[p.projectId],
        ),
      );
    }
  }

  for (final e in catalogs.entries) {
    final uuid = e.key;
    if (uuid == kLocalMachineKey || !machineIds.contains(uuid)) continue;
    for (final p in e.value) {
      final entryId = '$uuid.${p.projectId}';
      add(
        ProjectMember(
          machineId: uuid,
          entryId: entryId,
          projectId: p.projectId,
          name: _nonEmpty(p.label) ?? labels[entryId] ?? p.projectId,
          gitRemote: p.gitRemoteProbed ? p.gitRemote : null,
        ),
      );
    }
  }

  bool uncatalogued(String uuid) =>
      machineIds.contains(uuid) && !catalogs.containsKey(uuid);
  for (final e in labels.entries) {
    final dot = e.key.indexOf('.');
    if (dot <= 0) continue;
    final uuid = e.key.substring(0, dot);
    if (!uncatalogued(uuid)) continue;
    add(
      ProjectMember(
        machineId: uuid,
        entryId: e.key,
        projectId: e.key.substring(dot + 1),
        name: e.value,
      ),
    );
  }
  for (final o in sessionOrigins) {
    final uuid = o.machineUuid;
    if (uuid == null || !uncatalogued(uuid)) continue;
    add(
      ProjectMember(
        machineId: uuid,
        entryId: o.registrationId,
        projectId: o.projectId,
        name: o.projectName,
      ),
    );
  }
  return members.values.toList(growable: false);
}

String? _nonEmpty(String? s) => s == null || s.isEmpty ? null : s;

/// Merge members into one group per repository. Pure.
///
/// A known origin is the identity: two folders with the same remote are the
/// same project whatever they are called. Without one (no remote, a bridge
/// predating `gitRemote`, a project not probed yet) the lowercased name is all
/// there is — and a name that matches exactly ONE origin-keyed group joins it,
/// so a machine still on an older bridge does not split a project in two. A
/// name shared by two different origins stays on its own: guessing between
/// them would put sessions under the wrong repository.
List<ProjectGroup> groupProjects(List<ProjectMember> members) {
  final byKey = <String, List<ProjectMember>>{};
  final nameOfKey = <String, String>{};
  final gitKeysByName = <String, Set<String>>{};

  for (final m in members) {
    final remote = m.gitRemote;
    if (remote == null) continue;
    final key = 'git:$remote';
    (byKey[key] ??= []).add(m);
    nameOfKey.putIfAbsent(key, () => m.name);
    (gitKeysByName[m.name.toLowerCase()] ??= {}).add(key);
  }
  for (final m in members) {
    if (m.gitRemote != null) continue;
    final lower = m.name.toLowerCase();
    final candidates = gitKeysByName[lower];
    final key = candidates != null && candidates.length == 1
        ? candidates.single
        : 'name:$lower';
    (byKey[key] ??= []).add(m);
    nameOfKey.putIfAbsent(key, () => m.name);
  }
  return [
    for (final e in byKey.entries)
      ProjectGroup(
        key: e.key,
        name: nameOfKey[e.key]!,
        members: List.unmodifiable(e.value),
      ),
  ];
}

/// Where a session sits in the project panel's default grouping.
enum SessionBucket { needsYou, running, done }

/// `error` is a call to action like `attention`: nothing resolves it without
/// the user. `unread` is a finished turn nobody has looked at yet — done, with
/// its own dot.
SessionBucket sessionBucket(AgentWorkStatus status) => switch (status) {
  AgentWorkStatus.attention || AgentWorkStatus.error => SessionBucket.needsYou,
  AgentWorkStatus.working => SessionBucket.running,
  AgentWorkStatus.unread || AgentWorkStatus.done => SessionBucket.done,
};

/// One project under the current machine scope.
@immutable
class ProjectView {
  const ProjectView({
    required this.group,
    required this.members,
    required this.machines,
    required this.hiddenMachines,
    required this.sessions,
    required this.liveCount,
    required this.needsYouCount,
  });

  final ProjectGroup group;

  /// The copies on machines in scope.
  final List<ProjectMember> members;

  /// Those machines, in directory order.
  final List<MachineInfo> machines;

  /// Machines holding the project that the scope hides.
  final List<MachineInfo> hiddenMachines;

  /// Sessions on in-scope copies, most recent first.
  final List<RecentSessionRow> sessions;
  final int liveCount;
  final int needsYouCount;

  bool get inScope => members.isNotEmpty;

  /// Every in-scope machine holding it is offline — shown dimmed, never hidden.
  bool get allOffline => machines.isNotEmpty && machines.every((m) => !m.online);
}

/// Project views for every group, in-scope or not, most recently active first.
/// Pure. [statusOf] answers a session's effective status (see
/// `recentSessionStatusesProvider`).
List<ProjectView> buildProjectViews({
  required List<ProjectGroup> groups,
  required List<MachineInfo> machines,
  required Set<String> scopedMachineIds,
  required List<RecentSessionRow> sessions,
  required AgentWorkStatus Function(RecentSessionRow row) statusOf,
}) {
  final machineOrder = {
    for (var i = 0; i < machines.length; i++) machines[i].id: i,
  };
  final sessionsByEntry = <String, List<RecentSessionRow>>{};
  for (final r in sessions) {
    (sessionsByEntry[r.origin.registrationId] ??= []).add(r);
  }

  final views = <({ProjectView view, int lastUsed})>[];
  for (final g in groups) {
    final members = [
      for (final m in g.members)
        if (scopedMachineIds.contains(m.machineId)) m,
    ]..sort(
        (a, b) => (machineOrder[a.machineId] ?? 1 << 30).compareTo(
          machineOrder[b.machineId] ?? 1 << 30,
        ),
      );
    List<MachineInfo> machinesOf(Iterable<ProjectMember> ms) {
      final ids = <String>{for (final m in ms) m.machineId};
      return [
        for (final m in machines)
          if (ids.contains(m.id)) m,
      ];
    }

    final rows = [
      for (final m in members) ...?sessionsByEntry[m.entryId],
    ]..sort((a, b) => b.session.lastUsedAt.compareTo(a.session.lastUsedAt));
    var live = 0;
    var needs = 0;
    for (final r in rows) {
      switch (sessionBucket(statusOf(r))) {
        case SessionBucket.running:
          live++;
        case SessionBucket.needsYou:
          needs++;
        case SessionBucket.done:
          break;
      }
    }
    final scopedIds = {for (final m in members) m.machineId};
    views.add((
      view: ProjectView(
        group: g,
        members: List.unmodifiable(members),
        machines: List.unmodifiable(machinesOf(members)),
        hiddenMachines: List.unmodifiable(
          machinesOf(g.members.where((m) => !scopedIds.contains(m.machineId))),
        ),
        sessions: List.unmodifiable(rows),
        liveCount: live,
        needsYouCount: needs,
      ),
      lastUsed: rows.isEmpty ? 0 : rows.first.session.lastUsedAt,
    ));
  }
  views.sort((a, b) {
    final byRecency = b.lastUsed.compareTo(a.lastUsed);
    if (byRecency != 0) return byRecency;
    return a.view.group.name.toLowerCase().compareTo(
      b.view.group.name.toLowerCase(),
    );
  });
  return List.unmodifiable([for (final v in views) v.view]);
}

/// A session waiting on the user, as the Needs you list shows it.
@immutable
class NeedsYouItem {
  const NeedsYouItem({
    required this.row,
    required this.status,
    required this.machineName,
    required this.projectName,
  });

  final RecentSessionRow row;
  final AgentWorkStatus status;
  final String machineName;
  final String projectName;
}

/// Sessions in scope that need the user: questions and approvals
/// (`attention`) before failures (`error`), most recent first within each.
/// Pure.
List<NeedsYouItem> buildNeedsYou({
  required List<ProjectView> views,
  required Map<String, MachineInfo> machinesById,
  required AgentWorkStatus Function(RecentSessionRow row) statusOf,
}) {
  final items = <NeedsYouItem>[];
  for (final v in views) {
    for (final r in v.sessions) {
      final status = statusOf(r);
      if (sessionBucket(status) != SessionBucket.needsYou) continue;
      items.add(
        NeedsYouItem(
          row: r,
          status: status,
          machineName:
              machinesById[machineIdOf(r.origin)]?.name ?? r.origin.deviceName,
          projectName: v.group.name,
        ),
      );
    }
  }
  int rank(AgentWorkStatus s) => s == AgentWorkStatus.attention ? 0 : 1;
  items.sort((a, b) {
    final byKind = rank(a.status).compareTo(rank(b.status));
    if (byKind != 0) return byKind;
    return b.row.session.lastUsedAt.compareTo(a.row.session.lastUsedAt);
  });
  return List.unmodifiable(items);
}

/// The machine the composer pre-selects for [view]: the one its most recent
/// session ran on, if that machine is online, else the next most recent online
/// one, else the first online machine holding the project. Null when none is
/// online — the picker then asks rather than pointing at a dead machine.
String? defaultComposerMachine(ProjectView view) {
  final online = {for (final m in view.machines) if (m.online) m.id};
  for (final r in view.sessions) {
    final id = machineIdOf(r.origin);
    if (online.contains(id)) return id;
  }
  for (final m in view.machines) {
    if (m.online) return m.id;
  }
  return null;
}

final projectGroupsProvider = Provider<List<ProjectGroup>>((ref) {
  final demo = ref.watch(demoModeProvider);
  final machineIds = {for (final m in ref.watch(machineDirectoryProvider)) m.id};
  final sessions = ref.watch(recentSessionsProvider);
  return groupProjects(
    collectProjectMembers(
      locals: demo ? [demoProject()] : ref.watch(projectsProvider),
      catalogs: demo ? const {} : ref.watch(machineCatalogsProvider),
      labels: demo ? const {} : ref.watch(remoteProjectLabelsProvider),
      sessionOrigins: [for (final r in sessions) r.origin],
      machineIds: machineIds,
    ),
  );
});

AgentWorkStatus Function(RecentSessionRow) _statusLookup(
  Map<String, AgentWorkStatus> statuses,
) => (r) =>
    statuses[recentStatusKey(r.origin.registrationId, r.session.id)] ??
    AgentWorkStatus.done;

final projectViewsProvider = Provider<List<ProjectView>>((ref) {
  return buildProjectViews(
    groups: ref.watch(projectGroupsProvider),
    machines: ref.watch(machineDirectoryProvider),
    scopedMachineIds: ref.watch(scopedMachineIdsProvider),
    sessions: ref.watch(recentSessionsProvider),
    statusOf: _statusLookup(ref.watch(recentSessionStatusesProvider)),
  );
});

final needsYouProvider = Provider<List<NeedsYouItem>>((ref) {
  return buildNeedsYou(
    views: ref.watch(projectViewsProvider),
    machinesById: {for (final m in ref.watch(machineDirectoryProvider)) m.id: m},
    statusOf: _statusLookup(ref.watch(recentSessionStatusesProvider)),
  );
});
