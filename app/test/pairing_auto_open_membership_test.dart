import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';

import 'package:antgrid/services/account_agents_api.dart';
import 'package:antgrid/services/keychain_device_store.dart';
import 'package:antgrid/services/pairing_service.dart';
import 'package:antgrid/services/phone_identity.dart';
import 'package:antgrid/storage/recent_agents_store.dart';
import 'helpers/fake_device_store.dart';
import 'helpers/prefs_test_mock.dart';

// ---------------------------------------------------------------------------
// Fake RelayService — captures the emitted pair-request args.
// ---------------------------------------------------------------------------
class _FakeRelayService extends RelayService {
  _FakeRelayService() : super(crypto: CryptoService());

  Map<String, dynamic>? capturedRequest;

  final _stateCtrl = StreamController<AppState>.broadcast();
  final _approvalCtrl = StreamController<PairApprovalMessage>.broadcast();
  final _rejectedCtrl = StreamController<PairRejectedMessage>.broadcast();

  AppState _state = const AppState();

  @override
  AppState get currentState => _state;

  @override
  Stream<AppState> get stateStream => _stateCtrl.stream;

  @override
  Stream<PairApprovalMessage> get pairApprovalStream => _approvalCtrl.stream;

  @override
  Stream<PairRejectedMessage> get pairRejectedStream => _rejectedCtrl.stream;

  @override
  Future<void> connect(
    String relayUrl,
    DeviceIdentity identity, {
    required String licenseToken,
    required int epoch,
  }) async {
    _state = const AppState(connectionState: RelayConnectionState.connecting);
    // ignore: unawaited_futures
    Future<void>.delayed(Duration.zero, () {
      _state = const AppState(
        connectionState: RelayConnectionState.authenticated,
      );
      _stateCtrl.add(_state);
    });
  }

  @override
  void requestPair({
    required String agentDeviceId,
    required String phonePubkey,
    required String phoneDeviceId,
    required String nonce,
    required String requestedAt,
    required int deadline,
    required String phoneSignature,
    String? pairCode,
    String? label,
    String? accountDevicePubkey,
    String? accountMembershipSig,
  }) {
    capturedRequest = {
      'agentDeviceId': agentDeviceId,
      'phonePubkey': phonePubkey,
      'phoneDeviceId': phoneDeviceId,
      'nonce': nonce,
      'requestedAt': requestedAt,
      'phoneSignature': phoneSignature,
      'pairCode': pairCode,
      'label': label,
      'accountDevicePubkey': accountDevicePubkey,
      'accountMembershipSig': accountMembershipSig,
    };
  }

  void pushApproval(PairApprovalMessage msg) => _approvalCtrl.add(msg);

  @override
  void disconnect() {}

  @override
  void unpair() {}

  @override
  Future<void> dispose() async {
    await _stateCtrl.close();
    await _approvalCtrl.close();
    await _rejectedCtrl.close();
  }
}

DeviceIdentity _fakeIdentity({String deviceId = 'phone-device-1'}) {
  return DeviceIdentity(
    deviceId: deviceId,
    name: 'Test Phone',
    ed25519PrivateKey: Uint8List(32),
    ed25519PublicKey: Uint8List(32),
    x25519PrivateKey: Uint8List(32),
    x25519PublicKey: Uint8List(32),
  );
}

/// Provisioned account device fixture: a real Ed25519 keypair whose 32-byte
/// seed (base64) is stored as `ed25519Priv` and pubkey (base64) as `ed25519Pub`
/// so signatures produced by autoOpen verify against [pub]/[pubB64].
class _AccountDevice {
  _AccountDevice(this.store, this.pub, this.pubB64);
  final KeychainDeviceStore store;
  final SimplePublicKey pub;
  final String pubB64;
}

