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

/// A fake relay that drives `connect` → `authenticated`, captures the
/// pair-request, and lets the test push an arbitrary later [AppState] (e.g. the
/// bare `disconnected` the relay emits after `ws.close(1008,"AGENT_OFFLINE")`)
/// WITHOUT ever delivering an approval — reproducing the project-slot
/// registration race a phone hits on drill-in.
class _OfflineFakeRelay extends RelayService {
  _OfflineFakeRelay() : super(crypto: CryptoService());

  Map<String, dynamic>? lastRequest;

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
    lastRequest = {'phonePubkey': phonePubkey};
  }

  @override
  void disconnect() {}
  @override
  void unpair() {}

  /// Emit a later connection state (the test's stand-in for a relay-initiated
  /// close mid-pairing).
  void pushState(AppState s) {
    _state = s;
    _stateCtrl.add(s);
  }
}

DeviceIdentity _id() => DeviceIdentity(
  deviceId: 'phone-1',
  name: 'Test Phone',
  ed25519PrivateKey: Uint8List(32),
  ed25519PublicKey: Uint8List(32),
  x25519PrivateKey: Uint8List(32),
  x25519PublicKey: Uint8List(32),
);

Future<RecentAgent> _recent(PhoneIdentity phoneId) async {
  final kp = await phoneId.ensureKeypair('M');
  final agentKp = await Ed25519().newKeyPair();
  final agentPubB64 = base64Encode((await agentKp.extractPublicKey()).bytes);
  final now = DateTime.now();
  return RecentAgent(
    agentDeviceId: 'M',
    agentLabel: 'Test Agent',
    agentEd25519Pubkey: agentPubB64,
    relayUrl: 'wss://relay.test',
    phoneDeviceId: 'phone-1',
    phoneEd25519Pubkey: kp.pubkeyB64,
    pairedAt: now,
    lastConnectedAt: now,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => useInMemoryPrefs());

  test(
    'a bare relay close mid-pairing fails fast as a retryable AGENT_OFFLINE '
    'PairException (not a 30s timeout)',
    () async {
      final relay = _OfflineFakeRelay();
      final store = await RecentAgentsStore.open();
      final phoneId = PhoneIdentity.inMemory();
      final ra = await _recent(phoneId);

      final svc = PairingService(
        relay: relay,
        phoneIdentity: phoneId,
        recentAgentsStore: store,
        registrationId: 'M.p1',
      );

      final sw = Stopwatch()..start();
      final fut = svc.reconnect(ra, _id());

      // Wait until the pair-request is out, then simulate the relay closing the
      // socket with no readable error code (the AGENT_OFFLINE bare close).
      while (relay.lastRequest == null) {
        await Future<void>.delayed(Duration.zero);
      }
      relay.pushState(
        const AppState(connectionState: RelayConnectionState.disconnected),
      );

      await expectLater(
        fut,
        throwsA(
          isA<PairException>().having((e) => e.agentOffline, 'agentOffline', isTrue),
        ),
      );
      sw.stop();
      // The whole point: it must NOT wait out the 30s approval timeout.
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));

      await store.close();
    },
  );

  test(
    'a terminal license close mid-pairing is non-retryable (surfaces the code)',
    () async {
      final relay = _OfflineFakeRelay();
      final store = await RecentAgentsStore.open();
      final phoneId = PhoneIdentity.inMemory();
      final ra = await _recent(phoneId);

      final svc = PairingService(
        relay: relay,
        phoneIdentity: phoneId,
        recentAgentsStore: store,
        registrationId: 'M.p1',
      );

      final fut = svc.reconnect(ra, _id());
      while (relay.lastRequest == null) {
        await Future<void>.delayed(Duration.zero);
      }
      relay.pushState(
        const AppState(
          connectionState: RelayConnectionState.disconnected,
          errorCode: 'LICENSE_INVALID',
        ),
      );

      await expectLater(
        fut,
        throwsA(
          isA<PairException>()
              .having((e) => e.agentOffline, 'agentOffline', isFalse)
              .having((e) => e.message, 'message', contains('LICENSE_INVALID')),
        ),
      );

      await store.close();
    },
  );
}
