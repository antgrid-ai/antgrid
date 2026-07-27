import 'package:antgrid/models/drawer_entry.dart';
import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/control_plane.dart';
import 'package:antgrid/providers/drawer_entries.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/recent_agents.dart';
import 'package:antgrid/services/account_agents_api.dart';
import 'package:antgrid/services/control_plane_client.dart';
import 'package:antgrid/services/storage_service.dart';
import 'package:antgrid/storage/recent_agents_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid/widgets/drawer_entry_row.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';
import '../helpers/test_store_overrides.dart';

const _remoteEntryId = 'remote-device.project';
const _inventoryEntryId = 'inventory-device';

RecentAgent _recentAgent() {
  final now = DateTime(2026, 1, 1);
  return RecentAgent(
    agentDeviceId: _remoteEntryId,
    agentLabel: 'Remote Agent',
    agentEd25519Pubkey: '',
    relayUrl: 'wss://relay.example.test/ws',
    pairedAt: now,
    lastConnectedAt: now,
  );
}

InventoryAgent _inventoryAgent() => InventoryAgent(
  deviceUuid: _inventoryEntryId,
  displayName: 'Inventory Agent',
  platform: 'windows',
  ed25519Pub: '',
  relayUrl: 'wss://relay.example.test/ws',
);

class _EmptyPairedAgentNotifier extends PairedAgentNotifier {
  @override
  Future<List<PairedAgent>> build() async => const [];
}

class _MemoryStorageService extends StorageService {
  _MemoryStorageService(this.agents);

  List<PairedAgent> agents;

  @override
  Future<List<PairedAgent>> loadPairedAgents() async => List.of(agents);

  @override
  Future<void> savePairedAgents(List<PairedAgent> agents) async {
    this.agents = List.of(agents);
  }
}

class _SeededRecentAgentsNotifier extends RecentAgentsNotifier {
  _SeededRecentAgentsNotifier(this._seed);
  final List<RecentAgent> _seed;
  @override
  List<RecentAgent> build() {
    super.build(); // wire the store-change subscription
    return _seed;
  }
}

