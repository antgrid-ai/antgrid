// End-to-end coverage for supervisor-driven `RelayConnection` bring-up against
// the REAL v3 crypto handshake (via a fake agent responder, mirroring
// antgrid_relay_client's connection_handshake_test.dart harness).
//
// Also covers two "provider wiring" claims that are naturally proven at this
// layer, one connection/one handshake for real:
//   - two projects on ONE machine share the ONE MachineSession the connection
//     produces (no second dial / handshake for the second project).
//   - drill-in binds via `stream-ready` at 0 RTT: once the control plane has
//     advertised a project's streamId, `bindProject` resolves immediately
//     with no new `project:start` send.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:antgrid/connection/connection_supervisor.dart';
import 'package:antgrid/connection/relay_mechanisms.dart';
import 'package:antgrid/providers/relay_connection.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Fakes (same shape as antgrid_relay_client's connection_handshake_test.dart harness, plus a
// settable state stream and a peer-presence controller: the routable rung is
// fed by the relay's peer-online, which it emits right after welcome for a
// same-account agent).
// ---------------------------------------------------------------------------

class _RecordingRelay extends RelayService {
  _RecordingRelay() : super(crypto: CryptoService());

  final _messages = StreamController<IncomingRouteMessage>.broadcast();
  final _states = StreamController<AppState>.broadcast();
  final _presence = StreamController<bool>.broadcast();
  final sent = <({Uint8List payload, FrameKind kind})>[];
  AppState _cur = const AppState();

  /// How many upcoming connect() calls must fail before one succeeds.
  int failNextConnects = 0;

  @override
  Stream<IncomingRouteMessage> get messageStream => _messages.stream;
  @override
  Stream<AppState> get stateStream => _states.stream;
  @override
  AppState get currentState => _cur;
  @override
  Stream<bool> get peerPresenceStream => _presence.stream;
  @override
  Stream<ErrorMessage> get errorStream => const Stream.empty();

  int connectCalls = 0;

  @override
  Future<void> connect(
    String relayUrl,
    DeviceIdentity identity, {
    required String licenseToken,
    required int epoch,
    String? machineDeviceId,
  }) async {
    connectCalls++;
    if (failNextConnects > 0) {
      failNextConnects--;
      setState(const AppState());
      throw StateError('relay refused the hello');
    }
    setState(
      const AppState(connectionState: RelayConnectionState.authenticated),
    );
    // The relay announces same-account peers immediately after welcome.
    _presence.add(true);
  }