Future<_AccountDevice> _makeAccountDevice() async {
  final seed = List<int>.generate(32, (i) => (i * 7 + 3) % 256);
  final deviceKp = await Ed25519().newKeyPairFromSeed(seed);
  final devicePub = await deviceKp.extractPublicKey();
  final devicePubB64 = base64Encode(devicePub.bytes);
  final devicePrivB64 = base64Encode(seed);

  final deviceRecord = DeviceRecord(
    userId: 'user-1',
    deviceUuid: 'account-device-1',
    clientId: 'client-1',
    clientSecret: 'secret-1',
    ed25519Pub: devicePubB64,
    ed25519Priv: devicePrivB64,
    x25519Pub: base64Encode(Uint8List(32)),
    x25519Priv: base64Encode(Uint8List(32)),
  );
  final store = KeychainDeviceStore(
    storage: InMemoryDeviceSecretStorage(jsonEncode(deviceRecord.toJson())),
  );
  return _AccountDevice(store, devicePub, devicePubB64);
}

InventoryAgent _makeAgent({
  required String deviceUuid,
  required String ed25519PubB64,
}) => InventoryAgent(
  deviceUuid: deviceUuid,
  displayName: 'My Dev Machine',
  platform: 'macos',
  ed25519Pub: ed25519PubB64,
  relayUrl: 'wss://relay.test',
);

