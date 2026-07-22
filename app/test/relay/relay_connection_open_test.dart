// End-to-end coverage for `RelayConnection.open()` against the REAL v3
// crypto handshake (via a fake agent responder, mirroring
// connection_handshake_test.dart's harness) — replaces the deleted
// test/relay/relay_connection_open_test.dart (pre-v3 `registrationId` API)
// and test/handshake_initiate_test.dart (pre-v3 pull-model open() flow).
//
// Also covers two A6 "provider wiring" claims that are naturally proven at
// this layer, one connection/one handshake for real:
//   - two projects on ONE machine share the ONE MachineSession `open()`
//     produces (no second pairFlow/handshake for the second project).
//   - drill-in binds via `stream-ready` at 0 RTT: once the control plane has
//     advertised a project's streamId, `bindProject` resolves immediately
//     with no new `project:start` send.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:antgrid/providers/relay_connection.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Fakes (same shape as connection_handshake_test.dart's harness, plus a
// settable state stream so a fake PairFlow can drive the relay to `paired`).
// ---------------------------------------------------------------------------

class _RecordingRelay extends RelayService {
  _RecordingRelay() : super(crypto: CryptoService());

  final _messages = StreamController<IncomingRouteMessage>.broadcast();
  final _states = StreamController<AppState>.broadcast();
  final sent = <({Uint8List payload, FrameKind kind})>[];
  AppState _cur = const AppState();
  int unpairCalls = 0;

  @override
  Stream<IncomingRouteMessage> get messageStream => _messages.stream;
  @override
  Stream<AppState> get stateStream => _states.stream;
  @override
  AppState get currentState => _cur;
  @override
  Stream<PairApprovalMessage> get pairApprovalStream => const Stream.empty();
  @override
  Stream<PairRejectedMessage> get pairRejectedStream => const Stream.empty();

  @override
  void unpair() => unpairCalls++;

  @override
  void sendMessage(
    String to,
    String channel,
    Uint8List payload, {
    FrameKind kind = FrameKind.sealed,
  }) {
    if (channel == 'control') sent.add((payload: payload, kind: kind));
  }

  void inject(IncomingRouteMessage msg) => _messages.add(msg);

  void setState(AppState s) {
    _cur = s;
    _states.add(s);
  }

  @override
  void dispose() {
    unawaited(closeStreams());
  }

  Future<void> closeStreams() async {
    if (!_messages.isClosed) await _messages.close();
    if (!_states.isClosed) await _states.close();
  }
}

Future<(List<int> seed, Uint8List pub)> _agentEd25519Keypair() async {
  final seed = List.filled(32, 0xA1);
  final kp = await Ed25519().newKeyPairFromSeed(seed);
  final pub = await kp.extractPublicKey();
  return (seed, Uint8List.fromList(pub.bytes));
}

