import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../launcher/host_control_client.dart' show ProjectSummary;
import '../models/project_catalog.dart';
import '../services/control_plane_client.dart';
import 'cached_sessions.dart';

/// Each machine's last-advertised projects, keyed by bare uuid
/// ([kLocalMachineKey] for this device), seeded from the persisted cache so a
/// machine that is offline or not dialed this launch still has its projects.
///
/// Written imperatively by the app_shell control-plane reaper — the
/// single-writer pattern of `remoteProjectLabelsProvider`, for the same reason.
final machineCatalogsProvider =
    NotifierProvider<MachineCatalogsController, Map<String, List<CatalogProject>>>(
      MachineCatalogsController.new,
    );

class MachineCatalogsController
    extends Notifier<Map<String, List<CatalogProject>>> {
  @override
  Map<String, List<CatalogProject>> build() {
    // Guarded like the status seed: a test that never builds the cache must
    // not have this throw out of build().
    try {
      return {...ref.read(cachedSessionsStoreProvider).catalogs()};
    } catch (_) {
      return const {};
    }
  }

  void setMachine(String machineKey, List<CatalogProject> projects) {
    final prev = state[machineKey];
    if (prev != null &&
        const ListEquality<CatalogProject>().equals(prev, projects)) {
      return;
    }
    state = {...state, machineKey: List.unmodifiable(projects)};
    try {
      ref.read(cachedSessionsStoreProvider).putCatalog(machineKey, projects);
    } catch (_) {
      // No store in this container: the in-memory map is the whole answer.
    }
  }
}

/// The catalog a remote machine's advert implies, or null when the advert says
/// nothing about it and the stored one must stand.
///
/// Remote access off advertises an empty list, which is a statement about
/// reachability, not about which projects the machine holds — wiping the
/// catalog then would drop every one of its projects from the merged views
/// until it is switched back on. Null + empty is the same non-answer from a
/// bridge that predates the flag, or a socket whose first advert has not come.
List<CatalogProject>? catalogFromAdvert(ControlPlaneState state) {
  if (state.remoteAccessEnabled == false) return null;
  if (state.remoteAccessEnabled == null && state.projects.isEmpty) return null;
  return [
    for (final p in state.projects)
      CatalogProject(
        projectId: p.projectId,
        label: p.label,
        gitRemote: p.gitRemote,
        gitRemoteProbed: p.gitRemoteProbed,
      ),
  ];
}

/// The local catalog after a `project:list` poll. That poll lists WARM cores
/// only, so a project absent from it keeps its stored entry; one present
/// updates only once its remote has been probed.
List<CatalogProject> mergeLocalCatalog(
  List<CatalogProject> previous,
  Iterable<ProjectSummary> polled,
) {
  final byId = {for (final p in previous) p.projectId: p};
  for (final s in polled) {
    if (!s.gitRemoteProbed) continue;
    byId[s.projectId] = CatalogProject(
      projectId: s.projectId,
      label: byId[s.projectId]?.label,
      gitRemote: s.gitRemote,
      gitRemoteProbed: true,
    );
  }
  return byId.values.toList(growable: false);
}
