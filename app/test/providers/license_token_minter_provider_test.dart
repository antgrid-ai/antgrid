import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:antgrid/connection/relay_mechanisms.dart';
import 'package:antgrid/providers/account_agents.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/auth.dart';
import 'package:antgrid/providers/device_provisioning.dart';
import 'package:antgrid/providers/connection_identity.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/recent_agents.dart';
import 'package:antgrid/providers/relay_connection.dart';
import 'package:antgrid/services/account_agents_api.dart';
import 'package:antgrid/services/keychain_device_store.dart';
import 'package:antgrid/services/license_token_minter.dart';
import 'package:antgrid/storage/recent_agents_store.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';

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

/// Captures the [RelayMechanisms] the transport builder hands the connection —
/// and deliberately never constructs a supervisor, so nothing dials.
class _CapturingConnection extends RelayConnection {
  _CapturingConnection() : super(machineDeviceId: 'M', crypto: CryptoService());

  final Completer<RelayMechanisms> _first = Completer<RelayMechanisms>();

  /// Resolves with the first mechanisms handed over, so the test awaits the
  /// event itself rather than polling the wall clock for it.
  Future<RelayMechanisms> get firstMechanisms => _first.future;

  @override
  void ensureStarted({required RelayMechanisms mechanisms}) {
    if (!_first.isCompleted) _first.complete(mechanisms);
  }
}

class _CapturingManager extends RelayConnectionManager {
  _CapturingManager(this.conn) : super(crypto: CryptoService());
  final _CapturingConnection conn;

  @override
  RelayConnection connectionFor(String machineDeviceId) => conn;
  @override
  RelayConnection? peek(String machineDeviceId) => conn;
}

DeviceRecord _record(String uuid) => DeviceRecord(
  userId: 'u1',
  deviceUuid: uuid,
  clientId: 'cid',
  clientSecret: 'csec',
  ed25519Pub: base64Encode(List<int>.filled(32, 1)),
  ed25519Priv: base64Encode(List<int>.filled(32, 2)),
  x25519Pub: base64Encode(List<int>.filled(32, 3)),
  x25519Priv: base64Encode(List<int>.filled(32, 4)),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('licenseTokenMinterProvider returns null when keychain empty', () async {
    final container = ProviderContainer(
      overrides: [
        keychainDeviceStoreProvider.overrideWithValue(
          KeychainDeviceStore(storage: _MemStorage()),
        ),
        licenseApiUrlProvider.overrideWithValue('https://api.antgrid.test'),
      ],
    );
    addTearDown(container.dispose);
    final minter = await container.read(licenseTokenMinterProvider.future);
    expect(minter, isNull);
  });

  test(
    'licenseTokenMinterProvider returns a minter when keychain has record',
    () async {
      final storage = _MemStorage();
      final store = KeychainDeviceStore(storage: storage);
      await store.write(
        DeviceRecord(
          userId: 'u1',
          deviceUuid: 'd1',
          clientId: 'cid',
          clientSecret: 'csec',
          ed25519Pub: 'ep',
          ed25519Priv: 'epp',
          x25519Pub: 'xp',
          x25519Priv: 'xpp',
        ),
      );
      final container = ProviderContainer(
        overrides: [
          keychainDeviceStoreProvider.overrideWithValue(store),
          licenseApiUrlProvider.overrideWithValue('https://api.antgrid.test'),
        ],
      );
      addTearDown(container.dispose);
      final minter = await container.read(licenseTokenMinterProvider.future);
      expect(minter, isNotNull);
      expect(minter!.clientId, 'cid');
      expect(minter.licenseApiUrl, 'https://api.antgrid.test');
    },
  );

  // The wiring under test: the token a remote-control socket presents must come
  // from the CONNECTION-scoped minter (the record the socket authenticates as),
  // never the main-record one above. The relay does not bind the app token's
  // `deviceUuid`/`pk` to the hello, but it DOES check revocation against
  // `claims.deviceUuid` — so one minter shared across two device records
  // silently widens revoking either into revoking both.
  //
  // Driving the real `RelayMechanisms.mintToken` closure is the only way to see
  // which provider it reads: the two minters below return distinguishable
  // tokens. (This assertion previously rode `PairingService.tokenProvider`,
  // deleted in Task 10 — same guarantee, re-anchored on the surviving carrier:
  // the mechanisms the transport builder hands the connection.)
  test('the connection mints from the CONNECTION-scoped minter', () async {
    LicenseTokenMinter minterYielding(String prefix, void Function() onMint) {
      var n = 0;
      return LicenseTokenMinter(
        licenseApiUrl: 'https://api.antgrid.test',
        clientId: 'cid',
        clientSecret: 'csec',
        httpClient: MockClient((req) async {
          n++;
          onMint();
          return http.Response(
            jsonEncode({'access_token': '$prefix-$n', 'expires_in': 3600}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
    }

    var connectionMints = 0;
    var mainRecordMints = 0;
    final connectionMinter = minterYielding('CONN', () => connectionMints++);
    final mainMinter = minterYielding('MAIN', () => mainRecordMints++);

    useInMemoryPrefs();
    final recentStore = await RecentAgentsStore.open();
    addTearDown(recentStore.close);
    final now = DateTime.now();
    await recentStore.upsert(
      RecentAgent(
        agentDeviceId: 'M',
        agentLabel: 'M',
        agentEd25519Pubkey: base64Encode(List<int>.filled(32, 7)),
        relayUrl: 'wss://relay.example/ws',
        pairedAt: now,
        lastConnectedAt: now,
      ),
    );

    final conn = _CapturingConnection();
    addTearDown(conn.dispose);

    final container = ProviderContainer(
      overrides: [
        keychainDeviceStoreProvider.overrideWithValue(
          KeychainDeviceStore(storage: _MemStorage()),
        ),
        licenseApiUrlProvider.overrideWithValue('https://api.antgrid.test'),
        connectionTokenMinterProvider.overrideWith(
          (ref) async => connectionMinter,
        ),
        licenseTokenMinterProvider.overrideWith((ref) async => mainMinter),
        recentAgentsStoreProvider.overrideWithValue(recentStore),
        // The record the socket authenticates AS — a different deviceUuid from the
        // main record, so a mix-up is a different DEVICE IDENTITY, not just a
        // different object.
        connectionDeviceRecordProvider.overrideWith(
          (_) async => _record('controller-uuid'),
        ),
        accountAgentsProvider.overrideWith(
          (_) async => const <InventoryAgent>[],
        ),
        relayConnectionManagerProvider.overrideWithValue(
          _CapturingManager(conn),
        ),
      ],
    );
    addTearDown(container.dispose);

    // The builder throws once it reaches `awaitSession` (this connection never
    // starts a supervisor), which is fine — the mechanisms are captured before
    // then. Listen so the rejection lands on a subscriber, not unhandled.
    final sub = container.listen(
      agentTransportForProvider('M'),
      (_, _) {},
      onError: (_, _) {},
    );
    addTearDown(sub.close);
    final mech = await conn.firstMechanisms.timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw TestFailure('the relay path must have been built'),
    );

    expect(await mech.mintToken(), 'CONN-1');
    expect(connectionMints, 1);
    expect(mainRecordMints, 0, reason: 'the MAIN record must not be used');

    // Fresh per attempt, never a cached token: one minted before a long backoff
    // is already expired by the time its dial runs.
    expect(await mech.mintToken(), 'CONN-2');
    expect(connectionMints, 2);
    expect(mainRecordMints, 0);
  }, timeout: const Timeout(Duration(seconds: 30)));
}