Future<Map<String, dynamic>> _waitForHandshakeFrame(
  _RecordingRelay relay,
  String type, {
  Duration timeout = const Duration(seconds: 5),
  int startIndex = 0,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('fake agent: "$type" not received');
    }
    for (var i = startIndex; i < relay.sent.length; i++) {
      final f = relay.sent[i];
      if (f.kind != FrameKind.handshake) continue;
      Map<String, dynamic> j;
      try {
        j = jsonDecode(utf8.decode(f.payload)) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      if (j['type'] == type) return j;
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Fully drives the fake-agent side of one handshake attempt to
/// `established`, so the phone's `open()` resolves.
Future<SessionKeys> _completeFakeAgentHandshake(
  _RecordingRelay relay, {
  required List<int> agentSeed,
  required String machineDeviceId,
  required String phoneDeviceId,
  int startIndex = 0,
}) async {
  final clientHello = await _waitForHandshakeFrame(
      relay, 'handshake:client-hello',
      startIndex: startIndex);
  final attemptId = clientHello['attemptId'] as String;
  final phoneX25519Pub = base64.decode(clientHello['pubkey'] as String);
  final nonce = base64.decode(clientHello['nonce'] as String);

  final agentX25519KP = await X25519().newKeyPair();
  final agentX25519Priv =
      Uint8List.fromList(await agentX25519KP.extractPrivateKeyBytes());
  final agentX25519Pub =
      Uint8List.fromList((await agentX25519KP.extractPublicKey()).bytes);

  final agentTranscript = buildTranscriptV2(TranscriptFields(
    registrationId: machineDeviceId,
    role: 'agent',
    agentDeviceId: machineDeviceId,
    phoneDeviceId: phoneDeviceId,
    agentX25519Pub: agentX25519Pub,
    phoneX25519Pub: phoneX25519Pub,
    nonce: nonce,
  ));
  final agentSig =
      await signTranscriptV2(transcript: agentTranscript, ed25519Seed: agentSeed);
  final ss = await x25519SharedSecret(
      privateKey: agentX25519Priv, peerPublicKey: phoneX25519Pub);
  final keys = await deriveSessionKeysV2(ss, agentTranscript);

  relay.inject(IncomingRouteMessage(
    from: machineDeviceId,
    channel: 'control',
    kind: FrameKind.handshake,
    payload: Uint8List.fromList(utf8.encode(jsonEncode({
      'type': 'handshake:agent-hello',
      'attemptId': attemptId,
      'pubkey': base64.encode(agentX25519Pub),
      'sig': agentSig,
    }))),
  ));

  final t = E2eTransportDart(sendKey: keys.a2p, recvKey: keys.p2a);
  relay.inject(IncomingRouteMessage(
    from: machineDeviceId,
    channel: 'control',
    kind: FrameKind.sealed,
    payload: await t.seal(jsonEncode({
      'type': 'handshake:agent-ready',
      'attemptId': attemptId,
      'confirm': base64.encode(await agentConfirmTagV2(keys.confirm)),
    })),
  ));

  // Wait for the resulting sealed app:ready before answering established —
  // matches the real protocol's causal order.
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    var found = false;
    for (final f in relay.sent) {
      if (f.kind != FrameKind.sealed) continue;
      final dec = await t.open(f.payload);
      if (dec == null) continue;
      final j = jsonDecode(dec) as Map<String, dynamic>;
      if (j['type'] == 'app:ready' && j['attemptId'] == attemptId) {
        found = true;
        break;
      }
    }
    if (found) break;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }

  relay.inject(IncomingRouteMessage(
    from: machineDeviceId,
    channel: 'control',
    kind: FrameKind.sealed,
    payload: await t.seal(jsonEncode({
      'type': 'established',
      'attemptId': attemptId,
    })),
  ));

  return keys;
}

const _machineId = 'machine-1';
const _phoneId = 'phone-device-id';

typedef VoidCallback = void Function();

/// Runs `conn.open()` against the fake agent and returns both the resulting
/// session and the derived [SessionKeys], so a caller can seal further
/// control-plane traffic (e.g. a `stream-ready` advert) as the agent would.
Future<(MachineSession, SessionKeys)> _openConnectionWithKeys(
  RelayConnection conn, {
  required List<int> agentSeed,
  required Uint8List agentPub,
  required VoidCallback onPairFlowCalled,
}) async {
  final relay = conn.relay as _RecordingRelay;
  final agentFuture = _completeFakeAgentHandshake(
    relay,
    agentSeed: agentSeed,
    machineDeviceId: _machineId,
    phoneDeviceId: _phoneId,
  );
  final session = await conn.open(
    pairFlow: () async {
      onPairFlowCalled();
      relay.setState(
        const AppState(connectionState: RelayConnectionState.paired),
      );
    },
    crypto: CryptoService(),
    phoneDeviceId: _phoneId,
    agentEd25519PubB64: base64.encode(agentPub),
    phoneEd25519Seed: List<int>.filled(32, 3),
  );
  final keys = await agentFuture;
  return (session, keys);
}

Future<MachineSession> _openConnection(
  RelayConnection conn, {
  required List<int> agentSeed,
  required Uint8List agentPub,
  required VoidCallback onPairFlowCalled,
}) async {
  final (session, _) = await _openConnectionWithKeys(
    conn,
    agentSeed: agentSeed,
    agentPub: agentPub,
    onPairFlowCalled: onPairFlowCalled,
  );
  return session;
}

void main() {
  late _RecordingRelay relay;
  late List<int> agentSeed;
  late Uint8List agentPub;

  setUp(() async {
    relay = _RecordingRelay();
    final (seed, pub) = await _agentEd25519Keypair();
    agentSeed = seed;
    agentPub = pub;
  });

  tearDown(() async {
    await relay.closeStreams();
  });

  test('open() drives connect → pair → E2E handshake and resolves a usable '
      'MachineSession', () async {
    final conn = RelayConnection(
      machineDeviceId: _machineId,
      crypto: CryptoService(),
      relayOverride: relay,
    );
    addTearDown(conn.dispose);

    var pairFlowCalls = 0;
    final session = await _openConnection(
      conn,
      agentSeed: agentSeed,
      agentPub: agentPub,
      onPairFlowCalled: () => pairFlowCalls++,
    );

    expect(pairFlowCalls, 1);
    expect(session.isEstablished, isTrue);
    expect(conn.session, same(session));
  });

  test(
    'two projects on the SAME machine share the ONE MachineSession — a '
    'second open() call reuses the cached connection with no second '
    'pairFlow/handshake',
    () async {
      final conn = RelayConnection(
        machineDeviceId: _machineId,
        crypto: CryptoService(),
        relayOverride: relay,
      );
      addTearDown(conn.dispose);

      var pairFlowCalls = 0;
      final session1 = await _openConnection(
        conn,
        agentSeed: agentSeed,
        agentPub: agentPub,
        onPairFlowCalled: () => pairFlowCalls++,
      );

      // Simulate a SECOND project on this machine resolving its transport —
      // agentTransportForProvider calls `mgr.connectionFor(base).open(...)`
      // again for every project id; RelayConnection.open() must short-circuit
      // via its cached `_openFuture`.
      final session2 = await conn.open(
        pairFlow: () async {
          pairFlowCalls++;
          fail('pairFlow must not run again for a second project on the '
              'same machine');
        },
        crypto: CryptoService(),
        phoneDeviceId: _phoneId,
        agentEd25519PubB64: base64.encode(agentPub),
        phoneEd25519Seed: List<int>.filled(32, 3),
      );

      expect(pairFlowCalls, 1);
      expect(session2, same(session1));

      // Two distinct project streams, ONE underlying session/relay.
      final streamA = session1.streamFor('stream-a');
      final streamB = session1.streamFor('stream-b');
      expect(identical(streamA, streamB), isFalse);
      expect(streamA.session, same(session1));
      expect(streamB.session, same(session1));
      expect(conn.relay, same(relay), reason: 'exactly one RelayService');
    },
  );

  test(
    'drill-in binds via a control-plane stream-ready advert at 0 RTT — no '
    'new project:start once the streamId is already known',
    () async {
      final conn = RelayConnection(
        machineDeviceId: _machineId,
        crypto: CryptoService(),
        relayOverride: relay,
      );
      addTearDown(conn.dispose);

      final (session, keys) = await _openConnectionWithKeys(
        conn,
        agentSeed: agentSeed,
        agentPub: agentPub,
        onPairFlowCalled: () {},
      );

      // The agent advertises a project's stream unprompted (e.g. as part of
      // `agent:projects` on connect) — sealed under the established keys,
      // exactly as MachineSession's own outbound traffic is.
      final agentSend =
          E2eTransportDart(sendKey: keys.a2p, recvKey: keys.p2a);
      relay.inject(IncomingRouteMessage(
        from: _machineId,
        channel: 'control',
        kind: FrameKind.sealed,
        payload: await agentSend.seal(jsonEncode({
          'm': {
            'type': 'stream-ready',
            'projectId': 'proj-a',
            'streamId': 'stream-a',
          },
        })),
      ));

      String? knownStreamId;
      for (var i = 0; i < 50; i++) {
        knownStreamId = session.streamIdForProject('proj-a');
        if (knownStreamId != null) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(knownStreamId, 'stream-a');

      final sentBefore = relay.sent.length;
      final streamId = await session.bindProject(
        'proj-a',
        {'type': 'project:start', 'projectId': 'proj-a'},
        timeout: const Duration(seconds: 2),
      );
      expect(streamId, 'stream-a');
      expect(relay.sent.length, sentBefore,
          reason: 'a known streamId resolves at 0 RTT — bindProject must '
              'not send project:start when the mapping is already known');

      final transport = session.streamFor(streamId);
      expect(transport.session, same(session),
          reason: 'the drilled-in project stream still lives on the SAME '
              'machine session — no new socket/handshake');
    },
  );
}
