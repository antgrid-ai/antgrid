// v3 ConnectionHandshake coverage — replaces the deleted
// test/relay/connection_handshake_test.dart (pre-v3 API: `registrationId`,
// `installKeys` callback, completion on agent-ready). The v3 handshake adds a
// phone-generated `attemptId` correlating every frame, kind-byte dispatch
// (handshake vs sealed), and a mandatory sealed `established{attemptId}` from
// the agent — `run()` only completes on that, retransmitting sealed
// `app:ready` every [ConnectionHandshake]'s `appReadyRetransmit` interval
// until it arrives.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class _RecordingRelay extends RelayService {
  _RecordingRelay() : super(crypto: CryptoService());

  final _messages = StreamController<IncomingRouteMessage>.broadcast();
  final sent = <({Uint8List payload, FrameKind kind})>[];

  @override
  Stream<IncomingRouteMessage> get messageStream => _messages.stream;
  @override
  Stream<AppState> get stateStream => const Stream.empty();
  @override
  AppState get currentState => const AppState();

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

  Future<void> closeStreams() => _messages.close();
}

Future<(List<int> seed, Uint8List pub)> _agentEd25519Keypair([
  int fill = 0xA1,
]) async {
  final seed = List.filled(32, fill);
  final kp = await Ed25519().newKeyPairFromSeed(seed);
  final pub = await kp.extractPublicKey();
  return (seed, Uint8List.fromList(pub.bytes));
}

/// Scans only frames at index >= [startIndex] — a rekey's second `perform()`
/// call must not re-match the FIRST attempt's already-sent client-hello still
/// sitting in `relay.sent` (frames accumulate across calls; nothing clears
/// them between attempts).
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

/// Decodes every SEALED frame sent so far into JSON, using the agent's view
/// of the keys (recvKey: p2a — matches what the phone sealed app:ready with).
Future<List<Map<String, dynamic>>> _decodeSealedFrames(
  _RecordingRelay relay,
  SessionKeys keys,
) async {
  final out = <Map<String, dynamic>>[];
  final t = E2eTransportDart(sendKey: keys.a2p, recvKey: keys.p2a);
  for (final f in relay.sent) {
    if (f.kind != FrameKind.sealed) continue;
    final dec = await t.open(f.payload);
    if (dec == null) continue;
    try {
      out.add(jsonDecode(dec) as Map<String, dynamic>);
    } catch (_) {}
  }
  return out;
}

class _FakeAgentSession {
  _FakeAgentSession(this.keys, this.attemptId);
  final SessionKeys keys;
  final String attemptId;
}

/// Drives the agent side of the handshake up through `agent-hello` +
/// `agent-ready`, matching the phone's `attemptId`. Returns the derived keys
/// so the caller can drive (or withhold) `established` explicitly.
Future<_FakeAgentSession> _runFakeAgentUpToReady(
  _RecordingRelay relay, {
  required List<int> agentSeed,
  required Uint8List agentPub,
  required String machineDeviceId,
  required String phoneDeviceId,
  Duration timeout = const Duration(seconds: 5),
  int startIndex = 0,
  bool tamperConfirmTag = false,
}) async {
  final clientHello = await _waitForHandshakeFrame(
    relay,
    'handshake:client-hello',
    timeout: timeout,
    startIndex: startIndex,
  );
  final attemptId = clientHello['attemptId'] as String;
  final phoneX25519Pub = base64.decode(clientHello['pubkey'] as String);
  final nonce = base64.decode(clientHello['nonce'] as String);

  final agentX25519KP = await X25519().newKeyPair();
  final agentX25519Priv = Uint8List.fromList(
    await agentX25519KP.extractPrivateKeyBytes(),
  );
  final agentX25519Pub = Uint8List.fromList(
    (await agentX25519KP.extractPublicKey()).bytes,
  );

  final agentTranscript = buildTranscriptV2(
    TranscriptFields(
      registrationId: machineDeviceId,
      role: 'agent',
      agentDeviceId: machineDeviceId,
      phoneDeviceId: phoneDeviceId,
      agentX25519Pub: agentX25519Pub,
      phoneX25519Pub: phoneX25519Pub,
      nonce: nonce,
    ),
  );
  final agentSig = await signTranscriptV2(
    transcript: agentTranscript,
    ed25519Seed: agentSeed,
  );
  final ss = await x25519SharedSecret(
    privateKey: agentX25519Priv,
    peerPublicKey: phoneX25519Pub,
  );
  final keys = await deriveSessionKeysV2(ss, agentTranscript);

  relay.inject(
    IncomingRouteMessage(
      from: machineDeviceId,
      channel: 'control',
      kind: FrameKind.handshake,
      payload: Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'type': 'handshake:agent-hello',
            'attemptId': attemptId,
            'pubkey': base64.encode(agentX25519Pub),
            'sig': agentSig,
          }),
        ),
      ),
    ),
  );

  final validTag = await agentConfirmTagV2(keys.confirm);
  final confirmTag = tamperConfirmTag
      ? (Uint8List.fromList(validTag)..[0] ^= 0xFF)
      : validTag;
  final agentReadySealed =
      await E2eTransportDart(sendKey: keys.a2p, recvKey: keys.p2a).seal(
        jsonEncode({
          'type': 'handshake:agent-ready',
          'attemptId': attemptId,
          'confirm': base64.encode(confirmTag),
        }),
      );
  relay.inject(
    IncomingRouteMessage(
      from: machineDeviceId,
      channel: 'control',
      kind: FrameKind.sealed,
      payload: agentReadySealed,
    ),
  );

  return _FakeAgentSession(keys, attemptId);
}

