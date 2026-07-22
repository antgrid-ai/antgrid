// Coverage for PairingService._awaitAndVerifyApproval's typed-error
// classification off RelayService.errorStream — replaces the relevant slice
// of the deleted pairing_service_auto_open_test.dart /
// pairing_service_token_reconnect_test.dart /
// integration/auto_open_token_flow_test.dart (the v3 semantics: matching by
// `ref == nonce`, AGENT_OFFLINE retried on the SAME still-open socket,
// PAIR_REJECTED/EXPIRED surfaced as a terminal PairException, and a
// mandatory epoch/token threaded into `relay.connect`).
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';

import 'package:antgrid/services/pairing_service.dart';
import 'package:antgrid/services/phone_identity.dart';
import 'package:antgrid/storage/recent_agents_store.dart';
import '../helpers/prefs_test_mock.dart';

class _FakeRelay extends RelayService {
  _FakeRelay() : super(crypto: CryptoService());

  final List<Map<String, dynamic>> requests = [];
  int? capturedEpoch;
  String? capturedLicenseToken;

  final _stateCtrl = StreamController<AppState>.broadcast();
  final _approvalCtrl = StreamController<PairApprovalMessage>.broadcast();
  final _rejectedCtrl = StreamController<PairRejectedMessage>.broadcast();
  final _errorCtrl = StreamController<ErrorMessage>.broadcast();
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
  Stream<ErrorMessage> get errorStream => _errorCtrl.stream;

  @override
  Future<void> connect(
    String relayUrl,
    DeviceIdentity identity, {
    required String licenseToken,
    required int epoch,
  }) async {
    capturedEpoch = epoch;
    capturedLicenseToken = licenseToken;
    _state = const AppState(connectionState: RelayConnectionState.connecting);
    unawaited(Future<void>.delayed(Duration.zero, () {
      _state = const AppState(
        connectionState: RelayConnectionState.authenticated,
      );
      _stateCtrl.add(_state);
    }));
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
    requests.add({
      'agentDeviceId': agentDeviceId,
      'phonePubkey': phonePubkey,
      'phoneDeviceId': phoneDeviceId,
      'nonce': nonce,
      'deadline': deadline,
    });
  }

  void pushError(String code, {String? ref, bool retryable = true}) {
    _errorCtrl.add(ErrorMessage(
      code: code,
      message: code,
      retryable: retryable,
      ref: ref,
    ));
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
    await _errorCtrl.close();
  }
}

DeviceIdentity _identity() => DeviceIdentity(
      deviceId: 'phone-1',
      name: 'Test Phone',
      ed25519PrivateKey: Uint8List(32),
      ed25519PublicKey: Uint8List(32),
      x25519PrivateKey: Uint8List(32),
      x25519PublicKey: Uint8List(32),
    );

Future<RecentAgent> _recent(PhoneIdentity phoneId, String machineId) async {
  final kp = await phoneId.ensureKeypair(machineId);
  final agentKp = await Ed25519().newKeyPair();
  final agentPubB64 = base64Encode((await agentKp.extractPublicKey()).bytes);
  final now = DateTime.now();
  return RecentAgent(
    agentDeviceId: machineId,
    agentLabel: 'Test Agent',
    agentEd25519Pubkey: agentPubB64,
    relayUrl: 'wss://relay.test',
    phoneDeviceId: 'phone-1',
    phoneEd25519Pubkey: kp.pubkeyB64,
    pairedAt: now,
    lastConnectedAt: now,
  );
}

/// Signs an approval matching whatever the LATEST captured request asked for.
Future<PairApprovalMessage> _approvalFor(
  Map<String, dynamic> req,
  SimpleKeyPair agentKp,
  String signedAgentDeviceId,
) async {
  final expiresAt =
      DateTime.now().add(const Duration(hours: 1)).toUtc().toIso8601String();
  const domain = 'antgrid.pair-approval.v1';
  final b = BytesBuilder();
  b.add(utf8.encode(domain));
  b.addByte(0);
  b.add(utf8.encode(signedAgentDeviceId));
  b.addByte(0);
  b.add(base64.decode(req['phonePubkey'] as String));
  b.addByte(0);
  b.add(utf8.encode(req['phoneDeviceId'] as String));
  b.addByte(0);
  b.add(base64.decode(req['nonce'] as String));
  b.addByte(0);
  b.add(utf8.encode(expiresAt));
  final sig = await Ed25519().sign(b.toBytes(), keyPair: agentKp);
  return PairApprovalMessage(
    pairId: 'pair-1',
    phonePubkey: req['phonePubkey'] as String,
    phoneDeviceId: req['phoneDeviceId'] as String,
    nonce: req['nonce'] as String,
    expiresAt: DateTime.parse(expiresAt),
    signature: base64Encode(sig.bytes),
  );
}