/// Drives the pair-approval response: waits for the captured pair-request, then
/// signs an approval (with [agentKp]) over [signedId] as the `agentDeviceId`
/// and pushes it onto the fake relay. Pass the bare deviceUuid for the happy
/// path or a compound id to exercise the verify-failure path.
Future<void> _driveApproval(
  _FakeRelayService relay, {
  required SimpleKeyPair agentKp,
  required String signedId,
}) async {
  while (relay.capturedRequest == null) {
    await Future<void>.delayed(Duration.zero);
  }
  final req = relay.capturedRequest!;
  final nonce = req['nonce'] as String;
  final phonePubkey = req['phonePubkey'] as String;
  final phoneDeviceId = req['phoneDeviceId'] as String;

  final expiresAt = DateTime.now()
      .add(const Duration(hours: 24))
      .toUtc()
      .toIso8601String();

  const domain = 'antgrid.pair-approval.v1';
  final builder = BytesBuilder();
  builder.add(utf8.encode(domain));
  builder.addByte(0);
  builder.add(utf8.encode(signedId));
  builder.addByte(0);
  builder.add(base64.decode(phonePubkey));
  builder.addByte(0);
  builder.add(utf8.encode(phoneDeviceId));
  builder.addByte(0);
  builder.add(base64.decode(nonce));
  builder.addByte(0);
  builder.add(utf8.encode(expiresAt));
  final body = Uint8List.fromList(builder.toBytes());
  final sig = await Ed25519().sign(body, keyPair: agentKp);

  relay.pushApproval(
    PairApprovalMessage(
      pairId: 'test-pair-id',
      phonePubkey: phonePubkey,
      phoneDeviceId: phoneDeviceId,
      nonce: nonce,
      expiresAt: DateTime.parse(expiresAt),
      signature: base64Encode(sig.bytes),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    useInMemoryPrefs();
  });

  test(
    'autoOpen signs an account-membership proof that verifies under the device key',
    () async {
      final fakeRelay = _FakeRelayService();
      addTearDown(fakeRelay.dispose);
      final store = await RecentAgentsStore.open();
      final identity = _fakeIdentity();

      // Phase B: trust identity is the BARE `deviceUuid` from the account
      // inventory (`GET /account/agents`, keyed by deviceUuid). The agent signs
      // its pair-approval over this bare id; autoOpen must feed the bare value
      // into verifyPairApproval.
      const agentDeviceId = 'agent-uuid-1';

      final agentKp = await Ed25519().newKeyPair();
      final agentPubB64 = base64Encode(
        (await agentKp.extractPublicKey()).bytes,
      );

      final device = await _makeAccountDevice();
      final agent = _makeAgent(
        deviceUuid: agentDeviceId,
        ed25519PubB64: agentPubB64,
      );

      final svc = PairingService(
        relay: fakeRelay,
        phoneIdentity: PhoneIdentity.inMemory(),
        recentAgentsStore: store,
        deviceStore: device.store,
        // Control-plane / single-project pairing: registrationId == bare uuid.
        registrationId: agentDeviceId,
        random: Random(42),
      );

      // Sign the approval over the BARE deviceUuid — the value autoOpen must
      // feed to the verifier.
      final approvalDriver = _driveApproval(
        fakeRelay,
        agentKp: agentKp,
        signedId: agentDeviceId,
      );

      final raFuture = svc.autoOpen(agent, identity);
      await approvalDriver;
      await raFuture;

      final req = fakeRelay.capturedRequest!;

      // 0. The pair-request was routed/signed under the BARE deviceUuid.
      expect(req['agentDeviceId'], equals(agentDeviceId));

      // 1. accountDevicePubkey == stored DeviceRecord.ed25519Pub.
      expect(req['accountDevicePubkey'], equals(device.pubB64));

      // 2. accountMembershipSig is non-empty.
      final membershipSig = req['accountMembershipSig'] as String?;
      expect(membershipSig, isNotNull);
      expect(membershipSig!.isNotEmpty, isTrue);

      // 3. The sig VERIFIES under the device pubkey, over the canonical body.
      final body = buildMembershipSigBody(
        agentDeviceId: agentDeviceId,
        phoneDeviceId: req['phoneDeviceId'] as String,
        phonePubkey: req['phonePubkey'] as String,
        accountDevicePubkey: device.pubB64,
        nonce: req['nonce'] as String,
      );
      final ok = await Ed25519().verify(
        body,
        signature: Signature(
          base64.decode(membershipSig),
          publicKey: device.pub,
        ),
      );
      expect(ok, isTrue, reason: 'membership sig must verify under device key');

      await store.close();
    },
  );

  test('autoOpen throws when no provisioned account device exists', () async {
    final fakeRelay = _FakeRelayService();
    addTearDown(fakeRelay.dispose);
    final store = await RecentAgentsStore.open();
    final deviceStore = KeychainDeviceStore(
      storage: InMemoryDeviceSecretStorage(null),
    );

    final agent = InventoryAgent(
      deviceUuid: 'agent-x.proj-hash',
      displayName: 'X',
      platform: 'linux',
      ed25519Pub: base64Encode(Uint8List(32)),
      relayUrl: 'wss://relay.test',
    );

    final svc = PairingService(
      relay: fakeRelay,
      phoneIdentity: PhoneIdentity.inMemory(),
      recentAgentsStore: store,
      deviceStore: deviceStore,
      registrationId: 'agent-x.proj-hash',
    );

    await expectLater(
      svc.autoOpen(agent, _fakeIdentity()),
      throwsA(isA<PairException>()),
    );

    await store.close();
  });

  test(
    'autoOpen rejects an approval signed over the COMPOUND id (bare is load-bearing)',
    () async {
      // Phase B negative: prove the BARE deviceUuid is the value autoOpen feeds
      // into verifyPairApproval. If the agent (wrongly) signed over a compound
      // `<deviceUuid>.<projectId>`, the signature must NOT verify and autoOpen
      // must fail with an invalid-signature PairException.
      final fakeRelay = _FakeRelayService();
      addTearDown(fakeRelay.dispose);
      final store = await RecentAgentsStore.open();
      final identity = _fakeIdentity();

      const bareDeviceUuid = 'agent-uuid-1';
      const compoundId = 'agent-uuid-1.proj-hash';

      final agentKp = await Ed25519().newKeyPair();
      final agentPubB64 = base64Encode(
        (await agentKp.extractPublicKey()).bytes,
      );

      final device = await _makeAccountDevice();
      final agent = _makeAgent(
        deviceUuid: bareDeviceUuid,
        ed25519PubB64: agentPubB64,
      );

      final svc = PairingService(
        relay: fakeRelay,
        phoneIdentity: PhoneIdentity.inMemory(),
        recentAgentsStore: store,
        deviceStore: device.store,
        // The service verifies the approval over `registrationId` (bare uuid
        // here); an approval signed over the compound id must NOT verify.
        registrationId: bareDeviceUuid,
        random: Random(42),
      );

      // Sign the approval over the COMPOUND id — the wrong value.
      final approvalDriver = _driveApproval(
        fakeRelay,
        agentKp: agentKp,
        signedId: compoundId,
      );

      final raFuture = svc.autoOpen(agent, identity);
      await approvalDriver;

      await expectLater(
        raFuture,
        throwsA(
          isA<PairException>().having(
            (e) => e.message,
            'message',
            contains('signature invalid'),
          ),
        ),
      );

      await store.close();
    },
  );
}