Future<void> _sendEstablished(
  _RecordingRelay relay,
  String machineDeviceId,
  _FakeAgentSession fa,
) async {
  final sealed = await E2eTransportDart(
    sendKey: fa.keys.a2p,
    recvKey: fa.keys.p2a,
  ).seal(jsonEncode({'type': 'established', 'attemptId': fa.attemptId}));
  relay.inject(
    IncomingRouteMessage(
      from: machineDeviceId,
      channel: 'control',
      kind: FrameKind.sealed,
      payload: sealed,
    ),
  );
}

const _machineDeviceId = 'machine-1';
const _phoneDeviceId = 'phone-device-id';

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

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

  ConnectionHandshake buildHandshake({
    Duration attemptTimeout = const Duration(seconds: 5),
    Duration appReadyRetransmit = const Duration(milliseconds: 150),
  }) {
    return ConnectionHandshake(
      relay: relay,
      crypto: CryptoService(),
      machineDeviceId: _machineDeviceId,
      phoneDeviceId: _phoneDeviceId,
      agentEd25519PubB64: base64.encode(agentPub),
      phoneEd25519Seed: const [
        1,
        2,
        3,
        4,
        5,
        6,
        7,
        8,
        9,
        10,
        11,
        12,
        13,
        14,
        15,
        16,
        17,
        18,
        19,
        20,
        21,
        22,
        23,
        24,
        25,
        26,
        27,
        28,
        29,
        30,
        31,
        32,
      ],
      attemptTimeout: attemptTimeout,
      appReadyRetransmit: appReadyRetransmit,
    );
  }

  test('run() completes only once established{attemptId} arrives, and no '
      'earlier frame (agent-ready alone) is enough', () async {
    final hs = buildHandshake();
    final runFuture = hs.run();

    final fa = await _runFakeAgentUpToReady(
      relay,
      agentSeed: agentSeed,
      agentPub: agentPub,
      machineDeviceId: _machineDeviceId,
      phoneDeviceId: _phoneDeviceId,
    );

    // app:ready must have gone out (sealed under the derived keys), but run()
    // must NOT have completed yet — only `established` completes it.
    var appReadySeen = false;
    for (var i = 0; i < 50 && !appReadySeen; i++) {
      final frames = await _decodeSealedFrames(relay, fa.keys);
      appReadySeen = frames.any((f) => f['type'] == 'app:ready');
      if (!appReadySeen)
        await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(appReadySeen, isTrue);

    var runCompleted = false;
    unawaited(runFuture.then((_) => runCompleted = true));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(
      runCompleted,
      isFalse,
      reason: 'agent-ready alone must not complete the handshake',
    );

    await _sendEstablished(relay, _machineDeviceId, fa);
    final keys = await runFuture;
    expect(keys, isNotNull);
    expect(identical(keys, fa.keys), isFalse); // distinct objects, same bytes
    expect(keys!.a2p, fa.keys.a2p);
  });

  test('app:ready is retransmitted (re-sealed each time) until established '
      'arrives — a fake agent that drops the FIRST app:ready still gets a '
      'handshake, via the retransmit', () async {
    final hs = buildHandshake(
      attemptTimeout: const Duration(seconds: 5),
      appReadyRetransmit: const Duration(milliseconds: 120),
    );
    final runFuture = hs.run();

    final fa = await _runFakeAgentUpToReady(
      relay,
      agentSeed: agentSeed,
      agentPub: agentPub,
      machineDeviceId: _machineDeviceId,
      phoneDeviceId: _phoneDeviceId,
    );

    // Wait for at least TWO distinct app:ready sends (the retransmit firing),
    // WITHOUT ever answering the first one — proves the retransmit loop runs.
    List<Map<String, dynamic>> appReadyFrames = const [];
    for (var i = 0; i < 200; i++) {
      final frames = await _decodeSealedFrames(relay, fa.keys);
      appReadyFrames = frames.where((f) => f['type'] == 'app:ready').toList();
      if (appReadyFrames.length >= 2) break;
      await Future<void>.delayed(const Duration(milliseconds: 15));
    }
    expect(
      appReadyFrames.length,
      greaterThanOrEqualTo(2),
      reason: 'app:ready must be retransmitted while established is withheld',
    );
    // Every retransmit carries the SAME attemptId and a valid confirm tag
    // (re-sealed each time — GCM nonces differ, but the plaintext repeats).
    for (final f in appReadyFrames) {
      expect(f['attemptId'], fa.attemptId);
      expect(f['confirm'], isNotNull);
    }

    // Now let it succeed on a later retransmit.
    await _sendEstablished(relay, _machineDeviceId, fa);
    final keys = await runFuture.timeout(const Duration(seconds: 5));
    expect(keys, isNotNull);
  });

  test('a duplicate established{attemptId} is idempotent — run() resolves '
      'exactly once with no error', () async {
    final hs = buildHandshake();
    final runFuture = hs.run();

    final fa = await _runFakeAgentUpToReady(
      relay,
      agentSeed: agentSeed,
      agentPub: agentPub,
      machineDeviceId: _machineDeviceId,
      phoneDeviceId: _phoneDeviceId,
    );

    // Fire established TWICE back-to-back before the phone has a chance to
    // tear down its listener.
    await _sendEstablished(relay, _machineDeviceId, fa);
    await _sendEstablished(relay, _machineDeviceId, fa);

    final keys = await runFuture.timeout(const Duration(seconds: 5));
    expect(keys, isNotNull);
  });

  test('run() rejects an agent-hello signed by a different key (no '
      'established is ever produced)', () async {
    final hs = buildHandshake(
      attemptTimeout: const Duration(milliseconds: 300),
    );
    final runFuture = hs.run();

    // Sign with a DIFFERENT seed than the one whose pubkey was pinned.
    final (wrongSeed, _) = await _agentEd25519Keypair(0xB2);
    await _runFakeAgentUpToReady(
      relay,
      agentSeed: wrongSeed,
      agentPub: agentPub,
      machineDeviceId: _machineDeviceId,
      phoneDeviceId: _phoneDeviceId,
    );

    final keys = await runFuture;
    expect(keys, isNull);
  });

  test(
    'run() rejects a TAMPERED agent-ready confirm tag — no sealed '
    'app:ready is ever sent, and the attempt times out with no keys',
    () async {
      final hs = buildHandshake(
        attemptTimeout: const Duration(milliseconds: 300),
      );
      final runFuture = hs.run();

      final fa = await _runFakeAgentUpToReady(
        relay,
        agentSeed: agentSeed,
        agentPub: agentPub,
        machineDeviceId: _machineDeviceId,
        phoneDeviceId: _phoneDeviceId,
        tamperConfirmTag: true,
      );

      final keys = await runFuture;
      expect(
        keys,
        isNull,
        reason: 'a bad confirm tag must never yield established keys',
      );

      final sealedFrames = await _decodeSealedFrames(relay, fa.keys);
      expect(
        sealedFrames.any((f) => f['type'] == 'app:ready'),
        isFalse,
        reason:
            'app:ready must never be sent on top of an unverified '
            'agent-ready confirm (possible MITM)',
      );
    },
  );

  group('AppSessionHandshaker', () {
    test(
      'each perform() call runs a FRESH attempt with a new attemptId',
      () async {
        final handshaker = AppSessionHandshaker(
          relay: relay,
          crypto: CryptoService(),
          machineDeviceId: _machineDeviceId,
          phoneDeviceId: _phoneDeviceId,
          agentEd25519PubB64: base64.encode(agentPub),
          phoneEd25519Seed: List<int>.filled(32, 7),
        );

        final firstPerform = handshaker.perform();
        final fa1 = await _runFakeAgentUpToReady(
          relay,
          agentSeed: agentSeed,
          agentPub: agentPub,
          machineDeviceId: _machineDeviceId,
          phoneDeviceId: _phoneDeviceId,
        );
        await _sendEstablished(relay, _machineDeviceId, fa1);
        final keys1 = await firstPerform.timeout(const Duration(seconds: 5));
        expect(keys1, isNotNull);

        final startIndex = relay.sent.length;
        final secondPerform = handshaker.perform();
        final fa2 = await _runFakeAgentUpToReady(
          relay,
          agentSeed: agentSeed,
          agentPub: agentPub,
          machineDeviceId: _machineDeviceId,
          phoneDeviceId: _phoneDeviceId,
          startIndex: startIndex,
        );
        expect(
          fa2.attemptId,
          isNot(fa1.attemptId),
          reason: 'a rekey (second perform) must mint a fresh attemptId',
        );
        await _sendEstablished(relay, _machineDeviceId, fa2);
        final keys2 = await secondPerform.timeout(const Duration(seconds: 5));
        expect(keys2, isNotNull);
      },
    );
  });
}
