import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/providers/account_agents.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/control_plane.dart';
import 'package:antgrid/providers/eager_control_planes.dart';
import 'package:antgrid/providers/new_session_picker.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/relay_connection.dart';
import 'package:antgrid/providers/ui_attention_providers.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/services/account_agents_api.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid/widgets/new_session/picker_sources.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';

import '../helpers/prefs_test_mock.dart';
import '../helpers/test_store_overrides.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ProjectSessionRegistry.machinesWithOpenProjects', () {
    test('returns the distinct base uuids of open compound ids', () {
      final registry = ProjectSessionRegistry(
        localCap: 10,
        relayCap: 30,
        onEvict: (_) async {},
      );

      expect(registry.machinesWithOpenProjects(), isEmpty);

      registry
        ..touch('M.a', isLocal: false)
        ..touch('M.b', isLocal: false) // same machine → collapses to one entry
        ..touch('K.c', isLocal: false)
        ..touch('local1', isLocal: true); // bare/local id excluded

      expect(registry.machinesWithOpenProjects(), unorderedEquals(['M', 'K']));

      registry.remove('K.c');
      expect(registry.machinesWithOpenProjects(), unorderedEquals(['M']));
    });
  });

  group('controlPlaneAliveTargetsProvider', () {
    ProviderContainer makeContainer(
      ProjectSessionRegistry registry, {
      String selectedSourceId = 'local',
    }) {
      final source = switch (selectedSourceId) {
        'local' => const PickerSource(
          id: 'local',
          label: 'Local',
          isLocal: true,
          projects: <PickerProject>[],
        ),
        'machine:none' => const PickerSource(
          id: 'machine:none',
          label: 'Remote',
          isLocal: false,
          projects: <PickerProject>[],
          machineUuid: null,
        ),
        _ => PickerSource(
          id: selectedSourceId,
          label: 'Machine',
          isLocal: false,
          projects: const <PickerProject>[],
          machineUuid: machineUuidFromSourceId(selectedSourceId),
        ),
      };
      return ProviderContainer(
        overrides: [
          projectSessionRegistryProvider.overrideWith(
            () => ProjectSessionRegistryController(registry),
          ),
          pickerSourcesProvider.overrideWithValue([source]),
          selectedSourceIdProvider.overrideWith(
            () => ValueController(selectedSourceId),
          ),
          // flutter_test runs as Android → the eager union would read the
          // recents store, which this harness deliberately doesn't provide.
          eagerControlPlanesEnabledProvider.overrideWithValue(false),
        ],
      );
    }

    test('empty with no open project and a local viewed source', () {
      final registry = ProjectSessionRegistry(
        localCap: 10,
        relayCap: 30,
        onEvict: (_) async {},
      );
      final c = makeContainer(registry);
      addTearDown(c.dispose);

      expect(c.read(controlPlaneAliveTargetsProvider), isEmpty);
    });

    test('open remote project adds its machine; local id is ignored', () {
      final registry = ProjectSessionRegistry(
        localCap: 10,
        relayCap: 30,
        onEvict: (_) async {},
      );
      final c = makeContainer(registry);
      addTearDown(c.dispose);

      c.read(projectSessionRegistryProvider.notifier)
        ..touch('M.a', isLocal: false)
        ..touch('local1', isLocal: true);

      final alive = c.read(controlPlaneAliveTargetsProvider);
      expect(alive, contains('M'));
      // A no-dot local id must never surface as a control-plane target.
      expect(alive, isNot(contains('local1')));
    });

    test(
      'focused remote pins its machine before the session registry opens',
      () {
        final registry = ProjectSessionRegistry(
          localCap: 10,
          relayCap: 30,
          onEvict: (_) async {},
        );
        final c = ProviderContainer(
          overrides: [
            projectSessionRegistryProvider.overrideWith(
              () => ProjectSessionRegistryController(registry),
            ),
            pickerSourcesProvider.overrideWithValue(const [
              PickerSource(
                id: 'local',
                label: 'Local',
                isLocal: true,
                projects: <PickerProject>[],
              ),
            ]),
            selectedTargetProvider.overrideWith(
              () => ValueController(
                const RemoteProject(machineUuid: 'M', projectId: 'p1'),
              ),
            ),
            workbenchSurfaceProvider.overrideWith(
              () => ValueController(WorkbenchSurface.workspace),
            ),
            eagerControlPlanesEnabledProvider.overrideWithValue(false),
          ],
        );
        addTearDown(c.dispose);

        expect(registry.openProjects, isEmpty);
        expect(c.read(controlPlaneAliveTargetsProvider), contains('M'));

        c
            .read(selectedTargetProvider.notifier)
            .set(const RemoteTarget.legacy('K'));
        expect(c.read(controlPlaneAliveTargetsProvider), contains('K'));
      },
    );

    test('viewed machine source keeps it alive with no open project', () {
      final registry = ProjectSessionRegistry(
        localCap: 10,
        relayCap: 30,
        onEvict: (_) async {},
      );
      final c = makeContainer(registry, selectedSourceId: 'machine:M');
      addTearDown(c.dispose);

      expect(c.read(controlPlaneAliveTargetsProvider), contains('M'));
    });

    test('machine:none placeholder never becomes a target', () {
      final registry = ProjectSessionRegistry(
        localCap: 10,
        relayCap: 30,
        onEvict: (_) async {},
      );
      final c = makeContainer(registry, selectedSourceId: 'machine:none');
      addTearDown(c.dispose);

      expect(c.read(controlPlaneAliveTargetsProvider), isNot(contains('none')));
    });

    test('visible fallback machine stays alive when selected id is stale', () {
      final registry = ProjectSessionRegistry(
        localCap: 10,
        relayCap: 30,
        onEvict: (_) async {},
      );
      final c = ProviderContainer(
        overrides: [
          projectSessionRegistryProvider.overrideWith(
            () => ProjectSessionRegistryController(registry),
          ),
          pickerSourcesProvider.overrideWithValue(const [
            PickerSource(
              id: 'machine:M',
              label: 'Machine',
              isLocal: false,
              projects: <PickerProject>[],
              machineUuid: 'M',
            ),
          ]),
          selectedSourceIdProvider.overrideWith(() => ValueController('local')),
          eagerControlPlanesEnabledProvider.overrideWithValue(false),
        ],
      );
      addTearDown(c.dispose);

      expect(c.read(controlPlaneAliveTargetsProvider), contains('M'));
    });

    test(
      'picker fallback machine is NOT kept alive once a project is open',
      () {
        // Regression: mobile has no Local source, so the default 'local'
        // selection resolves visiblePickerSource to the first MACHINE. Before
        // gating on picker visibility, that pinned the machine's socket open
        // forever — even on the workspace, with the picker not shown.
        final registry = ProjectSessionRegistry(
          localCap: 10,
          relayCap: 30,
          onEvict: (_) async {},
        );
        final c = ProviderContainer(
          overrides: [
            projectSessionRegistryProvider.overrideWith(
              () => ProjectSessionRegistryController(registry),
            ),
            pickerSourcesProvider.overrideWithValue(const [
              PickerSource(
                id: 'machine:M',
                label: 'Machine',
                isLocal: false,
                projects: <PickerProject>[],
                machineUuid: 'M',
              ),
            ]),
            selectedSourceIdProvider.overrideWith(
              () => ValueController('local'),
            ),
            // A project is open and the workspace is showing → picker hidden.
            selectedRegistrationIdProvider.overrideWithValue('local-proj'),
            workbenchSurfaceProvider.overrideWith(
              () => ValueController(WorkbenchSurface.workspace),
            ),
            eagerControlPlanesEnabledProvider.overrideWithValue(false),
          ],
        );
        addTearDown(c.dispose);

        expect(
          c.read(controlPlaneAliveTargetsProvider),
          isNot(contains('M')),
          reason:
              'the picker is hidden, so its fallback machine must not pin '
              'a control-plane socket',
        );
      },
    );
  });

  group('visiblePickerSourceProvider', () {
    test('falls back to the visible remote source when selection is stale', () {
      final c = ProviderContainer(
        overrides: [
          pickerSourcesProvider.overrideWithValue(const [
            PickerSource(
              id: 'machine:M',
              label: 'Machine',
              isLocal: false,
              projects: <PickerProject>[],
              machineUuid: 'M',
            ),
          ]),
          selectedSourceIdProvider.overrideWith(() => ValueController('local')),
        ],
      );
      addTearDown(c.dispose);

      expect(c.read(visiblePickerSourceProvider)?.machineUuid, 'M');
    });
  });

  group('refreshMachineInventoryAndControlPlanes', () {
    late TestStoreOverrides stores;

    setUp(() async {
      useInMemoryPrefs();
      stores = await buildTestStoreOverrides();
    });

    tearDown(() async {
      await stores.close();
    });

    test(
      'refetches inventory before retrying a stale offline control plane',
      () async {
        var inventoryFetches = 0;
        var transportBuilds = 0;
        final transport = FakeAgentTransport()
          ..requestHandler = (method, params) => {
            'frames': [
              {
                'type': 'agent:projects',
                'projects': [
                  {'projectId': 'p1', 'label': 'P1', 'running': true},
                ],
              },
            ],
          };

        final c = ProviderContainer(
          overrides: [
            accountAgentsProvider.overrideWith((_) async {
              inventoryFetches++;
              return [
                InventoryAgent(
                  deviceUuid: 'M',
                  displayName: 'Machine',
                  platform: 'linux',
                  ed25519Pub: 'pub',
                  relayUrl: 'wss://relay.example/ws',
                ),
              ];
            }),
            agentTransportForProvider('M').overrideWith((_) async {
              transportBuilds++;
              if (transportBuilds == 1) throw Exception('offline');
              return transport;
            }),
          ],
        );
        addTearDown(c.dispose);
        addTearDown(transport.dispose);

        await expectLater(
          c.read(controlPlaneClientForProvider('M').future),
          throwsA(isA<Exception>()),
        );
        expect(inventoryFetches, 0);
        expect(transportBuilds, 1);

        await refreshMachineInventoryAndControlPlanes(
          RefreshRef.ofContainer(c),
          ['M'],
        );

        expect(inventoryFetches, 1);
        expect(transportBuilds, 2);
        expect(transport.requests.single.method, 'state.snapshot');
        // Keep the stream provider listened while awaiting its first value: in
        // Riverpod 3 a StreamProvider's `.future` only resolves while the
        // provider is being observed (a bare `container.read(p.future)` no
        // longer self-pumps the stream the way v2 did). In production a widget
        // always watches this provider, so this mirrors real usage.
        final sub = c.listen(controlPlaneStateProvider('M'), (_, _) {});
        addTearDown(sub.close);
        final state = await c.read(controlPlaneStateProvider('M').future);
        expect(state.projects.single.projectId, 'p1');
      },
    );

    test(
      'drops a stale manager connection before retrying a machine',
      () async {
        final manager = RelayConnectionManager(crypto: CryptoService());
        addTearDown(manager.disposeAll);
        final stale = manager.connectionFor('M');

        final c = ProviderContainer(
          overrides: [
            ...stores.overrides,
            relayConnectionManagerProvider.overrideWithValue(manager),
            accountAgentsProvider.overrideWith((_) async => const []),
            pairedAgentProvider.overrideWith(() => _EmptyPairedAgentNotifier()),
          ],
        );
        addTearDown(c.dispose);

        await refreshMachineInventoryAndControlPlanes(
          RefreshRef.ofContainer(c),
          ['M'],
        );

        expect(manager.peek('M'), isNot(same(stale)));
      },
    );

    test(
      'keeps a healthy manager connection and refreshes its current client',
      () async {
        final manager = RelayConnectionManager(crypto: CryptoService());
        addTearDown(manager.disposeAll);
        final existing = manager.connectionFor('M');
        final transport = FakeAgentTransport()
          ..requestHandler = (method, params) => {'frames': <Object?>[]};

        final c = ProviderContainer(
          overrides: [
            relayConnectionManagerProvider.overrideWithValue(manager),
            accountAgentsProvider.overrideWith((_) async => const []),
            agentTransportForProvider('M').overrideWith((_) async => transport),
          ],
        );
        addTearDown(c.dispose);
        addTearDown(transport.dispose);

        await c.read(controlPlaneClientForProvider('M').future);

        await refreshMachineInventoryAndControlPlanes(
          RefreshRef.ofContainer(c),
          ['M'],
        );

        expect(manager.peek('M'), same(existing));
        expect(transport.requests.single.method, 'state.snapshot');
      },
    );

    test(
      'clears a stale advert when the peer is unreachable, keeps the connection',
      () async {
        // Regression: "was online → close desktop → refresh → still online".
        // The relay transport never reports a disconnect, so a present client
        // keeps its last agent:projects advert and refresh()'s snapshot RPC just
        // times out — the machine read as online. The refresh must clear the
        // stale advert (→ offline) while keeping the socket for auto-recovery.
        final manager = RelayConnectionManager(crypto: CryptoService());
        addTearDown(manager.disposeAll);
        final existing = manager.connectionFor('M');
        final transport = FakeAgentTransport()
          ..requestHandler = (method, params) =>
              throw RpcException('TIMEOUT', 'peer offline');

        final c = ProviderContainer(
          overrides: [
            relayConnectionManagerProvider.overrideWithValue(manager),
            accountAgentsProvider.overrideWith((_) async => const []),
            agentTransportForProvider('M').overrideWith((_) async => transport),
          ],
        );
        addTearDown(c.dispose);
        addTearDown(transport.dispose);

        final client = await c.read(controlPlaneClientForProvider('M').future);
        // Seed the stale advert the now-closed desktop last left behind.
        transport.emit('agent:projects', {
          'projects': [
            {'projectId': 'p1', 'label': 'P1', 'running': true},
          ],
        });
        await Future<void>.delayed(Duration.zero);
        expect(client!.currentState.projects, isNotEmpty);

        await refreshMachineInventoryAndControlPlanes(
          RefreshRef.ofContainer(c),
          ['M'],
        );

        expect(
          client.currentState.projects,
          isEmpty,
          reason:
              'an unreachable peer\'s stale advert must be cleared → offline',
        );
        expect(
          manager.peek('M'),
          same(existing),
          reason: 'the connection is kept for auto-recovery, not torn down',
        );
        expect(transport.requests.single.method, 'state.snapshot');
      },
    );
  });
}

class _EmptyPairedAgentNotifier extends PairedAgentNotifier {
  @override
  Future<List<PairedAgent>> build() async => const [];
}
