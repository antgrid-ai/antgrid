import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/drawer_entry.dart';
import '../models/project_catalog.dart';
import '../services/account_agents_api.dart';
import '../utils/platform_utils.dart';
import 'account_agents.dart';
import 'demo_mode.dart';
import 'device_provisioning.dart';
import 'drawer_entries.dart';
import 'machine_scope.dart';
import 'mobile_connection.dart';
import 'projects.dart';
import 'recent_sessions.dart';

/// How long after a bridge's last account heartbeat it still reads as online.
/// The bridge heartbeats every 60s (`pushHeartbeat`, host-server.ts), so three
/// missed beats is the margin; a machine with an open, connected socket is
/// online regardless.
const Duration kPresenceFreshWindow = Duration(minutes: 3);

/// One machine of the account, as the project-first views name it.
@immutable
class MachineInfo {
  const MachineInfo({
    required this.id,
    required this.name,
    required this.isLocal,
    required this.online,
    this.lastSeenAt,
    this.remoteAccessEnabled,
    this.platform,
  });

  /// [kLocalMachineKey] for this device, the bare device uuid otherwise.
  final String id;
  final String name;
  final bool isLocal;
  final bool online;
  final DateTime? lastSeenAt;

  /// The machine's own remote-access switch, as its last advert stated it.
  /// Null when nothing has said: no advert this launch, or an older bridge.
  /// Never read null as off.
  final bool? remoteAccessEnabled;

  /// The account inventory's platform tag (`macos`, `windows`, `linux`); null
  /// for a machine the inventory does not list.
  final String? platform;

  @override
  bool operator ==(Object other) =>
      other is MachineInfo &&
      other.id == id &&
      other.name == name &&
      other.isLocal == isLocal &&
      other.online == online &&
      other.lastSeenAt == lastSeenAt &&
      other.remoteAccessEnabled == remoteAccessEnabled &&
      other.platform == platform;

  @override
  int get hashCode => Object.hash(
    id,
    name,
    isLocal,
    online,
    lastSeenAt,
    remoteAccessEnabled,
    platform,
  );
}

/// Online when a socket to the machine is connected, else when its last
/// account heartbeat is recent.
bool machineOnline({
  required bool connected,
  required DateTime? lastHeartbeatAt,
  required DateTime now,
}) {
  if (connected) return true;
  if (lastHeartbeatAt == null) return false;
  return now.difference(lastHeartbeatAt) <= kPresenceFreshWindow;
}

/// Every machine on the account: this device first (when it runs a bridge),
/// then the remote machines in drawer order. Pure, so it unit-tests directly.
///
/// [entries] is the drawer's list, which already de-duplicates a machine known
/// both from this device's own connections and from the account inventory.
List<MachineInfo> buildMachineDirectory({
  required List<DrawerEntry> entries,
  required List<InventoryAgent> inventory,
  required bool includeLocal,
  required String localName,
  required bool localOnline,
  required Map<String, bool> connected,
  required Map<String, bool?> remoteAccess,
  required DateTime now,
}) {
  final inventoryById = {for (final a in inventory) a.deviceUuid: a};
  final machines = <MachineInfo>[
    if (includeLocal)
      MachineInfo(
        id: kLocalMachineKey,
        name: localName,
        isLocal: true,
        online: localOnline,
        lastSeenAt: localOnline ? now : null,
      ),
  ];
  final seen = <String>{};
  for (final entry in entries) {
    final uuid = entry.machineUuid;
    if (uuid == null || !seen.add(uuid)) continue;
    final heartbeat = inventoryById[uuid]?.lastSeenAt;
    // Our own last connection says when this device last reached it, which
    // is worth showing as "seen" but is no evidence it is up now.
    final lastSeen =
        heartbeat ??
        (entry is RemoteAgentEntry ? entry.agent.lastConnectedAt : null);
    machines.add(
      MachineInfo(
        id: uuid,
        name: entry.displayName,
        isLocal: false,
        online: machineOnline(
          connected: connected[uuid] ?? false,
          lastHeartbeatAt: heartbeat,
          now: now,
        ),
        lastSeenAt: lastSeen,
        remoteAccessEnabled: remoteAccess[uuid],
        platform: inventoryById[uuid]?.platform,
      ),
    );
  }
  return List.unmodifiable(machines);
}

/// Whether each machine with an OPEN control-plane socket is connected right
/// now, keyed by bare uuid; absent when no socket is open. Written by the
/// app_shell control-plane reaper, the single writer every live per-machine
/// map here has, for the reason given on `remoteProjectLabelsProvider`.
final machineLiveConnectionProvider =
    NotifierProvider<MachineLiveConnectionController, Map<String, bool>>(
      MachineLiveConnectionController.new,
    );

