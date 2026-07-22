import 'dart:typed_data';

import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/device_provisioning.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/recent_agents.dart';
import 'package:antgrid/providers/relay_connection.dart';
import 'package:antgrid/services/keychain_device_store.dart';
import 'package:antgrid/services/phone_identity.dart';
import 'package:antgrid/storage/recent_agents_store.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';

class _MemStorage implements DeviceSecretStorage {
  String? v;
  @override
  Future<String?> read() async => v;
  @override
  Future<void> write(String s) async {
    v = s;
  }

  @override
  Future<void> delete() async {
    v = null;
  }
}

class _StubDeviceIdentityNotifier extends DeviceIdentityNotifier {
  @override
  Future<DeviceIdentity> build() async => DeviceIdentity(
        deviceId: 'phone-device-id',
        name: 'Test Phone',
        ed25519PrivateKey: Uint8List(64),
        ed25519PublicKey: Uint8List(32),
        x25519PrivateKey: Uint8List(32),
        x25519PublicKey: Uint8List(32),
      );
}

// NOTE: the placeholder `phoneEd25519Pubkey` (44 'A's) will FAIL reconnect()'s
// pubkey sanity check, which throws PairException before relay.connect(). Tests
// that only assert on the connection slot (peek) are fine; any test that uses
// relay STATE as its discriminant must use [_recentAgentWithKeypair] so the
// flow can actually reach relay.connect().
RecentAgent _recentAgent(String agentDeviceId) {
  final now = DateTime.now();
  return RecentAgent(
    agentDeviceId: agentDeviceId,
    agentLabel: agentDeviceId,
    agentEd25519Pubkey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
    relayUrl: 'ws://x',
    phoneDeviceId: 'phone-device-id',
    phoneEd25519Pubkey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
    pairedAt: now,
    lastConnectedAt: now,
  );
}

