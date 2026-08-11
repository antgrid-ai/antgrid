import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/drawer_entry.dart';
import 'package:antgrid/models/ab_project.dart';
import 'package:antgrid/services/account_agents_api.dart';
import 'package:antgrid/storage/recent_agents_store.dart';
import 'package:antgrid/providers/drawer_entries.dart';

void main() {
  group('mergeDrawerEntries', () {
    final t0 = DateTime(2026, 5, 1, 10, 0);
    final t1 = DateTime(2026, 5, 1, 11, 0);
    final t2 = DateTime(2026, 5, 1, 12, 0);

    final p1 = AbProject(
      projectId: 'p1',
      folder: '/a',
      displayName: 'a',
      hostDeviceUuid: 'p1',
      hostMachineName: '',
      lastOpenedAt: t0,
    );
    final p2 = AbProject(
      projectId: 'p2',
      folder: '/b',
      displayName: 'b',
      hostDeviceUuid: 'p2',
      hostMachineName: '',
      lastOpenedAt: t2,
    );
    final r1 = RecentAgent(
      agentDeviceId: 'r1.proj',
      agentLabel: 'dev-server',
      agentEd25519Pubkey: '',
      relayUrl: '',
      pairedAt: t0,
      lastConnectedAt: t1,
    );

    test('merges preserving source order (locals then remotes)', () {
      final entries = mergeDrawerEntries(locals: [p1, p2], remotes: [r1]);
      expect(entries.length, 3);
      expect(entries[0].id, 'p1');
      expect(entries[1].id, 'p2');
      expect(entries[2].id, 'r1.proj');
    });

    test('inventory agents appear after locals + remotes', () {
      final inv1 = InventoryAgent(
        deviceUuid: 'inv-uuid',
        displayName: 'Studio PC',
        platform: 'windows',
        ed25519Pub: 'AAAA',
        relayUrl: 'wss://relay/ws',
      );
      final entries = mergeDrawerEntries(
        locals: [p1],
        remotes: [r1],
        inventory: [inv1],
      );
      expect(entries.length, 3);
      expect(entries[2].id, 'inv-uuid');
      expect(entries[2], isA<InventoryAgentEntry>());
    });

    test('inventory agent deduped when hostDeviceUuid matches', () {
      final pLocal = AbProject(
        projectId: 'pLocal',
        folder: '/local',
        displayName: 'local',
        hostDeviceUuid: 'known-uuid',
        hostMachineName: 'My Mac',
        lastOpenedAt: t0,
      );
      final inv = InventoryAgent(
        deviceUuid: 'known-uuid', // same as pLocal.hostDeviceUuid
        displayName: 'My Mac',
        platform: 'macos',
        ed25519Pub: 'BBBB',
      );
      final entries = mergeDrawerEntries(
        locals: [pLocal],
        remotes: [],
        inventory: [inv],
      );
      // Only the local project — inv is deduped.
      expect(entries.length, 1);
      expect(entries[0], isA<LocalProjectEntry>());
    });

    test('inventory agent deduped when agentDeviceId matches recent', () {
      final rAgent = RecentAgent(
        agentDeviceId: 'paired-uuid',
        agentLabel: 'work-server',
        agentEd25519Pubkey: '',
        relayUrl: '',
        pairedAt: t0,
        lastConnectedAt: t1,
      );
      final inv = InventoryAgent(
        deviceUuid: 'paired-uuid', // same as rAgent.agentDeviceId
        displayName: 'Work Server',
        platform: 'linux',
        ed25519Pub: 'CCCC',
      );
      final entries = mergeDrawerEntries(
        locals: [],
        remotes: [rAgent],
        inventory: [inv],
      );
      // Only the recent agent — inv is deduped.
      expect(entries.length, 1);
      expect(entries[0], isA<RemoteAgentEntry>());
    });

    test('inventory agent deduped when recent agentDeviceId is compound '
        '<deviceUuid>.<projectId> (QR-paired)', () {
      // QR-paired agents persist the compound registrationId, per CLAUDE.md.
      // Inventory returns the bare deviceUuid. Without normalization the same
      // agent would appear twice in the drawer.
      final rAgent = RecentAgent(
        agentDeviceId: 'qr-uuid.some-project',
        agentLabel: 'qr-paired',
        agentEd25519Pubkey: '',
        relayUrl: '',
        pairedAt: t0,
        lastConnectedAt: t1,
      );
      final inv = InventoryAgent(
        deviceUuid: 'qr-uuid',
        displayName: 'qr-paired',
        platform: 'macos',
        ed25519Pub: 'DDDD',
      );
      final entries = mergeDrawerEntries(
        locals: [],
        remotes: [rAgent],
        inventory: [inv],
      );
      expect(entries.length, 1, reason: 'inventory should be deduped');
      expect(entries[0], isA<RemoteAgentEntry>());
    });

    test('inventory agent for this device is excluded with no local project', () {
      // The locally-spawned agent registers in the account inventory under this
      // device's own host uuid. With no local project open it would otherwise
      // render as a phantom REMOTE machine — localDeviceUuid suppresses it.
      final selfInv = InventoryAgent(
        deviceUuid: 'self-uuid',
        displayName: 'RadhaAI',
        platform: 'windows',
        ed25519Pub: 'EEEE',
      );
      final entries = mergeDrawerEntries(
        locals: [],
        remotes: [],
        inventory: [selfInv],
        localDeviceUuid: 'self-uuid',
      );
      expect(entries, isEmpty);
    });

    group('machine vs project entry discrimination', () {
      RecentAgent recent({
        required String agentDeviceId,
        String agentLabel = 'lbl',
        String? hostMachineName,
      }) => RecentAgent(
        agentDeviceId: agentDeviceId,
        agentLabel: agentLabel,
        agentEd25519Pubkey: '',
        relayUrl: '',
        pairedAt: t0,
        lastConnectedAt: t1,
        hostMachineName: hostMachineName,
      );

      test('same-account machine (bare uuid) → machineUuid set, name is the '
          'host machine name (not the uuid)', () {
        final e = RemoteAgentEntry(
          recent(agentDeviceId: 'bare-uuid-123', hostMachineName: 'Studio PC'),
        );
        expect(e.machineUuid, 'bare-uuid-123');
        expect(e.displayName, 'Studio PC');
      });

      test('machine name falls back to label, then to the uuid', () {
        final labelled = RemoteAgentEntry(
          recent(
            agentDeviceId: 'u1',
            agentLabel: 'work',
            hostMachineName: '  ',
          ),
        );
        expect(labelled.displayName, 'work');
        final bare = RemoteAgentEntry(
          recent(agentDeviceId: 'u2', agentLabel: '', hostMachineName: null),
        );
        expect(bare.displayName, 'u2');
      });

      test('QR-paired compound entry is a project, not a machine', () {
        final e = RemoteAgentEntry(recent(agentDeviceId: 'uuid.proj-hash'));
        expect(e.machineUuid, isNull);
        expect(e.displayName, 'proj-hash');
      });

      test('inventory entry is always a machine', () {
        final e = InventoryAgentEntry(
          InventoryAgent(
            deviceUuid: 'inv-uuid',
            displayName: 'Studio PC',
            platform: 'windows',
            ed25519Pub: 'AAAA',
          ),
        );
        expect(e.machineUuid, 'inv-uuid');
      });

      test('local project is never a machine', () {
        expect(LocalProjectEntry(p1).machineUuid, isNull);
      });
    });

    group('applyDrawerOrder', () {
      test('empty order returns entries unchanged', () {
        final entries = mergeDrawerEntries(locals: [p1, p2], remotes: [r1]);
        expect(applyDrawerOrder(entries, const []), entries);
      });

      test('orders ids first, appends unknowns in source order', () {
        final entries = mergeDrawerEntries(locals: [p1, p2], remotes: [r1]);
        // Promote remote, then p2 — p1 not in order, should append at end.
        final result = applyDrawerOrder(entries, ['r1.proj', 'p2']);
        expect(result.map((e) => e.id), ['r1.proj', 'p2', 'p1']);
      });

      test('skips stale ids not present in entries', () {
        final entries = mergeDrawerEntries(locals: [p1], remotes: [r1]);
        final result = applyDrawerOrder(entries, ['ghost', 'r1.proj', 'p1']);
        expect(result.map((e) => e.id), ['r1.proj', 'p1']);
      });
    });
  });
}
