import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/account_agents.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/control_plane.dart';
import 'package:antgrid/providers/device_provisioning.dart';
import 'package:antgrid/providers/new_session_picker.dart';
import 'package:antgrid/providers/relay_connection.dart';
import 'package:antgrid/providers/ui_attention_providers.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/screens/app_shell.dart';
import 'package:antgrid/services/account_agents_api.dart';
import 'package:antgrid/services/control_plane_client.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid/widgets/new_session/picker_sources.dart';

import '../helpers/prefs_test_mock.dart';
import '../helpers/test_store_overrides.dart';

/// Records release calls and advertises a fixed set of open control-plane
/// sockets, so the reaper's reconcile decisions are observable without real
/// relay connections.
class _RecordingManager extends RelayConnectionManager {
  _RecordingManager(this._openIds) : super(crypto: CryptoService());

  final List<String> _openIds;
  final List<String> released = [];

  @override
  List<String> openControlPlaneIds() => List.of(_openIds);

  @override
  void release(String registrationId) {
    released.add(registrationId);
    _openIds.remove(registrationId);
  }
}

/// Flipped by the test to swap the reaper's child between two distinct subtrees,
/// mimicking the picker (NewSessionScreen) ↔ workspace (WorkspaceShell) route
/// switch that [ControlPlaneReaper] is deliberately mounted ABOVE in app_shell.
final _onWorkspaceRouteProvider = NotifierProvider<ValueController<bool>, bool>(
  () => ValueController(false),
);

final _inventoryFutureProvider =
    NotifierProvider<
      ValueController<Future<List<InventoryAgent>>>,
      Future<List<InventoryAgent>>
    >(() => ValueController(Future.value(const <InventoryAgent>[])));

/// Mutable stand-in for the focused registration id, so a test can leave the
/// New Session canvas (focus a project) at runtime — the reap trigger under
/// the open-socket pinning contract, where de-selection alone no longer reaps.
final _focusedRegistrationProvider =
    NotifierProvider<ValueController<String?>, String?>(
      () => ValueController(null),
    );

