import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../demo/demo_identity.dart';
import '../models/drawer_entry.dart';
import '../util/device_id.dart';
import '../models/ab_project.dart';
import '../services/account_agents_api.dart';
import '../storage/recent_agents_store.dart';
import 'account_agents.dart';
import 'demo_mode.dart';
import 'device_provisioning.dart';
import 'drawer_order.dart';
import 'projects.dart';
import 'recent_agents.dart';

/// Pure helper — merges source lists into a single drawer-entry list,
/// preserving the source order of each list (locals first, then remotes, then
/// inventory-only agents not already represented in the first two groups).
///
/// [inventory] agents whose [InventoryAgent.deviceUuid] already appears in a
/// local project's [AbProject.hostDeviceUuid] or in a remote agent's
/// [RecentAgent.agentDeviceId] are silently deduplicated.
///
/// [localDeviceUuid] is THIS device's own host identity. The locally-spawned
/// agent registers in the account inventory under that same uuid, so it comes
/// back from `/account/agents` as an inventory row describing this very machine.
/// Excluding it keeps the device from listing itself as a phantom REMOTE machine
/// when no local project happens to be open (the dedup above relies on an open
/// local project to cover it, which isn't guaranteed).
///
/// Note on id formats: QR-paired agents persist [RecentAgent.agentDeviceId] as
/// the agent's full registrationId — `<deviceUuid>.<projectId>` — because the
/// QR `d=` param carries the compound registrationId. Inventory rows from the
/// web report only the bare `deviceUuid`. We normalize the recent-id
/// to its `<deviceUuid>` prefix before deduping so QR-paired agents don't
/// render twice once their inventory entry loads.
List<DrawerEntry> mergeDrawerEntries({
  required List<AbProject> locals,
  required List<RecentAgent> remotes,
  List<InventoryAgent> inventory = const [],
  String? localDeviceUuid,
}) {
  final coveredUuids = <String>{
    ?localDeviceUuid,
    for (final p in locals)
      if (p.hostDeviceUuid != null) p.hostDeviceUuid!,
    for (final r in remotes) baseDeviceUuid(r.agentDeviceId),
  };
  return <DrawerEntry>[
    ...locals.map(LocalProjectEntry.new),
    ...remotes.map(RemoteAgentEntry.new),
    for (final a in inventory)
      if (!coveredUuids.contains(a.deviceUuid)) InventoryAgentEntry(a),
  ];
}

/// Applies a user-defined ordering to [entries]. Ids from [order] that match
/// an entry come first (in order); any entries whose id isn't in [order] are
/// appended in their original source order. Stale ids (in [order] but not in
/// [entries]) are silently skipped.
List<DrawerEntry> applyDrawerOrder(
  List<DrawerEntry> entries,
  List<String> order,
) {
  if (order.isEmpty) return entries;
  final byId = {for (final e in entries) e.id: e};
  final result = <DrawerEntry>[];
  final used = <String>{};
  for (final id in order) {
    final e = byId[id];
    if (e != null) {
      result.add(e);
      used.add(id);
    }
  }
  for (final e in entries) {
    if (!used.contains(e.id)) result.add(e);
  }
  return List.unmodifiable(result);
}

/// Merged + user-ordered drawer list. Re-derives whenever projects, recent
/// agents, inventory, or the persisted order change.
///
/// When [accountAgentsProvider] is loading or has errored the inventory source
/// is treated as empty so the drawer still renders immediately with local +
/// recent data.
final drawerEntriesProvider = Provider<List<DrawerEntry>>((ref) {
  // The sample project is the whole drawer while the demo is on, and none of
  // the real sources below are watched: `accountAgentsProvider` reads the
  // session cookie out of the keychain and fetches /account/agents, and every
  // remote row it would produce dials that machine's relay socket. Returning
  // early is also what keeps the header from reading "PROJECTS · 0 / No
  // projects yet" over a workspace that is plainly showing one.
  if (ref.watch(demoModeProvider)) return demoDrawerEntries();

  final locals = ref.watch(projectsProvider);
  final remotes = ref.watch(recentAgentsProvider);
  final inventory = ref.watch(accountAgentsProvider).value ?? const [];
  final localUuid = ref.watch(localDeviceUuidProvider).value;
  final order = ref.watch(drawerOrderProvider);
  return applyDrawerOrder(
    mergeDrawerEntries(
      locals: locals,
      remotes: remotes,
      inventory: inventory,
      localDeviceUuid: localUuid,
    ),
    order,
  );
});

/// The drawer's contents while the demo is on: the sample project and nothing
/// else.
///
/// A [LocalProjectEntry] over an in-memory [AbProject] rather than a fourth
/// [DrawerEntry] subclass — the demo's whole premise is that the real UI
/// renders it, and a local entry is exactly what it is: `machineUuid` null, so
/// the row expands into its own sessions instead of a machine's project advert
/// (which would open a control-plane socket).
List<DrawerEntry> demoDrawerEntries() =>
    List.unmodifiable([LocalProjectEntry(demoProject())]);
