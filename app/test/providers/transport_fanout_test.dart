import 'dart:convert';

import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/connection_identity.dart';
import 'package:antgrid/providers/device_provisioning.dart';
import 'package:antgrid/providers/recent_agents.dart';
import 'package:antgrid/providers/relay_connection.dart';
import 'package:antgrid/services/keychain_device_store.dart';
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

/// The app's own remote-control identity. Every relay dial now authenticates
/// and signs the E2E transcript as this record, so it must be resolvable for a
/// remote transport to be built at all.
DeviceRecord _connectionRecord() => DeviceRecord(
  userId: 'u-1',
  deviceUuid: 'controller-uuid',
  clientId: 'cid',
  clientSecret: 'csec',
  ed25519Pub: base64Encode(List<int>.filled(32, 1)),
  ed25519Priv: base64Encode(List<int>.filled(32, 2)),
  x25519Pub: base64Encode(List<int>.filled(32, 3)),
  x25519Priv: base64Encode(List<int>.filled(32, 4)),
);

RecentAgent _recentAgent(String agentDeviceId) {
  final now = DateTime.now();
  return RecentAgent(
    agentDeviceId: agentDeviceId,
    agentLabel: agentDeviceId,
    agentEd25519Pubkey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
    relayUrl: 'ws://x',
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

      final c = ProviderContainer(
        overrides: [
          keychainDeviceStoreProvider.overrideWithValue(
            KeychainDeviceStore(storage: _MemStorage()),
          ),
          recentAgentsStoreProvider.overrideWithValue(store),
          connectionDeviceRecordProvider.overrideWith(
            (_) async => _connectionRecord(),
          ),
          connectionTokenMinterProvider.overrideWith((_) async => null),
        ],
      );
      addTearDown(c.dispose);
      final mgr = c.read(relayConnectionManagerProvider);

      // Start the family. It reaches connectionFor('M') only after an internal
      // `await connectionDeviceRecordProvider.future`, so poll briefly rather
      // than guess the await count. Do NOT await the whole future: the dial
      // targets a non-existent relay and would hang on the connect timeout.
      c.read(agentTransportForProvider('M'));
      for (var i = 0; i < 50 && mgr.peek('M') == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(
        mgr.peek('M'),
        isNotNull,
        reason: 'a machine connection was created for id M',
      );
    },
  );

  test('a compound project id resolves via its bare-keyed machine recent', () async {
    useInMemoryPrefs();
    final store = await RecentAgentsStore.open();
    addTearDown(store.close);

    // Machine-level recent keyed by the BARE uuid 'M'.
    await store.upsert(_recentAgent('M'));

    final c = ProviderContainer(
      overrides: [
        keychainDeviceStoreProvider.overrideWithValue(
          KeychainDeviceStore(storage: _MemStorage()),
        ),
        recentAgentsStoreProvider.overrideWithValue(store),
        connectionDeviceRecordProvider.overrideWith(
          (_) async => _connectionRecord(),
        ),
        connectionTokenMinterProvider.overrideWith((_) async => null),
      ],
    );
    addTearDown(c.dispose);
    final mgr = c.read(relayConnectionManagerProvider);

    // Drill-in passes the COMPOUND registrationId; resolution must match by base.
    c.read(agentTransportForProvider('M.p1'));
    // connectionFor is idempotent (putIfAbsent), so this reads the SAME slot
    // that _buildRelayTransportFor opens — the relay state on it is our
    // discriminant. Poll until the supervisor's dial reaches relay.connect() →
    // state transitions from disconnected to connecting. Without the fix (no
    // base-match), resolve returns null, relay.connect() is never called, and
    // the state stays disconnected.
    final conn = mgr.connectionFor('M.p1');
    for (
      var i = 0;
      i < 50 &&
          conn.relay.currentState.connectionState ==
              RelayConnectionState.disconnected;
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(
      conn.relay.currentState.connectionState,
      isNot(RelayConnectionState.disconnected),
      reason:
          'compound id must resolve via the bare machine recent and open its machine connection',
    );
    expect(
      mgr.peek('M'),
      isNotNull,
      reason:
          'v3: the data plane REUSES the one machine connection (keyed by bare uuid)',
    );
  });
}
