import '../helpers/test_license_token_minter.dart';
import '../helpers/fixed_peer_connector.dart';
import '../helpers/test_peer_runtime.dart';
// Task 9 cutover: the remote transport connects and authenticates the CENTRAL
// relay hello AS the app's own `kind:"app"` DeviceRecord on every resolve path.
//
// The native peer hello carries no crypto of its own since Stage B: QUIC/TLS
// between lease-authorized Iroh endpoints is the confidentiality layer, so a
// plaintext `session:hello {attemptId, capabilities}` replaces the old
// transcript-signed `handshake:client-hello` — there is no signature left to
// rebuild or verify here.
//
// "No resolve path sends a pair-request" is no longer asserted here because it
// is no longer assertable: Task 10 deleted `RelayService.requestPair`, so the
// compiler enforces it.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:antgrid/connection/connection_supervisor.dart';
import 'package:antgrid/connection/peer_connection.dart';
import 'package:antgrid/providers/account_agents.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/peer_runtime.dart';
import 'package:antgrid/providers/connection_identity.dart';
import 'package:antgrid/providers/device_provisioning.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/relay_connection.dart';
import 'package:antgrid/services/account_agents_api.dart';
import 'package:antgrid/services/keychain_device_store.dart';
import 'package:antgrid/storage/recent_agents_store.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';
import '../helpers/test_store_overrides.dart';

const _machine = 'machine-uuid';
const _agentPubB64 = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';

/// Records what the transport actually put on the wire. `connect` authenticates
/// instantly and announces the agent as present, which is what lets the
/// supervisor climb all the way to the E2E-handshake rung.
class _RecordingRelay extends RelayService implements PeerLink {
  @override
  bool get isDispatchAllowed => true;
  @override
  Stream<PeerLinkState> get payloadStateStream => const Stream.empty();
  @override
  Stream<PeerPath> get pathStream => const Stream.empty();
  @override
  Stream<PeerLinkFailure> get failureStream => const Stream.empty();
  _RecordingRelay() : super(crypto: CryptoService());

  final _states = StreamController<AppState>.broadcast();
  final _presence = StreamController<bool>.broadcast();
  final sent = <Uint8List>[];
  DeviceIdentity? connectedAs;
  String? connectedMachineId;
  AppState _cur = const AppState();

  @override
  Stream<IncomingSessionRecord> get messageStream => const Stream.empty();
  @override
  Stream<AppState> get stateStream => _states.stream;
  @override
  Stream<bool> get peerPresenceStream => _presence.stream;
  @override
  Stream<ErrorMessage> get errorStream => const Stream.empty();
  @override
  AppState get currentState => _cur;

  @override
  Future<void> connect(
    String relayUrl,
    DeviceIdentity identity, {
    required String licenseToken,
    required int epoch,
    String? machineDeviceId,
  }) async {
    connectedAs = identity;
    connectedMachineId = machineDeviceId;
    _cur = const AppState(connectionState: RelayConnectionState.authenticated);
    _states.add(_cur);
    // The relay announces same-account peers right after `welcome`.
    _presence.add(true);
  }

  @override
  void disconnect() {
    _cur = const AppState();
    _states.add(_cur);
  }

  @override
  Future<PeerSendOutcome> sendRecord(Uint8List payload) async {
    if (!isDispatchAllowed) return PeerSendOutcome.closed;
    sent.add(payload);
    return PeerSendOutcome.accepted;
  }

  @override
  Future<PeerStream> openStream(
    StreamOpen open, {
    required int maxRecordBytes,
    required int maxQueuedBytes,
    int? rawAfterRecords,
  }) => throw UnimplementedError('not exercised by this suite');

  @override
  void dispose() {
    unawaited(_states.close());
    unawaited(_presence.close());
  }

  /// The decoded `session:hello` records sent, in order.
  List<Map<String, dynamic>> helloFrames() => [
    for (final payload in sent)
      jsonDecode(utf8.decode(payload)) as Map<String, dynamic>,
  ].where((m) => m['type'] == kSessionHello).toList();
}

class _FakeConnectionManager extends MachineConnectionManager {
  _FakeConnectionManager(this._relay) : super(crypto: CryptoService());

  final RelayService _relay;
  final Map<String, MachineConnection> _conns = {};

  @override
  MachineConnection connectionFor(String machineDeviceId) => _conns.putIfAbsent(
    machineDeviceId,
    () => MachineConnection(
      machineDeviceId: machineDeviceId,
      crypto: CryptoService(),
      relayOverride: _relay,
    ),
  );

  @override
  MachineConnection? peek(String machineDeviceId) => _conns[machineDeviceId];
}

Future<DeviceRecord> _connectionRecord() async {
  final seed = List<int>.generate(32, (i) => (i * 7 + 3) % 256);
  final kp = await Ed25519().newKeyPairFromSeed(seed);
  final pub = await kp.extractPublicKey();
  return DeviceRecord(
    userId: 'u-1',
    deviceUuid: 'controller-device-uuid',
    clientId: 'cid',
    clientSecret: 'csec',
    ed25519Pub: base64Encode(pub.bytes),
    ed25519Priv: base64Encode(seed),
    x25519Pub: base64Encode(List<int>.filled(32, 5)),
    x25519Priv: base64Encode(List<int>.filled(32, 6)),
  );
}

RecentAgent _recent(String id) {
  final now = DateTime.now();
  return RecentAgent(
    agentDeviceId: id,
    agentLabel: id,
    agentEd25519Pubkey: _agentPubB64,
    relayUrl: 'wss://relay.example/ws',
    pairedAt: now,
    lastConnectedAt: now,
  );
}

