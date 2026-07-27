import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/providers/recent_agents.dart';
import 'package:antgrid/storage/recent_agents_store.dart';
import '../helpers/prefs_test_mock.dart';

RecentAgent _agent(String id) => RecentAgent(
  agentDeviceId: id,
  agentLabel: id,
  agentEd25519Pubkey: '',
  relayUrl: '',
  pairedAt: DateTime.utc(2026, 1, 1),
  lastConnectedAt: DateTime.utc(2026, 1, 1),
);

void main() {
  setUp(() {
    useInMemoryPrefs();
  });

  test('notifier seeds from store on construction', () async {
    final store = await RecentAgentsStore.open();
    addTearDown(store.close);
    await store.upsert(_agent('a'));

    final container = ProviderContainer(
      overrides: [recentAgentsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);

    expect(container.read(recentAgentsProvider).map((a) => a.agentDeviceId), [
      'a',
    ]);
  });

  test('notifier reflects direct store writes (PairingService path)', () async {
    final store = await RecentAgentsStore.open();
    addTearDown(store.close);
    final container = ProviderContainer(
      overrides: [recentAgentsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);

    // Force the notifier to materialize so it subscribes to the stream
    // before the write happens.
    expect(container.read(recentAgentsProvider), isEmpty);

    // Simulate PairingService writing straight to the store.
    await store.upsert(_agent('a'));
    // Let the broadcast emission settle into the notifier.
    await Future<void>.delayed(Duration.zero);

    expect(container.read(recentAgentsProvider).map((a) => a.agentDeviceId), [
      'a',
    ]);
  });

  test('notifier reflects direct store removes', () async {
    final store = await RecentAgentsStore.open();
    addTearDown(store.close);
    await store.upsert(_agent('a'));
    await store.upsert(_agent('b'));

    final container = ProviderContainer(
      overrides: [recentAgentsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);

    expect(container.read(recentAgentsProvider), hasLength(2));

    await store.remove('a');
    await Future<void>.delayed(Duration.zero);

    expect(container.read(recentAgentsProvider).map((x) => x.agentDeviceId), [
      'b',
    ]);
  });
}
