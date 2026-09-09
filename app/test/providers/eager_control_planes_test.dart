import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/control_plane.dart';
import 'package:antgrid/providers/eager_control_planes.dart';
import 'package:antgrid/providers/new_session_picker.dart';
import 'package:antgrid/providers/recent_agents.dart';
import 'package:antgrid/providers/relay_connection.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/storage/recent_agents_store.dart';
import 'package:antgrid/widgets/new_session/picker_sources.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';

/// Store-free stand-in for [RecentAgentsNotifier]: serves a fixed snapshot so
/// eager-target derivation is testable without SharedPreferences.
class _FixedRecentAgents extends RecentAgentsNotifier {
  _FixedRecentAgents(this.rows);
  final List<RecentAgent> rows;
  @override
  List<RecentAgent> build() => rows;
}

RecentAgent _recent(String id, DateTime lastConnectedAt) => RecentAgent(
  agentDeviceId: id,
  agentLabel: id,
  agentEd25519Pubkey: 'pub',
  relayUrl: 'wss://relay.example/ws',
  pairedAt: lastConnectedAt,
  lastConnectedAt: lastConnectedAt,
);

void main() {
  group('eagerControlPlaneTargets', () {
    test('caps at the most recently connected machines', () {
      final targets = eagerControlPlaneTargets([
        _recent('A', DateTime(2026, 1, 1)),
        _recent('C', DateTime(2026, 1, 3)),
        _recent('D', DateTime(2026, 1, 4)),
        _recent('B', DateTime(2026, 1, 2)),
      ], cap: 3);
      expect(targets, unorderedEquals(['D', 'C', 'B']));
    });

    test('dedupes compound rows to their bare uuid before spending cap', () {
      // Legacy QR rows persist the compound registrationId; the same machine
      // remembered both ways must cost ONE slot, leaving room for K.
      final targets = eagerControlPlaneTargets([
        _recent('M.proj', DateTime(2026, 1, 4)),
        _recent('M', DateTime(2026, 1, 3)),
        _recent('K', DateTime(2026, 1, 2)),
        _recent('J', DateTime(2026, 1, 1)),
      ], cap: 2);
      expect(targets, unorderedEquals(['M', 'K']));
    });
  });

  group('eagerControlPlaneTargetsProvider', () {
    test(
      'empty when disabled (desktop), without touching the recents store',
      () {
        final c = ProviderContainer(
          overrides: [
            eagerControlPlanesEnabledProvider.overrideWithValue(false),
            // recentAgentsStoreProvider is NOT overridden: reading recents here
            // would throw its StateError, so an empty result also proves the
            // disabled path never reaches the store.
          ],
        );
        addTearDown(c.dispose);
        expect(c.read(eagerControlPlaneTargetsProvider), isEmpty);
      },
    );

    test('derives capped bare uuids from recents when enabled', () {
      final c = ProviderContainer(
        overrides: [
          eagerControlPlanesEnabledProvider.overrideWithValue(true),
          recentAgentsProvider.overrideWith(
            () => _FixedRecentAgents([
              _recent('M.proj', DateTime(2026, 1, 2)),
              _recent('K', DateTime(2026, 1, 1)),
            ]),
          ),
        ],
      );
      addTearDown(c.dispose);
      expect(
        c.read(eagerControlPlaneTargetsProvider),
        unorderedEquals(['M', 'K']),
      );
    });
  });

  group('controlPlaneAliveTargetsProvider ∪ eager targets', () {
    test('eager machines are alive with no selection or expansion', () {
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
          selectedSourceIdProvider.overrideWith(() => ValueController('local')),
          eagerControlPlanesEnabledProvider.overrideWithValue(true),
          recentAgentsProvider.overrideWith(
            () => _FixedRecentAgents([_recent('M', DateTime(2026, 1, 1))]),
          ),
        ],
      );
      addTearDown(c.dispose);
      expect(c.read(controlPlaneAliveTargetsProvider), contains('M'));
    });
  });

  group('kickEagerControlPlaneDials', () {
    test(
      'dials targets without a connection, skips machines with one',
      () async {
        final manager = RelayConnectionManager(crypto: CryptoService());
        addTearDown(manager.disposeAll);
        // M already has a connection (however unhealthy): its supervisor owns
        // recovery, so the kick must not dial it again.
        final existing = manager.connectionFor('M');

        final dialed = <String>[];
        final c = ProviderContainer(
          overrides: [
            eagerControlPlanesEnabledProvider.overrideWithValue(true),
            recentAgentsProvider.overrideWith(
              () => _FixedRecentAgents([
                _recent('M', DateTime(2026, 1, 2)),
                _recent('K', DateTime(2026, 1, 1)),
              ]),
            ),
            relayConnectionManagerProvider.overrideWithValue(manager),
            controlPlaneClientForProvider.overrideWith((ref, uuid) async {
              dialed.add(uuid);
              return null;
            }),
          ],
        );
        addTearDown(c.dispose);

        await kickEagerControlPlaneDials(RefreshRef.ofContainer(c));

        expect(dialed, ['K']);
        expect(manager.peek('M'), same(existing));
      },
    );

    test('no-op when disabled (desktop)', () async {
      final manager = RelayConnectionManager(crypto: CryptoService());
      addTearDown(manager.disposeAll);
      final dialed = <String>[];
      final c = ProviderContainer(
        overrides: [
          eagerControlPlanesEnabledProvider.overrideWithValue(false),
          relayConnectionManagerProvider.overrideWithValue(manager),
          controlPlaneClientForProvider.overrideWith((ref, uuid) async {
            dialed.add(uuid);
            return null;
          }),
        ],
      );
      addTearDown(c.dispose);

      await kickEagerControlPlaneDials(RefreshRef.ofContainer(c));

      expect(dialed, isEmpty);
    });

    test(
      'a settled cached rejection behind a live connection is repaired',
      () async {
        final manager = RelayConnectionManager(crypto: CryptoService());
        addTearDown(manager.disposeAll);
        // The failed-at-launch shape: the dial materialized M's connection
        // before the provider chain settled on a rejection — a bare peek-skip
        // would strand that error until manual pull-to-refresh.
        manager.connectionFor('M');

        var builds = 0;
        final c = ProviderContainer(
          overrides: [
            eagerControlPlanesEnabledProvider.overrideWithValue(true),
            recentAgentsProvider.overrideWith(
              () => _FixedRecentAgents([_recent('M', DateTime(2026, 1, 1))]),
            ),
            relayConnectionManagerProvider.overrideWithValue(manager),
            controlPlaneClientForProvider.overrideWith((ref, uuid) async {
              builds++;
              if (builds == 1) throw Exception('agent offline at launch');
              return null;
            }),
          ],
        );
        addTearDown(c.dispose);

        // Settle the rejection, as the launch dial's swallowed read would.
        await expectLater(
          c.read(controlPlaneClientForProvider('M').future),
          throwsException,
        );

        await kickEagerControlPlaneDials(RefreshRef.ofContainer(c));

        // Never Connected (no supervisor started) → the stuck connection was
        // released for a genuinely fresh attempt, and the chain re-dialed.
        expect(builds, 2);
        expect(manager.peek('M'), isNull);
      },
    );

    test('a stale failed attempt is invalidated so the kick redials', () async {
      final manager = RelayConnectionManager(crypto: CryptoService());
      addTearDown(manager.disposeAll);
      var builds = 0;
      final c = ProviderContainer(
        overrides: [
          eagerControlPlanesEnabledProvider.overrideWithValue(true),
          recentAgentsProvider.overrideWith(
            () => _FixedRecentAgents([_recent('K', DateTime(2026, 1, 1))]),
          ),
          relayConnectionManagerProvider.overrideWithValue(manager),
          controlPlaneClientForProvider.overrideWith((ref, uuid) async {
            builds++;
            if (builds == 1) throw Exception('offline at launch');
            return null;
          }),
        ],
      );
      addTearDown(c.dispose);

      // Launch kick fails (machine offline) and swallows the error; the family
      // caches the rejection (noProviderRetry in production).
      await kickEagerControlPlaneDials(RefreshRef.ofContainer(c));
      expect(builds, 1);

      // Resume kick: no connection was ever materialized for K, so the stale
      // rejection must be invalidated and the dial attempted afresh.
      await kickEagerControlPlaneDials(RefreshRef.ofContainer(c));
      expect(builds, 2);
    });
  });
}