/// Builds a RecentAgent for [id] whose `phoneEd25519Pubkey` is [phi]'s REAL
/// pubkey for that id, so reconnect()'s sanity check passes and the pair flow
/// reaches relay.connect(). Use this (not [_recentAgent]) whenever a test
/// observes relay STATE — see the discriminant note in the compound-id test.
Future<RecentAgent> _recentAgentWithKeypair(
  String id,
  PhoneIdentity phi,
) async {
  final kp = await phi.ensureKeypair(id);
  final now = DateTime.now();
  return RecentAgent(
    agentDeviceId: id,
    agentLabel: id,
    agentEd25519Pubkey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
    relayUrl: 'ws://x',
    phoneDeviceId: 'phone-device-id',
    phoneEd25519Pubkey: kp.pubkeyB64,
    pairedAt: now,
    lastConnectedAt: now,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'selecting a remote id routes transport to its own connection, not _shared',
      () async {
    useInMemoryPrefs();
    final store = await RecentAgentsStore.open();
    addTearDown(store.close);
    // Seed a RecentAgent so resolution reaches connectionFor('M') via the
    // Stage-2 recent path without stubbing the AsyncNotifier.
    await store.upsert(_recentAgent('M'));

    final c = ProviderContainer(overrides: [
      phoneIdentityProvider.overrideWithValue(PhoneIdentity.inMemory()),
      keychainDeviceStoreProvider.overrideWithValue(
        KeychainDeviceStore(storage: _MemStorage()),
      ),
      recentAgentsStoreProvider.overrideWithValue(store),
      deviceIdentityProvider.overrideWith(() => _StubDeviceIdentityNotifier()),
    ]);
    addTearDown(c.dispose);
    final mgr = c.read(relayConnectionManagerProvider);

    // Start the family. It reaches connectionFor('M') only after an internal
    // `await deviceIdentityProvider.future`, so poll briefly rather than guess
    // the await count. Do NOT await the whole future: open() pairs against a
    // non-existent relay and would hang on the connect timeout.
    c.read(agentTransportForProvider('M'));
    for (var i = 0; i < 50 && mgr.peek('M') == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(mgr.peek('M'), isNotNull,
        reason: 'a machine connection was created for id M');
  });

  test('a compound project id resolves via its bare-keyed machine recent',
      () async {
    useInMemoryPrefs();
    final store = await RecentAgentsStore.open();
    addTearDown(store.close);

    // Machine-level recent keyed by the BARE uuid 'M'. The phone pubkey MUST
    // equal what PhoneIdentity.inMemory() generates for 'M': reconnect()
    // throws PairException BEFORE relay.connect() if this diverges, which would
    // make the test indistinguishable from RED. This pubkey match is what makes
    // "relay left disconnected" mean "resolve==null", not "pubkey mismatch".
    final phoneId = PhoneIdentity.inMemory();
    await store.upsert(await _recentAgentWithKeypair('M', phoneId));

    final c = ProviderContainer(overrides: [
      phoneIdentityProvider.overrideWithValue(phoneId),
      keychainDeviceStoreProvider.overrideWithValue(
        KeychainDeviceStore(storage: _MemStorage()),
      ),
      recentAgentsStoreProvider.overrideWithValue(store),
      deviceIdentityProvider.overrideWith(() => _StubDeviceIdentityNotifier()),
    ]);
    addTearDown(c.dispose);
    final mgr = c.read(relayConnectionManagerProvider);

    // Drill-in passes the COMPOUND registrationId; resolution must match by base.
    c.read(agentTransportForProvider('M.p1'));
    // connectionFor is idempotent (putIfAbsent), so this reads the SAME slot
    // that _buildRelayTransportFor opens — the relay state on it is our
    // discriminant. Poll until the pair flow reaches relay.connect() → state
    // transitions from disconnected to connecting. Without the fix (no
    // base-match), resolve returns null, relay.connect() is never called, and
    // the state stays disconnected.
    final conn = mgr.connectionFor('M.p1');
    for (var i = 0; i < 50 &&
        conn.relay.currentState.connectionState ==
            RelayConnectionState.disconnected;
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(
      conn.relay.currentState.connectionState,
      isNot(RelayConnectionState.disconnected),
      reason: 'compound id must resolve via the bare machine recent and open its machine connection',
    );
    expect(mgr.peek('M'), isNotNull,
        reason: 'v3: the data plane REUSES the one machine connection (keyed by bare uuid)');
  });

  test('pairingServiceForProvider binds to the per-id connection relay',
      () async {
    useInMemoryPrefs();
    final store = await RecentAgentsStore.open();
    addTearDown(store.close);

    // Minimal overrides so the family can be read without platform plugins:
    // PhoneIdentity/KeychainDeviceStore/RecentAgentsStore all throw on a real
    // secure-storage/prefs read otherwise. licenseTokenMinterProvider is read
    // lazily inside tokenProvider, so it need not be overridden here.
    final c = ProviderContainer(overrides: [
      phoneIdentityProvider.overrideWithValue(PhoneIdentity.inMemory()),
      keychainDeviceStoreProvider.overrideWithValue(
        KeychainDeviceStore(storage: _MemStorage()),
      ),
      recentAgentsStoreProvider.overrideWithValue(store),
    ]);
    addTearDown(c.dispose);
    final mgr = c.read(relayConnectionManagerProvider);

    final pairingA = c.read(pairingServiceForProvider('A'));
    final pairingB = c.read(pairingServiceForProvider('B'));

    expect(identical(pairingA, pairingB), isFalse,
        reason: 'distinct ids → distinct PairingService instances');
    expect(
      identical(mgr.connectionFor('A').relay, mgr.connectionFor('B').relay),
      isFalse,
    );
  });

  test(
      'reconnect rebinds pairingServiceForProvider to the fresh connection '
      '(a released connection\'s disposed relay must not survive)', () async {
    // Regression: the pull-to-refresh / Retry reconnect releases the prior
    // RelayConnection (disposing its RelayService) and mints a fresh one, but
    // pairingServiceForProvider captured the OLD relay at construction. Without
    // rebinding, the reconnect's pairFlow sends the pair-request onto the closed
    // stream ("Bad state: Cannot add new events after calling close") and never
    // pairs — the machine is stuck "offline" until a full app restart.
    useInMemoryPrefs();
    final store = await RecentAgentsStore.open();
    addTearDown(store.close);
    await store.upsert(_recentAgent('M'));

    final c = ProviderContainer(overrides: [
      phoneIdentityProvider.overrideWithValue(PhoneIdentity.inMemory()),
      keychainDeviceStoreProvider.overrideWithValue(
        KeychainDeviceStore(storage: _MemStorage()),
      ),
      recentAgentsStoreProvider.overrideWithValue(store),
      deviceIdentityProvider.overrideWith(() => _StubDeviceIdentityNotifier()),
    ]);
    addTearDown(c.dispose);
    final mgr = c.read(relayConnectionManagerProvider);

    // First build → connection A + pairing service bound to A's relay.
    c.read(agentTransportForProvider('M'));
    for (var i = 0; i < 50 && mgr.peek('M') == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final relayA = mgr.peek('M')!.relay;
    final pairingA = c.read(pairingServiceForProvider('M'));

    // Simulate the reconnect: release the connection (disposes relay A's stream
    // controllers) and invalidate the transport so it rebuilds against a fresh
    // connection — exactly what refreshMachineInventoryAndControlPlanes does.
    mgr.release('M');
    c.invalidate(agentTransportForProvider('M'));

    c.read(agentTransportForProvider('M'));
    for (var i = 0;
        i < 50 &&
            (mgr.peek('M') == null || identical(mgr.peek('M')!.relay, relayA));
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    // Let _buildRelayTransportFor's post-connectionFor invalidate settle.
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(identical(mgr.peek('M')!.relay, relayA), isFalse,
        reason: 'release+rebuild must mint a fresh RelayService');
    final pairingB = c.read(pairingServiceForProvider('M'));
    expect(identical(pairingB, pairingA), isFalse,
        reason: 'the pairing service must be rebuilt on reconnect so its '
            'pairFlow drives the live relay, not the disposed one');
  });
}