const _machineId = 'M';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => useInMemoryPrefs());

  test(
    'a pair-request carries the deadline (own timeout) and connect() '
    'receives the mandatory epoch/token',
    () async {
      final relay = _FakeRelay();
      addTearDown(relay.dispose);
      final store = await RecentAgentsStore.open();
      addTearDown(store.close);
      final phoneId = PhoneIdentity.inMemory();
      final ra = await _recent(phoneId, _machineId);

      final svc = PairingService(
        relay: relay,
        phoneIdentity: phoneId,
        recentAgentsStore: store,
        registrationId: _machineId,
        tokenProvider: () async => 'a-license-token',
        epochProvider: () async => 12345,
      );

      final before = DateTime.now().millisecondsSinceEpoch;
      unawaited(svc.reconnect(ra, _identity()).catchError((_) => ra));

      while (relay.requests.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(relay.capturedEpoch, 12345);
      expect(relay.capturedLicenseToken, 'a-license-token');
      final deadline = relay.requests.single['deadline'] as int;
      expect(deadline, greaterThan(before));
      // The pair-request's own ~30s timeout window (design: `_kPairTimeout`).
      expect(deadline - before, closeTo(30000, 2000));
    },
  );

  test(
    'AGENT_OFFLINE (ref == nonce) is retryable — the pair-request is resent '
    'on the SAME socket, and a subsequent approval still completes pairing',
    () async {
      final relay = _FakeRelay();
      addTearDown(relay.dispose);
      final store = await RecentAgentsStore.open();
      addTearDown(store.close);
      final phoneId = PhoneIdentity.inMemory();
      final ra = await _recent(phoneId, _machineId);
      final agentKp = await Ed25519().newKeyPairFromSeed(
        List.filled(32, 5),
      );
      // Re-derive a RecentAgent whose pinned agent pubkey matches agentKp.
      final kp = await phoneId.ensureKeypair(_machineId);
      final raWithKp = RecentAgent(
        agentDeviceId: _machineId,
        agentLabel: 'Test Agent',
        agentEd25519Pubkey:
            base64Encode((await agentKp.extractPublicKey()).bytes),
        relayUrl: ra.relayUrl,
        phoneDeviceId: 'phone-1',
        phoneEd25519Pubkey: kp.pubkeyB64,
        pairedAt: ra.pairedAt,
        lastConnectedAt: ra.lastConnectedAt,
      );

      final svc = PairingService(
        relay: relay,
        phoneIdentity: phoneId,
        recentAgentsStore: store,
        registrationId: _machineId,
      );

      final resultFuture = svc.reconnect(raWithKp, _identity());

      while (relay.requests.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      final nonce = relay.requests.single['nonce'] as String;

      // A ref MISMATCH must be ignored (not ours) — must not disturb pairing.
      relay.pushError('AGENT_OFFLINE', ref: 'some-other-nonce');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(relay.requests, hasLength(1),
          reason: 'an error with a foreign ref must not trigger a resend');

      // The REAL AGENT_OFFLINE for our nonce triggers a resend on the same
      // socket (no reconnect() call — `relay.requests` grows, `connect()` is
      // only ever invoked once for the whole test).
      relay.pushError('AGENT_OFFLINE', ref: nonce);
      for (var i = 0; i < 100 && relay.requests.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(relay.requests, hasLength(2),
          reason: 'AGENT_OFFLINE for our nonce must resend pair-request');

      // Now let the (resent) request succeed.
      final approval =
          await _approvalFor(relay.requests.last, agentKp, _machineId);
      relay.pushApproval(approval);

      final result = await resultFuture.timeout(const Duration(seconds: 5));
      expect(result.agentDeviceId, _machineId);
    },
  );

  test('PAIR_REJECTED (ref == nonce) surfaces as a non-retryable '
      'PairException', () async {
    final relay = _FakeRelay();
    addTearDown(relay.dispose);
    final store = await RecentAgentsStore.open();
    addTearDown(store.close);
    final phoneId = PhoneIdentity.inMemory();
    final ra = await _recent(phoneId, _machineId);

    final svc = PairingService(
      relay: relay,
      phoneIdentity: phoneId,
      recentAgentsStore: store,
      registrationId: _machineId,
    );

    final resultFuture = svc.reconnect(ra, _identity());
    while (relay.requests.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    final nonce = relay.requests.single['nonce'] as String;
    relay.pushError('PAIR_REJECTED', ref: nonce, retryable: false);

    await expectLater(
      resultFuture,
      throwsA(
        isA<PairException>()
            .having((e) => e.agentOffline, 'agentOffline', isFalse)
            .having((e) => e.message, 'message', contains('PAIR_REJECTED')),
      ),
    );
  });

  test(
    'EXPIRED (ref == nonce) surfaces as a PairException — the pair-request '
    'past its own deadline',
    () async {
      final relay = _FakeRelay();
      addTearDown(relay.dispose);
      final store = await RecentAgentsStore.open();
      addTearDown(store.close);
      final phoneId = PhoneIdentity.inMemory();
      final ra = await _recent(phoneId, _machineId);

      final svc = PairingService(
        relay: relay,
        phoneIdentity: phoneId,
        recentAgentsStore: store,
        registrationId: _machineId,
      );

      final resultFuture = svc.reconnect(ra, _identity());
      while (relay.requests.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      final nonce = relay.requests.single['nonce'] as String;
      relay.pushError('EXPIRED', ref: nonce);

      await expectLater(
        resultFuture,
        throwsA(
          isA<PairException>().having(
              (e) => e.message.toLowerCase(), 'message', contains('expired')),
        ),
      );
    },
  );
}
