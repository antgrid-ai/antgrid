import 'package:antgrid/providers/machine_scope.dart';
import 'package:antgrid/providers/scope_control_planes.dart';
import 'package:antgrid/services/account_agents_api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 10, 30, 12);

  InventoryAgent agent(String uuid, {Duration? seenAgo}) => InventoryAgent(
    deviceUuid: uuid,
    displayName: uuid,
    platform: 'linux',
    ed25519Pub: 'pk',
    lastSeenAt: seenAgo == null ? null : now.subtract(seenAgo),
  );

  Set<String> targets(
    List<InventoryAgent> inventory, {
    MachineScope scope = const MachineScope(),
    int cap = kScopeControlPlaneCap,
  }) => scopeControlPlaneTargets(
    inventory: inventory,
    scope: scope,
    localDeviceUuid: 'self',
    now: now,
    cap: cap,
  );

  test('dials only machines whose heartbeat says they are up', () {
    expect(
      targets([
        agent('fresh', seenAgo: const Duration(minutes: 1)),
        agent('stale', seenAgo: const Duration(hours: 2)),
        agent('never'),
      ]),
      {'fresh'},
    );
  });

  test('never dials this device, and respects an unchecked machine', () {
    expect(
      targets(
        [
          agent('self', seenAgo: const Duration(seconds: 5)),
          agent('a', seenAgo: const Duration(seconds: 5)),
          agent('b', seenAgo: const Duration(seconds: 5)),
        ],
        scope: const MachineScope().toggled('b', online: true),
      ),
      {'a'},
    );
  });

  test('caps the set at the most recently seen', () {
    expect(
      targets([
        agent('old', seenAgo: const Duration(minutes: 2)),
        agent('new', seenAgo: const Duration(seconds: 10)),
        agent('mid', seenAgo: const Duration(minutes: 1)),
      ], cap: 2),
      {'new', 'mid'},
    );
  });
}
