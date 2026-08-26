// Task 9 cutover: the remote transport connects and signs AS the app's own
// `kind:"app"` DeviceRecord on every resolve path.
//
// The signing assertion is made against the real handshake bytes: the transcript
// carries the phone device id and is signed with the phone's Ed25519 seed, so
// rebuilding it from the emitted `handshake:client-hello` and verifying it under
// the record's public key proves BOTH halves at once — a hello signed with any
// other key would neither carry the record's deviceUuid nor verify under its.
//
// "No resolve path sends a pair-request" is no longer asserted here because it
// is no longer assertable: Task 10 deleted `RelayService.requestPair`, so the
// compiler enforces it.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:antgrid/connection/connection_supervisor.dart';
import 'package:antgrid/connection/relay_mechanisms.dart';
import 'package:antgrid/providers/account_agents.dart';
import 'package:antgrid/providers/agent_transport.dart';
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
class _RecordingRelay extends RelayService {
  _RecordingRelay() : super(crypto: CryptoService());

  final _states = StreamController<AppState>.broadcast();
  final _presence = StreamController<bool>.broadcast();
  final sent = <({String channel, Uint8List payload, FrameKind kind})>[];
  DeviceIdentity? connectedAs;
  String? connectedMachineId;
  AppState _cur = const AppState();

  @override
  Stream<IncomingRouteMessage> get messageStream => const Stream.empty();
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
  void sendMessage(
    String to,
    String channel,
    Uint8List payload, {
    FrameKind kind = FrameKind.sealed,
  }) {
    sent.add((channel: channel, payload: payload, kind: kind));
  }

  @override
  void dispose() {
    unawaited(_states.close());
    unawaited(_presence.close());
  }

  /// The decoded kind-1 handshake frames, in order.
  List<Map<String, dynamic>> handshakeFrames() => [
    for (final f in sent)
      if (f.kind == FrameKind.handshake)
        jsonDecode(utf8.decode(f.payload)) as Map<String, dynamic>,
  ];
}

class _FakeConnectionManager extends RelayConnectionManager {
  _FakeConnectionManager(this._relay) : super(crypto: CryptoService());

  final RelayService _relay;
  final Map<String, RelayConnection> _conns = {};

  @override
  RelayConnection connectionFor(String machineDeviceId) => _conns.putIfAbsent(
    machineDeviceId,
    () => RelayConnection(
      machineDeviceId: machineDeviceId,
      crypto: CryptoService(),
      relayOverride: _relay,
    ),
  );

  @override
  RelayConnection? peek(String machineDeviceId) => _conns[machineDeviceId];
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
    accountAgentsProvider.overrideWith((_) async => inventory),
    localDeviceUuidProvider.overrideWith((_) async => 'this-device'),
    connectionDeviceRecordProvider.overrideWith((_) async => record),
    connectionTokenMinterProvider.overrideWith((_) async => null),
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

  test('the remote transport connects and signs the handshake with the '
      'connection DeviceRecord, never PhoneIdentity', () async {
    await stores.recentAgentsStore.upsert(_recent(_machine));
    final c = ProviderContainer(overrides: overrides());
    addTearDown(c.dispose);
    await c.read(accountAgentsProvider.future);

    // The handshake never confirms against this fake, so don't await the
    // transport — only the identity it presented is under test.
    c.read(agentTransportForProvider(_machine));
    await pump(c, () => relay.handshakeFrames().isNotEmpty);

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

    final hello = relay.handshakeFrames().single;
    expect(hello['type'], 'handshake:client-hello');

    // Rebuild the exact bytes the phone signed and verify them under the
    // record's public key. The transcript names the BARE deviceUuid even though
    // the hello above is scoped: it binds the account identity the agent
    // resolves us by, and a transport address there would make one phone sign a
    // different transcript per machine (see docs/protocol/e2e-handshake.md).
    final transcript = buildTranscriptV2(
      TranscriptFields(
        registrationId: _machine,
        role: 'phone',
        agentDeviceId: _machine,
        phoneDeviceId: record.deviceUuid,
        agentX25519Pub: Uint8List(0),
        phoneX25519Pub: base64Decode(hello['pubkey'] as String),
        nonce: base64Decode(hello['nonce'] as String),
      ),
    );
    expect(
      await verifyTranscriptSigV2(
        transcript: transcript,
        ed25519PubB64: record.ed25519Pub,
        sigB64: hello['sig'] as String,
      ),
      isTrue,
      reason:
          'the transcript names the record deviceUuid AND is signed with '
          'its Ed25519 seed',
    );

    // A DIFFERENT account key over the same bytes must NOT verify — otherwise
    // the check above would pass for any signer.
    expect(
      await verifyTranscriptSigV2(
        transcript: transcript,
        ed25519PubB64: _agentPubB64,
        sigB64: hello['sig'] as String,
      ),
      isFalse,
      reason: 'only the connection record may sign the handshake transcript',
    );
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
      await pump(withPaired, () => relay.handshakeFrames().isNotEmpty);
      expect(relay.handshakeFrames(), isNotEmpty, reason: 'recent + inventory');

      // recent only (no inventory row)
      final relay2 = _RecordingRelay();
      final recentOnly = ProviderContainer(overrides: overrides(on: relay2));
      addTearDown(recentOnly.dispose);
      await recentOnly.read(accountAgentsProvider.future);
      recentOnly.read(agentTransportForProvider(_machine));
      await pump(recentOnly, () => relay2.handshakeFrames().isNotEmpty);
      expect(
        relay2.handshakeFrames(),
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
      await pump(invOnly, () => relay3.handshakeFrames().isNotEmpty);
      expect(relay3.handshakeFrames(), isNotEmpty, reason: 'inventory dialled');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'the routable rung is fed by peer presence, not by a paired grant',
    () async {
      const coords = ConnCoords(
        relayUrl: 'wss://relay.example/ws',
        agentEd25519PubB64: _agentPubB64,
      );
      final mech = RelayMechanisms(
        relay: relay,
        crypto: CryptoService(),
        machineDeviceId: _machine,
        identity: connectionIdentityFor(record, machineDeviceId: _machine),
        phoneDeviceId: record.deviceUuid,
        phoneEd25519Seed: base64Decode(record.ed25519Priv),
        epoch: 1,
        resolveCoords: () async => coords,
        mintToken: () async => 'tok',
      );
      addTearDown(mech.release);

      expect(mech.agentOnline, isFalse, reason: 'nothing dialled yet');

      // The socket only ever reaches `authenticated` — there is no grant and no
      // `paired` state to gate on. `RelayMechanisms` doesn't self-subscribe to
      // presence (see `notePresence`'s doc comment); production feeds it from
      // `RelayConnection.ensureStarted`'s `peerPresenceStream` listener, so the
      // fixture reproduces that wiring directly here.
      await mech.dial(coords, 'tok');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        relay.currentState.connectionState,
        RelayConnectionState.authenticated,
      );
      expect(
        mech.socketAuthenticated,
        isTrue,
        reason: 'socket auth alone must not make the peer routable',
      );
      expect(mech.agentOnline, isFalse);

      mech.notePresence(true);
      expect(
        mech.agentOnline,
        isTrue,
        reason: 'peer-online for this machine makes it routable',
      );

      mech.notePresence(false);
      expect(mech.agentOnline, isFalse, reason: 'peer-offline unroutes it');
    },
  );
}
