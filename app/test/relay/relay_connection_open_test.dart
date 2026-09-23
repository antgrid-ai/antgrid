import '../helpers/fixed_peer_connector.dart';
// End-to-end coverage for supervisor-driven `RelayConnection` bring-up against
// the plaintext `session:hello` -> `established` exchange (via a fake agent
// responder). QUIC/TLS between lease-authorized Iroh endpoints is the
// confidentiality layer since Stage B, so the fake agent below answers with no
// crypto of its own — mirroring antgrid_relay_client's
// connection_handshake_test.dart harness.
//
// Also covers two "provider wiring" claims that are naturally proven at this
// layer, one connection/one hello for real:
//   - two projects on ONE machine share the ONE MachineSession the connection
//     produces (no second dial / hello for the second project).
//   - drill-in binds via `stream-ready` at 0 RTT: once the control plane has
//     advertised a project's streamId, `bindProject` resolves immediately
//     with no new `project:start` send.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:antgrid/connection/connection_supervisor.dart';
import 'package:antgrid/connection/peer_connection.dart';
import 'package:antgrid/providers/relay_connection.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Fakes (same shape as antgrid_relay_client's connection_handshake_test.dart harness, plus a
// settable control state and an explicit payload double for the native link).
// ---------------------------------------------------------------------------

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

  final _messages = StreamController<IncomingPeerFrame>.broadcast();
  final _states = StreamController<AppState>.broadcast();
  final _presence = StreamController<bool>.broadcast();
  final _errors = StreamController<ErrorMessage>.broadcast();
  final sent = <Uint8List>[];
  AppState _cur = const AppState();

  /// How many upcoming connect() calls must fail before one succeeds.
  int failNextConnects = 0;

  @override
  Stream<IncomingPeerFrame> get messageStream => _messages.stream;
  @override
  Stream<AppState> get stateStream => _states.stream;
  @override
  AppState get currentState => _cur;
  @override
  Stream<bool> get peerPresenceStream => _presence.stream;
  @override
  Stream<ErrorMessage> get errorStream => _errors.stream;

  void injectError(ErrorMessage e) => _errors.add(e);

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
  Future<PeerSendOutcome> sendFrame(String channel, Uint8List payload) async {
    if (!isDispatchAllowed) return PeerSendOutcome.closed;
    if (channel == 'control') sent.add(payload);
    return PeerSendOutcome.accepted;
  }

  void inject(IncomingPeerFrame msg) => _messages.add(msg);

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
    if (!_errors.isClosed) await _errors.close();
  }
}

Future<Map<String, dynamic>> _waitForControlFrame(
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
      Map<String, dynamic> j;
      try {
        j = jsonDecode(utf8.decode(relay.sent[i])) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      if (j['type'] == type) return j;
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Answers the phone's plaintext `session:hello` with `established`, so the
/// handshaker's `perform()` resolves. QUIC/TLS between the two lease-
/// authorized endpoints is the confidentiality layer now, so there is nothing
/// here to sign or seal.
Future<void> _completeFakeAgentHello(
  _RecordingRelay relay, {
  int startIndex = 0,
  Duration timeout = const Duration(seconds: 5),
}) async {
  final hello = await _waitForControlFrame(
    relay,
    'session:hello',
    startIndex: startIndex,
    timeout: timeout,
  );
  final attemptId = hello['attemptId'] as String;
  relay.inject(
    IncomingPeerFrame(
      channel: 'control',
      payload: Uint8List.fromList(
        utf8.encode(
          jsonEncode({'type': 'established', 'attemptId': attemptId}),
        ),
      ),
    ),
  );
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
/// is account-derived, so the ladder is dial -> presence -> plaintext hello.
PeerConnectionMechanisms _mechanisms(_RecordingRelay relay) =>
    PeerConnectionMechanisms(
      peerRuntime: FixedPeerConnector(relay),
      machineDeviceId: _machineId,
      resolveCoords: () async => const ConnCoords(
        relayUrl: 'ws://relay.test',
        agentEd25519PubB64: 'AGENT_PUB',
      ),
    );

RelayCentralControlDialer _central(_RecordingRelay relay) =>
    RelayCentralControlDialer(
      relay: relay,
      machineDeviceId: _machineId,
      identity: _identity(),
      epoch: 1,
      mintToken: () async => 'license-token',
    );

/// Brings the connection up against the fake agent and returns the resulting
/// session.
Future<MachineSession> _openConnection(MachineConnection conn) async {
  final relay = conn.relay as _RecordingRelay;
  final agentFuture = _completeFakeAgentHello(relay);
  conn.ensureStarted(mechanisms: _mechanisms(relay), central: _central(relay));
  final session = await conn.awaitSession();
  await agentFuture;
  return session;
}

void main() {
  late _RecordingRelay relay;

  setUp(() {
    relay = _RecordingRelay();
  });

  tearDown(() async {
    await relay.closeStreams();
  });

  test('the supervisor drives dial → presence → plaintext hello and resolves '
      'a usable MachineSession', () async {
    final conn = MachineConnection(
      machineDeviceId: _machineId,
      crypto: CryptoService(),
      relayOverride: relay,
    );
    addTearDown(conn.dispose);

    final session = await _openConnection(conn);

    expect(relay.connectCalls, 1);
    expect(session.isEstablished, isTrue);
    expect(conn.session, same(session));
  });

  test('a central hello failure does not poison the native session and is '
      'retried independently', () async {
    final conn = MachineConnection(
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
    final agentFuture = _completeFakeAgentHello(
      relay,
      timeout: const Duration(seconds: 15),
    );
    conn.ensureStarted(
      mechanisms: _mechanisms(relay),
      central: _central(relay),
    );

    final session = await conn.awaitSession();
    await agentFuture;
    for (var i = 0; i < 200 && relay.connectCalls < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(
      relay.connectCalls,
      2,
      reason: 'central control retries without rebuilding the payload',
    );
    expect(session.isEstablished, isTrue);
    expect(conn.session, same(session));
  });

  test('two projects on the SAME machine share the ONE MachineSession — a '
      'second bring-up reuses the running supervisor with no second '
      'dial/hello', () async {
    final conn = MachineConnection(
      machineDeviceId: _machineId,
      crypto: CryptoService(),
      relayOverride: relay,
    );
    addTearDown(conn.dispose);

    final session1 = await _openConnection(conn);

    // Simulate a SECOND project on this machine resolving its transport —
    // agentTransportForProvider calls ensureStarted/awaitSession again for
    // every project id; the machine's supervisor must already be running and
    // must not re-dial.
    conn.ensureStarted(
      mechanisms: _mechanisms(relay),
      central: _central(relay),
    );
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
    final conn = MachineConnection(
      machineDeviceId: _machineId,
      crypto: CryptoService(),
      relayOverride: relay,
    );
    addTearDown(conn.dispose);

    final session = await _openConnection(conn);

    // The agent advertises a project's stream unprompted (e.g. as part of
    // `agent:projects` on connect) — plaintext, exactly as MachineSession's
    // own outbound traffic is since Stage B.
    relay.inject(
      IncomingPeerFrame(
        channel: 'control',
        payload: Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'm': {
                'type': 'stream-ready',
                'projectId': 'proj-a',
                'streamId': 'stream-a',
              },
            }),
          ),
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