void main() {
  testWidgets(
    'reaper survives the picker→workspace child swap and still reaps when the canvas is left',
    (tester) async {
      final registry = ProjectSessionRegistry(
        localCap: 10,
        relayCap: 30,
        onEvict: (_) async {},
      );
      // Two open control-plane sockets: M (about to be de-selected) and K
      // (stays viewed via an open project), so we can assert K is NOT reaped.
      final mgr = _RecordingManager(['M', 'K']);
      registry.touch(
        'K.a',
        isLocal: false,
      ); // K backs an open project → stays alive

      final container = ProviderContainer(
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
            PickerSource(
              id: 'machine:M',
              label: 'Machine',
              isLocal: false,
              projects: <PickerProject>[],
              machineUuid: 'M',
            ),
          ]),
          selectedSourceIdProvider.overrideWith(
            () => ValueController('machine:M'),
          ),
          relayConnectionManagerProvider.overrideWithValue(mgr),
          // Surface pinned to workspace so pickerVisible toggles purely on the
          // focused registration id: null → canvas visible, non-null → left.
          selectedRegistrationIdProvider.overrideWith(
            (ref) => ref.watch(_focusedRegistrationProvider),
          ),
          workbenchSurfaceProvider.overrideWith(
            () => ValueController(WorkbenchSurface.workspace),
          ),
        ],
      );
      addTearDown(container.dispose);

      // The reaper wraps a child that swaps between two disjoint subtrees keyed
      // distinctly, so a swap genuinely tears the old subtree down. A regression
      // moving the reaper BELOW this switch unmounts its listener on the swap and
      // the post-swap de-selection below would go unobserved → release missed.
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: Consumer(
            builder: (context, ref, _) {
              final onWorkspace = ref.watch(_onWorkspaceRouteProvider);
              return ControlPlaneReaper(
                child: onWorkspace
                    ? const SizedBox(key: ValueKey('workspace'))
                    : const SizedBox(key: ValueKey('picker')),
              );
            },
          ),
        ),
      );

      // Sanity: M is viewed, K backs an open project → both alive, nothing reaped.
      expect(
        container.read(controlPlaneAliveTargetsProvider),
        unorderedEquals(['M', 'K']),
      );
      expect(mgr.released, isEmpty);

      // Swap the route child (picker → workspace) BEFORE de-selecting, so the
      // de-selection is observed only if the reaper outlived the swap.
      container.read(_onWorkspaceRouteProvider.notifier).set(true);
      await tester.pump();
      expect(find.byKey(const ValueKey('workspace')), findsOneWidget);
      expect(find.byKey(const ValueKey('picker')), findsNothing);
      expect(mgr.released, isEmpty);

      // De-select M (switch the viewed source to local). While the New Session
      // canvas is still visible, M's ALREADY-open socket stays pinned (the
      // recents list renders its labels/status live) — de-selection alone must
      // not reap it.
      container.read(selectedSourceIdProvider.notifier).set('local');
      await tester.pump();
      expect(
        container.read(controlPlaneAliveTargetsProvider),
        unorderedEquals(['M', 'K']),
      );
      expect(mgr.released, isEmpty);

      // Leave the canvas (focus a project → workspace). The alive set drops M
      // but keeps K (open project). The reaper, having survived the swap,
      // observes the change and releases only M.
      container.read(_focusedRegistrationProvider.notifier).set('K.a');
      await tester.pump();

      expect(container.read(controlPlaneAliveTargetsProvider), ['K']);
      expect(mgr.released, ['M']);
      expect(mgr.released, isNot(contains('K')));
    },
  );

  testWidgets(
    'reaping a machine invalidates its transport so a re-view rebuilds the socket',
    (tester) async {
      // The control-plane client is built atop the non-autoDispose transport
      // family; if the reaper releases the connection but does NOT invalidate
      // agentTransportForProvider(id), a re-view rebuilds the client on the
      // stale (now-dead) transport element. Assert the transport family entry
      // is rebuilt on reap by counting builds per id — this count only advances
      // on the explicit invalidate, so dropping that line makes the test red.
      final builds = <String, int>{};
      final registry = ProjectSessionRegistry(
        localCap: 10,
        relayCap: 30,
        onEvict: (_) async {},
      );
      final mgr = _RecordingManager(['M']);

      final container = ProviderContainer(
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
            PickerSource(
              id: 'machine:M',
              label: 'Machine',
              isLocal: false,
              projects: <PickerProject>[],
              machineUuid: 'M',
            ),
          ]),
          selectedSourceIdProvider.overrideWith(
            () => ValueController('machine:M'),
          ),
          relayConnectionManagerProvider.overrideWithValue(mgr),
          // Same shape as the first test: reap by leaving the canvas, since an
          // open socket stays pinned while it is visible.
          selectedRegistrationIdProvider.overrideWith(
            (ref) => ref.watch(_focusedRegistrationProvider),
          ),
          workbenchSurfaceProvider.overrideWith(
            () => ValueController(WorkbenchSurface.workspace),
          ),
          // Counting stand-in for the real transport builder: records a build
          // per id. A non-autoDispose family, mirroring the real one, so an
          // invalidate is the ONLY thing that re-runs it for a still-watched id.
          agentTransportForProvider.overrideWith((ref, id) async {
            builds[id] = (builds[id] ?? 0) + 1;
            return null;
          }),
        ],
      );
      addTearDown(container.dispose);

      // Keep M's transport element alive across the reap, so an invalidate
      // forces an observable rebuild rather than silently disposing the entry.
      final keepAlive = container.listen(
        agentTransportForProvider('M'),
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(keepAlive.close);
      await container.read(agentTransportForProvider('M').future);
      expect(builds['M'], 1);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const ControlPlaneReaper(child: SizedBox()),
        ),
      );

      // Leave the canvas (focus a project on some other machine) → M falls out
      // of the alive set; the reaper releases it AND invalidates its transport.
      container.read(_focusedRegistrationProvider.notifier).set('K.a');
      await tester.pump();
      expect(mgr.released, ['M']);

      // The invalidate re-ran the still-watched element: a fresh transport
      // build. Without ref.invalidate(agentTransportForProvider(id)) in the
      // reaper, the count stays at 1 and a re-view would serve the dead element.
      await container.read(agentTransportForProvider('M').future);
      expect(
        builds['M'],
        2,
        reason:
            'transport must rebuild after reap; missing invalidate leaves it stale',
      );
    },
  );

  test(
    'inventory refresh loading does not reap the currently viewed machine',
    () async {
      useInMemoryPrefs();
      final stores = await buildTestStoreOverrides();
      addTearDown(stores.close);

      final registry = ProjectSessionRegistry(
        localCap: 10,
        relayCap: 30,
        onEvict: (_) async {},
      );
      final mgr = _RecordingManager(['M']);
      final initialInventory = Future.value([
        InventoryAgent(
          deviceUuid: 'M',
          displayName: 'Machine',
          platform: 'linux',
          ed25519Pub: 'pub',
          relayUrl: 'wss://relay.example/ws',
        ),
      ]);
      final container = ProviderContainer(
        overrides: [
          ...stores.overrides,
          projectSessionRegistryProvider.overrideWith(
            () => ProjectSessionRegistryController(registry),
          ),
          selectedSourceIdProvider.overrideWith(
            () => ValueController('machine:M'),
          ),
          relayConnectionManagerProvider.overrideWithValue(mgr),
          localDeviceUuidProvider.overrideWith((_) async => null),
          _inventoryFutureProvider.overrideWith(
            () => ValueController(initialInventory),
          ),
          accountAgentsProvider.overrideWith(
            (ref) => ref.watch(_inventoryFutureProvider),
          ),
        ],
      );
      addTearDown(container.dispose);

      final reaper = container.listen<Set<String>>(
        controlPlaneAliveTargetsProvider,
        (_, alive) {
          for (final id in mgr.openControlPlaneIds()) {
            if (!alive.contains(id)) mgr.release(id);
          }
        },
        fireImmediately: true,
      );
      addTearDown(reaper.close);

      await container.read(accountAgentsProvider.future);
      expect(container.read(controlPlaneAliveTargetsProvider), contains('M'));
      expect(mgr.released, isEmpty);

      final pendingInventory = Completer<List<InventoryAgent>>();
      container
          .read(_inventoryFutureProvider.notifier)
          .set(pendingInventory.future);
      container.invalidate(accountAgentsProvider);
      await Future<void>.delayed(Duration.zero);
      final releasedDuringLoading = List<String>.of(mgr.released);

      pendingInventory.complete(await initialInventory);
      await container.read(accountAgentsProvider.future);
      await Future<void>.delayed(Duration.zero);

      expect(
        releasedDuringLoading,
        isEmpty,
        reason:
            'the viewed machine must stay alive while refreshed inventory is loading',
      );
    },
  );

  testWidgets(
    'a never-before-cached project revealed by a live advert gets its session list seeded automatically',
    (tester) async {
      // Regression test: landing on the New Session canvas never dials the
      // relay (renders straight from the cache), and pull-to-refresh only
      // re-syncs rows the cache already knows about — neither path discovers
      // a project's sessions the FIRST time a phone sees it, even though the
      // machine is already connected and the project is already advertised.
      // _seedNeverSyncedSessions closes that gap reactively, from an
      // already-open socket, with no new dial.
      useInMemoryPrefs();
      final stores = await buildTestStoreOverrides();
      addTearDown(stores.close);

      final registry = ProjectSessionRegistry(
        localCap: 10,
        relayCap: 30,
        onEvict: (_) async {},
      );
      final mgr = _RecordingManager(['M']);
      final transport = FakeAgentTransport();
      transport.requestHandler = (method, params) => {
        'sessions': [
          {
            'id': 's1',
            'name': 'hello',
            'createdAt': 0,
            'lastUsedAt': 0,
            'archived': false,
          },
        ],
      };
      final client = ControlPlaneClient(transport: transport);
      addTearDown(client.dispose);

      final container = ProviderContainer(
        overrides: [
          ...stores.overrides,
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
            PickerSource(
              id: 'machine:M',
              label: 'Machine',
              isLocal: false,
              projects: <PickerProject>[],
              machineUuid: 'M',
            ),
          ]),
          selectedSourceIdProvider.overrideWith(
            () => ValueController('machine:M'),
          ),
          relayConnectionManagerProvider.overrideWithValue(mgr),
          controlPlaneClientForProvider.overrideWith(
            (ref, uuid) async => uuid == 'M' ? client : null,
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const ControlPlaneReaper(child: SizedBox()),
        ),
      );
      await tester.pump();
      // M must have survived the post-frame reconcile (viewed machine, pinned).
      expect(mgr.released, isEmpty);

      // Never-cached project 'proj-new' arrives on the live advert.
      transport.emit('agent:projects', {
        'projects': [
          {'projectId': 'proj-new', 'label': 'New Project', 'running': true},
        ],
      });
      await tester.pump();
      await tester.pump(); // let the unawaited listSessions().then(...) settle

      final cache = stores.cachedSessionsStore;
      expect(cache.has('M.proj-new'), isTrue);
      expect(cache.get('M.proj-new'), hasLength(1));
      expect(cache.get('M.proj-new').single.id, 's1');
      expect(
        transport.requests.where((r) => r.method == 'sessions.list'),
        hasLength(1),
      );

      // Re-emitting the same advert (e.g. an unrelated label refresh) must not
      // re-request a project that's already seeded, even with a nonzero list.
      transport.emit('agent:projects', {
        'projects': [
          {'projectId': 'proj-new', 'label': 'New Project', 'running': true},
        ],
      });
      await tester.pump();
      await tester.pump();
      expect(
        transport.requests.where((r) => r.method == 'sessions.list'),
        hasLength(1),
        reason: 're-emitting the same advert must not re-request an already-seeded project',
      );

      // Drain the store's debounced flush timer so it doesn't outlive the
      // widget tree teardown (flutter_test asserts no pending timers).
      await stores.cachedSessionsStore.flushNow();
    },
  );
}