class MachineLiveConnectionController extends Notifier<Map<String, bool>> {
  @override
  Map<String, bool> build() => const {};

  void set(String machineUuid, bool connected) {
    if (state[machineUuid] == connected) return;
    state = {...state, machineUuid: connected};
  }

  void clear(String machineUuid) {
    if (!state.containsKey(machineUuid)) return;
    state = {...state}..remove(machineUuid);
  }
}

final machineDirectoryProvider = Provider<List<MachineInfo>>((ref) {
  final demo = ref.watch(demoModeProvider);
  final entries = ref.watch(drawerEntriesProvider);
  // Demo: one local machine, and none of the real account sources — the
  // inventory read is a keychain cookie and a network fetch.
  if (demo) {
    return buildMachineDirectory(
      entries: const [],
      inventory: const [],
      includeLocal: true,
      localName: 'This machine',
      localOnline: true,
      connected: const {},
      remoteAccess: const {},
      now: DateTime.now(),
    );
  }
  final inventory = ref.watch(accountAgentsProvider).value ?? const [];
  final localUuid = ref.watch(localDeviceUuidProvider).value;
  final localName =
      inventory
          .firstWhereOrNull((a) => a.deviceUuid == localUuid)
          ?.displayName ??
      'This machine';
  final adverts = ref.watch(machineAdvertisedProjectsProvider);
  return buildMachineDirectory(
    entries: entries,
    inventory: inventory,
    // A phone runs no bridge of its own, but a local project, wherever it
    // came from, still needs a machine to belong to.
    includeLocal:
        !isMobilePlatform ||
        ref.watch(projectsProvider.select((p) => p.isNotEmpty)),
    localName: localName,
    // Not the host's phase: the app spawns its own bridge on demand, so this
    // machine is reachable whenever the app is running. Keying it to `up`
    // would drop every local project out of the default scope at launch and
    // during any host restart.
    localOnline: true,
    connected: ref.watch(machineLiveConnectionProvider),
    remoteAccess: {
      for (final e in adverts.entries) e.key: e.value.remoteAccessEnabled,
    },
    // Not a ticking clock: presence moves with the heartbeat, and the
    // inventory that carries it is re-read on that cadence (AppShell).
    now: DateTime.now(),
  );
});

/// Ids of the machines the current [MachineScope] shows.
final scopedMachineIdsProvider = Provider<Set<String>>((ref) {
  // A phone shows the one machine it is connected to; the scope is the
  // desktop's.
  if (ref.watch(mobileConnectEnabledProvider)) {
    final id = ref.watch(mobileConnectionProvider.select((c) => c.machineId));
    return id == null ? const {} : {id};
  }
  final scope = ref.watch(machineScopeProvider);
  return {
    for (final m in scopeCandidates(ref.watch(machineDirectoryProvider)))
      if (scope.includes(m.id, online: m.online)) m.id,
  };
});

/// The machines a scope can include on this device. A phone cannot drive a
/// machine whose remote-access switch is off — its advert is empty and every
/// verb is refused — so there such a machine is shown locked, never in scope.
List<MachineInfo> scopeCandidates(List<MachineInfo> machines, {bool? mobile}) {
  if (!(mobile ?? isMobilePlatform)) return machines;
  return [
    for (final m in machines)
      if (m.remoteAccessEnabled != false) m,
  ];
}

/// What the scope button says, e.g. "All online machines" / "MacBook Pro" /
/// "3 of 5 machines".
String machineScopeLabel(List<MachineInfo> machines, MachineScope scope) {
  final inScope = [
    for (final m in machines)
      if (scope.includes(m.id, online: m.online)) m,
  ];
  if (inScope.isEmpty) return 'No machines';
  if (inScope.length == machines.length) return 'All machines';
  final online = [
    for (final m in machines)
      if (m.online) m,
  ];
  final onlyOnline =
      inScope.length == online.length && inScope.every((m) => m.online);
  if (onlyOnline) return 'All online machines';
  if (inScope.length == 1) return inScope.single.name;
  return '${inScope.length} of ${machines.length} machines';
}

/// The inventory's platform tag as people write it, e.g. "macOS".
String? platformLabel(String? platform) => switch (platform?.toLowerCase()) {
  'macos' || 'darwin' => 'macOS',
  'windows' || 'win32' => 'Windows',
  'linux' => 'Linux',
  _ => null,
};