  @override
  void disconnect() {
    setState(const AppState());
    _presence.add(false);
  }

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
    if (!_presence.isClosed) await _presence.close();
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
  Duration timeout = const Duration(seconds: 5),
}) async {
  final clientHello = await _waitForHandshakeFrame(
    relay,
    'handshake:client-hello',
    startIndex: startIndex,
    timeout: timeout,
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

  final t = E2eTransportDart(sendKey: keys.a2p, recvKey: keys.p2a);
  relay.inject(
    IncomingRouteMessage(
      from: machineDeviceId,
      channel: 'control',
      kind: FrameKind.sealed,
      payload: await t.seal(
        jsonEncode({
          'type': 'handshake:agent-ready',
          'attemptId': attemptId,
          'confirm': base64.encode(await agentConfirmTagV2(keys.confirm)),
        }),
      ),
    ),
  );

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

  relay.inject(
    IncomingRouteMessage(
      from: machineDeviceId,
      channel: 'control',
      kind: FrameKind.sealed,
      payload: await t.seal(
        jsonEncode({'type': 'established', 'attemptId': attemptId}),
      ),
    ),
  );

  return keys;
}

const _machineId = 'machine-1';
const _phoneId = 'phone-device-id';

typedef VoidCallback = void Function();

DeviceIdentity _identity() => DeviceIdentity(
  deviceId: _phoneId,
  name: 'Test Phone',
  ed25519PrivateKey: Uint8List(64),
  ed25519PublicKey: Uint8List(32),
  x25519PrivateKey: Uint8List(32),
  x25519PublicKey: Uint8List(32),
);

/// The production mechanisms adapter over the fake relay. No pair step: trust
/// is account-derived, so the ladder is dial -> presence -> E2E handshake.
RelayMechanisms _mechanisms(
  _RecordingRelay relay, {
  required Uint8List agentPub,
}) => RelayMechanisms(
  relay: relay,
  crypto: CryptoService(),
  machineDeviceId: _machineId,
  identity: _identity(),
  phoneDeviceId: _phoneId,
  phoneEd25519Seed: List<int>.filled(32, 3),
  epoch: 1,
  resolveCoords: () async => ConnCoords(
    relayUrl: 'ws://relay.test',
    agentEd25519PubB64: base64.encode(agentPub),
  ),
  mintToken: () async => 'license-token',
);

/// Brings the connection up against the fake agent and returns both the
/// resulting session and the derived [SessionKeys], so a caller can seal
/// further control-plane traffic (e.g. a `stream-ready` advert) as the agent
/// would.
Future<(MachineSession, SessionKeys)> _openConnectionWithKeys(
  RelayConnection conn, {
  required List<int> agentSeed,
  required Uint8List agentPub,
}) async {
  final relay = conn.relay as _RecordingRelay;
  final agentFuture = _completeFakeAgentHandshake(
    relay,
    agentSeed: agentSeed,
    machineDeviceId: _machineId,
    phoneDeviceId: _phoneId,
  );
  conn.ensureStarted(mechanisms: _mechanisms(relay, agentPub: agentPub));
  final session = await conn.awaitSession();
  final keys = await agentFuture;
  return (session, keys);
}

Future<MachineSession> _openConnection(
  RelayConnection conn, {
  required List<int> agentSeed,
  required Uint8List agentPub,
}) async {
  final (session, _) = await _openConnectionWithKeys(
    conn,
    agentSeed: agentSeed,
    agentPub: agentPub,
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

  test('the supervisor drives dial → presence → E2E handshake and resolves '
      'a usable MachineSession', () async {
    final conn = RelayConnection(
      machineDeviceId: _machineId,
      crypto: CryptoService(),
      relayOverride: relay,
    );
    addTearDown(conn.dispose);

    final session = await _openConnection(
      conn,
      agentSeed: agentSeed,
      agentPub: agentPub,
    );

    expect(relay.connectCalls, 1);
    expect(session.isEstablished, isTrue);
    expect(conn.session, same(session));
  });

  test('a dial that fails once is retried by the supervisor, not left '
      'poisoned for the lifetime of the connection', () async {
    final conn = RelayConnection(
      machineDeviceId: _machineId,
      crypto: CryptoService(),
      relayOverride: relay,
    );
    addTearDown(conn.dispose);

    // The old memoized open() cached the FAILED future forever: the machine
    // stayed pinned "alive" for the reaper and an app restart was the only
    // recovery. Recovery is now a level-triggered re-evaluation, with nobody
    // re-invoking anything.
    relay.failNextConnects = 1;
    final agentFuture = _completeFakeAgentHandshake(
      relay,
      agentSeed: agentSeed,
      machineDeviceId: _machineId,
      phoneDeviceId: _phoneId,
      timeout: const Duration(seconds: 15),
    );
    conn.ensureStarted(mechanisms: _mechanisms(relay, agentPub: agentPub));

    final session = await conn.awaitSession();
    await agentFuture;

    expect(
      relay.connectCalls,
      2,
      reason: 'the supervisor re-dialled on its own',
    );
    expect(session.isEstablished, isTrue);
    expect(conn.session, same(session));
  });

  test('two projects on the SAME machine share the ONE MachineSession — a '
      'second bring-up reuses the running supervisor with no second '
      'dial/handshake', () async {
    final conn = RelayConnection(
      machineDeviceId: _machineId,
      crypto: CryptoService(),
      relayOverride: relay,
    );
    addTearDown(conn.dispose);

    final session1 = await _openConnection(
      conn,
      agentSeed: agentSeed,
      agentPub: agentPub,
    );

    // Simulate a SECOND project on this machine resolving its transport —
    // agentTransportForProvider calls ensureStarted/awaitSession again for
    // every project id; the machine's supervisor must already be running and
    // must not re-dial.
    conn.ensureStarted(mechanisms: _mechanisms(relay, agentPub: agentPub));
    final session2 = await conn.awaitSession();

    expect(relay.connectCalls, 1);
    expect(session2, same(session1));

    // Two distinct project streams, ONE underlying session/relay.
    final streamA = session1.streamFor('stream-a');
    final streamB = session1.streamFor('stream-b');
    expect(identical(streamA, streamB), isFalse);
    expect(streamA.session, same(session1));
    expect(streamB.session, same(session1));
    expect(conn.relay, same(relay), reason: 'exactly one RelayService');
  });

  test('drill-in binds via a control-plane stream-ready advert at 0 RTT — no '
      'new project:start once the streamId is already known', () async {
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
    );

    // The agent advertises a project's stream unprompted (e.g. as part of
    // `agent:projects` on connect) — sealed under the established keys,
    // exactly as MachineSession's own outbound traffic is.
    final agentSend = E2eTransportDart(sendKey: keys.a2p, recvKey: keys.p2a);
    relay.inject(
      IncomingRouteMessage(
        from: _machineId,
        channel: 'control',
        kind: FrameKind.sealed,
        payload: await agentSend.seal(
          jsonEncode({
            'm': {
              'type': 'stream-ready',
              'projectId': 'proj-a',
              'streamId': 'stream-a',
            },
          }),
        ),
      ),
    );

    String? knownStreamId;
    for (var i = 0; i < 50; i++) {
      knownStreamId = session.streamIdForProject('proj-a');
      if (knownStreamId != null) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(knownStreamId, 'stream-a');

    final sentBefore = relay.sent.length;
    final streamId = await session.bindProject('proj-a', {
      'type': 'project:start',
      'projectId': 'proj-a',
    }, timeout: const Duration(seconds: 2));
    expect(streamId, 'stream-a');
    expect(
      relay.sent.length,
      sentBefore,
      reason:
          'a known streamId resolves at 0 RTT — bindProject must '
          'not send project:start when the mapping is already known',
    );

    final transport = session.streamFor(streamId);
    expect(
      transport.session,
      same(session),
      reason:
          'the drilled-in project stream still lives on the SAME '
          'machine session — no new socket/handshake',
    );
  });
}