InventoryAgent _inventory(String id) => InventoryAgent(
  deviceUuid: id,
  displayName: 'Remote',
  platform: 'linux',
  ed25519Pub: _agentPubB64,
  relayUrl: 'wss://relay.example/ws',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestStoreOverrides stores;
  late _RecordingRelay relay;
  late DeviceRecord record;

  setUp(() async {
    useInMemoryPrefs();
    stores = await buildTestStoreOverrides();
    relay = _RecordingRelay();
    record = await _connectionRecord();
  });

  tearDown(() async => stores.close());

  List<Override> overrides({
    List<InventoryAgent> inventory = const [],
    _RecordingRelay? on,
  }) => [
    ...stores.overrides,
    // These fixtures isolate coordinates and E2E identity from HTTP enrollment.
    peerRuntimeProvider.overrideWith((ref) async {
      final runtime = TestPeerRuntime(payloadLink: on ?? relay);
      ref.onDispose(runtime.dispose);
      return runtime;
    }),
    accountAgentsProvider.overrideWith((_) async => inventory),
    localDeviceUuidProvider.overrideWith((_) async => 'this-device'),
    connectionDeviceRecordProvider.overrideWith((_) async => record),
    connectionTokenMinterProvider.overrideWith(
      (_) async => TestLicenseTokenMinter(),
    ),
    cryptoServiceProvider.overrideWith((_) => CryptoService()),
    relayConnectionManagerProvider.overrideWithValue(
      _FakeConnectionManager(on ?? relay),
    ),
  ];

  Future<void> pump(ProviderContainer c, bool Function() until) async {
    for (var i = 0; i < 200 && !until(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('the remote transport connects on the relay slot and sends a plaintext '
      'session:hello, never a signed transcript', () async {
    await stores.recentAgentsStore.upsert(_recent(_machine));
    final c = ProviderContainer(overrides: overrides());
    addTearDown(c.dispose);
    await c.read(accountAgentsProvider.future);

    // The bridge fake never answers `established`, so don't await the
    // transport — only the hello it sent is under test.
    c.read(agentTransportForProvider(_machine));
    await pump(c, () => relay.helloFrames().isNotEmpty);

    expect(
      relay.connectedAs?.deviceId,
      relaySlotId(record.deviceUuid, _machine),
      reason:
          'the relay hello authenticates on this MACHINE\'S slot, so a second '
          'machine dialled at the same time cannot supersede it',
    );
    expect(
      baseSlotDeviceId(relay.connectedAs!.deviceId),
      record.deviceUuid,
      reason: 'the slot still resolves back to the connection DeviceRecord',
    );
    expect(relay.connectedMachineId, _machine);

    // QUIC/TLS between lease-authorized endpoints is the confidentiality layer
    // now, so the native hello carries only a type and an attemptId — no
    // capabilities, no transcript, no signature, nothing naming the
    // connection DeviceRecord at all.
    final hello = relay.helloFrames().single;
    expect(hello['attemptId'], isA<String>());
    expect(hello, {'type': 'session:hello', 'attemptId': hello['attemptId']});
  }, timeout: const Timeout(Duration(seconds: 30)));

  test(
    'every resolve path (paired-recent, recent-only, inventory-only) dials and '
    'reaches the E2E handshake',
    () async {
      // paired + recent
      await stores.recentAgentsStore.upsert(_recent(_machine));
      final withPaired = ProviderContainer(
        overrides: overrides(inventory: [_inventory(_machine)]),
      );
      addTearDown(withPaired.dispose);
      await withPaired.read(accountAgentsProvider.future);
      withPaired.read(agentTransportForProvider(_machine));
      await pump(withPaired, () => relay.helloFrames().isNotEmpty);
      expect(relay.helloFrames(), isNotEmpty, reason: 'recent + inventory');

      // recent only (no inventory row)
      final relay2 = _RecordingRelay();
      final recentOnly = ProviderContainer(overrides: overrides(on: relay2));
      addTearDown(recentOnly.dispose);
      await recentOnly.read(accountAgentsProvider.future);
      recentOnly.read(agentTransportForProvider(_machine));
      await pump(recentOnly, () => relay2.helloFrames().isNotEmpty);
      expect(
        relay2.helloFrames(),
        isNotEmpty,
        reason: 'recent-only dialled',
      );

      // inventory only (a machine we hold no RecentAgent for)
      final relay3 = _RecordingRelay();
      final invOnly = ProviderContainer(
        overrides: overrides(
          inventory: [_inventory('other-machine')],
          on: relay3,
        ),
      );
      addTearDown(invOnly.dispose);
      await invOnly.read(accountAgentsProvider.future);
      invOnly.read(agentTransportForProvider('other-machine'));
      await pump(invOnly, () => relay3.helloFrames().isNotEmpty);
      expect(relay3.helloFrames(), isNotEmpty, reason: 'inventory dialled');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test('native readiness remains independent of central presence', () async {
    const coords = ConnCoords(
      relayUrl: 'wss://relay.example/ws',
      agentEd25519PubB64: _agentPubB64,
    );
    final mech = PeerConnectionMechanisms(
      peerRuntime: FixedPeerConnector(relay),
      machineDeviceId: _machine,
      resolveCoords: () async => coords,
    );
    addTearDown(mech.release);

    expect(mech.payloadConnected, isFalse, reason: 'nothing dialled yet');

    await mech.connectPayload(coords);
    expect(mech.payloadConnected, isTrue);
  });
}