Future<void> _pumpActivationHarness(
  WidgetTester tester, {
  required TestStoreOverrides stores,
  required DrawerEntry entry,
  required SessionTarget? priorTarget,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...stores.overrides,
        drawerEntriesProvider.overrideWithValue([entry]),
        pairedAgentProvider.overrideWith(() => _EmptyPairedAgentNotifier()),
        // Activation now brings the machine up by reading its transport (the
        // supervisor owns the dial). A machine that cannot be reached surfaces
        // as this provider rejecting, which is what the restore-prior-target
        // behaviour under test hangs off.
        agentTransportForProvider.overrideWith(
          (ref, id) async => throw StateError('forced connect failure for $id'),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) {
              return TextButton(
                key: const Key('activate'),
                onPressed: () {
                  ref.read(selectedTargetProvider.notifier).set(priorTarget);
                  activateDrawerEntryById(context, ref, entry.id);
                },
                child: const Text('activate'),
              );
            },
          ),
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> expectFailedRemoteActivationRestores(
    WidgetTester tester, {
    required DrawerEntry entry,
    required SessionTarget? priorTarget,
  }) async {
    useInMemoryPrefs();
    final stores = await buildTestStoreOverrides();
    addTearDown(stores.close);

    await _pumpActivationHarness(
      tester,
      stores: stores,
      entry: entry,
      priorTarget: priorTarget,
    );

    await tester.tap(find.byKey(const Key('activate')));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byKey(const Key('activate'))),
    );
    expect(container.read(selectedTargetProvider), priorTarget);
  }

  group('activateDrawerEntryById failed remote activation', () {
    testWidgets('restores exact prior LocalProject', (tester) async {
      await expectFailedRemoteActivationRestores(
        tester,
        entry: RemoteAgentEntry(_recentAgent()),
        priorTarget: const LocalProject('local-project'),
      );
    });

    testWidgets('restores exact prior RemoteTarget.legacy', (tester) async {
      await expectFailedRemoteActivationRestores(
        tester,
        entry: RemoteAgentEntry(_recentAgent()),
        priorTarget: const RemoteTarget.legacy('prior-remote.project'),
      );
    });

    testWidgets('restores null prior target', (tester) async {
      await expectFailedRemoteActivationRestores(
        tester,
        entry: RemoteAgentEntry(_recentAgent()),
        priorTarget: null,
      );
    });

    testWidgets('inventory failure restores exact prior typed target', (
      tester,
    ) async {
      await expectFailedRemoteActivationRestores(
        tester,
        entry: InventoryAgentEntry(_inventoryAgent()),
        priorTarget: const RemoteTarget.legacy('prior-inventory.project'),
      );
    });
  });

  testWidgets(
    'cold remote session-row activation brings the machine up + focuses the '
    'project',
    (tester) async {
      // Regression: tapping a session row under an advertised-but-not-warm remote
      // project used to silently no-op (the entry==null branch only refocused
      // already-open projects). It must now bring the machine up and set the
      // typed RemoteProject target so the project actually opens.
      useInMemoryPrefs();
      final stores = await buildTestStoreOverrides();
      addTearDown(stores.close);

      const machineUuid = 'M';
      // A recent carrying a compound id whose bare machine prefix is 'M' — the
      // open path resolves the machine, not the compound target.
      final recent = RecentAgent(
        agentDeviceId: '$machineUuid.someproj',
        agentLabel: 'Remote Agent',
        agentEd25519Pubkey: '',
        relayUrl: 'wss://relay.example.test/ws',
        pairedAt: DateTime(2026, 1, 1),
        lastConnectedAt: DateTime(2026, 1, 1),
      );
      // Activation ALWAYS promotes via project:start (warm ≠ relay-promoted), so
      // the cold path needs a control-plane client. It records the project:start
      // and is seeded running:true below so awaitProjectRunning resolves.
      final cpTransport = FakeAgentTransport();
      addTearDown(cpTransport.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...stores.overrides,
            // 'M.p1' is NOT a drawer entry — forces the entry==null cold path.
            drawerEntriesProvider.overrideWithValue(const []),
            recentAgentsProvider.overrideWith(
              () => _SeededRecentAgentsNotifier([recent]),
            ),
            // Keyed by the MACHINE uuid, never the compound target id: a
            // compound-keyed resolution would build the REAL provider (and a
            // real relay transport with it) and fail.
            controlPlaneClientForProvider(machineUuid).overrideWith((
              ref,
            ) async {
              final c = ControlPlaneClient(transport: cpTransport);
              ref.onDispose(c.dispose);
              return c;
            }),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) {
                  return TextButton(
                    key: const Key('go'),
                    onPressed: () =>
                        activateDrawerEntryById(context, ref, 'M.p1'),
                    child: const Text('go'),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('go'))),
      );
      // Seed running:true so the activation's awaitProjectRunning resolves
      // immediately; it must STILL send project:start first.
      await container.read(controlPlaneClientForProvider(machineUuid).future);
      cpTransport.emit('agent:projects', {
        'projects': [
          {'projectId': 'p1', 'running': true},
        ],
      });
      await tester.pump();

      await tester.tap(find.byKey(const Key('go')));
      await tester.pumpAndSettle();

      expect(
        container.read(selectedTargetProvider),
        const RemoteProject(machineUuid: machineUuid, projectId: 'p1'),
      );
      // Always promotes: project:start was sent despite running:true.
      expect(
        cpTransport.sent.where((m) => m['type'] == 'project:start'),
        isNotEmpty,
      );
    },
  );

  testWidgets('forget remote row removes local machine trust', (tester) async {
    useInMemoryPrefs();
    final stores = await buildTestStoreOverrides();
    addTearDown(stores.close);
    final recent = _recentAgent();
    await stores.recentAgentsStore.upsert(recent);
    final storage = _MemoryStorageService([
      PairedAgent(
        relayUrl: recent.relayUrl,
        agentDeviceId: recent.agentDeviceId,
        agentName: recent.agentLabel,
      ),
    ]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...stores.overrides,
          storageServiceProvider.overrideWithValue(storage),
        ],
        child: MaterialApp(
          home: Scaffold(body: DrawerEntryRow(RemoteAgentEntry(recent))),
        ),
      ),
    );
    await tester.pump();
    await tester.ensureVisible(find.byType(DrawerEntryRow));
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.addPointer(
      location: tester.getCenter(find.byType(DrawerEntryRow)),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('Forget agent'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Forget'));
    await tester.pump();
    // forgetMachine does real-event-loop work (awaited registry evict +
    // purgeEntryState's ProjectStatusCache file I/O) that the fake-async clock
    // won't advance — so the trust-removal that follows it never lands and the
    // row's busy spinner never resets. Drain the real loop once, then settle.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();

    expect(storage.agents, isEmpty);
    expect(stores.recentAgentsStore.list(), isEmpty);
  });
}
