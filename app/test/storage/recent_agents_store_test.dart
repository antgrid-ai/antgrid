import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/storage/recent_agents_store.dart';
import '../helpers/prefs_test_mock.dart';

void main() {
  setUp(() {
    useInMemoryPrefs();
  });

  RecentAgent makeAgent({
    String agentDeviceId = 'agent-1',
    String agentLabel = 'My Mac',
    String agentEd25519Pubkey = 'pub-agent-1',
    String relayUrl = 'wss://relay.example/ws',
    DateTime? pairedAt,
    DateTime? lastConnectedAt,
  }) {
    final t = DateTime.utc(2026, 1, 1);
    return RecentAgent(
      agentDeviceId: agentDeviceId,
      agentLabel: agentLabel,
      agentEd25519Pubkey: agentEd25519Pubkey,
      relayUrl: relayUrl,
      pairedAt: pairedAt ?? t,
      lastConnectedAt: lastConnectedAt ?? t,
    );
  }

  test('round-trips agents through SharedPreferences', () async {
    final store = await RecentAgentsStore.open();
    expect(store.list(), isEmpty);

    final a = makeAgent();
    await store.upsert(a);

    final reopened = await RecentAgentsStore.open();
    final all = reopened.list();
    expect(all, hasLength(1));
    expect(all.first.agentDeviceId, 'agent-1');
    expect(all.first.agentLabel, 'My Mac');
    expect(all.first.relayUrl, 'wss://relay.example/ws');
    expect(all.first.pairedAt, a.pairedAt);
    expect(all.first.lastConnectedAt, a.lastConnectedAt);
  });

  test('upsert is idempotent on agentDeviceId', () async {
    final store = await RecentAgentsStore.open();
    await store.upsert(makeAgent(agentLabel: 'Old'));
    await store.upsert(
      makeAgent(agentLabel: 'New', lastConnectedAt: DateTime.utc(2026, 2, 1)),
    );

    final all = store.list();
    expect(all, hasLength(1));
    expect(all.first.agentLabel, 'New');
    expect(all.first.lastConnectedAt, DateTime.utc(2026, 2, 1));
  });

  test('remove drops the agent', () async {
    final store = await RecentAgentsStore.open();
    await store.upsert(makeAgent(agentDeviceId: 'a'));
    await store.upsert(makeAgent(agentDeviceId: 'b'));
    expect(store.list(), hasLength(2));

    await store.remove('a');
    final all = store.list();
    expect(all, hasLength(1));
    expect(all.first.agentDeviceId, 'b');
  });

  test('list() returns an unmodifiable view', () async {
    final store = await RecentAgentsStore.open();
    await store.upsert(makeAgent());
    final all = store.list();
    expect(
      () => all.add(makeAgent(agentDeviceId: 'x')),
      throwsUnsupportedError,
    );
  });

  test('emits current snapshot on changes after upsert', () async {
    final store = await RecentAgentsStore.open();
    addTearDown(store.close);
    final emissions = <List<RecentAgent>>[];
    final sub = store.changes.listen(emissions.add);

    await store.upsert(makeAgent(agentDeviceId: 'a'));
    await store.upsert(makeAgent(agentDeviceId: 'b'));

    // Let microtasks drain so broadcast deliveries settle.
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();

    expect(emissions, hasLength(2));
    expect(emissions[0].map((a) => a.agentDeviceId), ['a']);
    expect(emissions[1].map((a) => a.agentDeviceId), ['a', 'b']);
  });

  test('does not emit on no-op upsert of identical agent', () async {
    final store = await RecentAgentsStore.open();
    addTearDown(store.close);
    await store.upsert(makeAgent(agentDeviceId: 'a'));

    final emissions = <List<RecentAgent>>[];
    final sub = store.changes.listen(emissions.add);

    // Same agent value — encoded JSON unchanged, so no emission.
    await store.upsert(makeAgent(agentDeviceId: 'a'));

    await Future<void>.delayed(Duration.zero);
    await sub.cancel();

    expect(emissions, isEmpty);
  });

  test('emits current snapshot on changes after remove', () async {
    final store = await RecentAgentsStore.open();
    addTearDown(store.close);
    await store.upsert(makeAgent(agentDeviceId: 'a'));
    await store.upsert(makeAgent(agentDeviceId: 'b'));

    final emissions = <List<RecentAgent>>[];
    final sub = store.changes.listen(emissions.add);

    await store.remove('a');

    await Future<void>.delayed(Duration.zero);
    await sub.cancel();

    expect(emissions, hasLength(1));
    expect(emissions.single.map((x) => x.agentDeviceId), ['b']);
  });
}
