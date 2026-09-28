import '../helpers/fixed_peer_connector.dart';
// End-to-end coverage for supervisor-driven `RelayConnection` bring-up against
// the plaintext `session:hello` -> `established` exchange (via a fake agent
// responder). QUIC/TLS between lease-authorized Iroh endpoints is the
// confidentiality layer, so the fake agent below answers with no
// crypto of its own — mirroring antgrid_relay_client's
// connection_handshake_test.dart harness.
//
// Also covers two "provider wiring" claims that are naturally proven at this
// layer, one connection/one hello for real:
//   - two projects on ONE machine share the ONE MachineSession the connection
//     produces (no second dial / hello for the second project).
//   - drill-in binds via `stream-ready` at 0 RTT: once the control plane has
//     advertised a project ready, `openProject` opens its native stream with
//     no new `project:start` send.
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

  final _messages = StreamController<IncomingSessionRecord>.broadcast();
  final _states = StreamController<AppState>.broadcast();
  final _presence = StreamController<bool>.broadcast();
  final _errors = StreamController<ErrorMessage>.broadcast();
  final sent = <Uint8List>[];
  AppState _cur = const AppState();

  /// How many upcoming connect() calls must fail before one succeeds.
  int failNextConnects = 0;

  @override
  Stream<IncomingSessionRecord> get messageStream => _messages.stream;
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
  Future<PeerSendOutcome> sendRecord(Uint8List payload) async {
    if (!isDispatchAllowed) return PeerSendOutcome.closed;
    sent.add(payload);
    return PeerSendOutcome.accepted;
  }

  void inject(IncomingSessionRecord msg) => _messages.add(msg);

  void setState(AppState s) {
    _cur = s;
    _states.add(s);
  }

  /// Every native project stream opened, in call order — a project bound at
  /// 0 RTT still opens exactly one of these; only an extra `project:start`
  /// round trip would add a second control-plane send, not a second entry
  /// here.
  final openedStreams = <_FakeProjectStream>[];

  @override
  Future<PeerStream> openStream(
    StreamOpen open, {
    required int maxRecordBytes,
    required int maxQueuedBytes,
    int? rawAfterRecords,
  }) async {
    final stream = _FakeProjectStream(open);
    openedStreams.add(stream);
    return stream;
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

/// One project's native stream, the bridge side. Mirrors
/// `antgrid_relay_client`'s own `FakePeerStream` test fake at the shape this
/// suite needs: inject the bridge's first `stream-ready` record, read back
/// what the app sent.
class _FakeProjectStream implements PeerStream {
  _FakeProjectStream(this.open);

  final StreamOpen open;
  // Single-subscription, so a record injected before the session's read loop
  // subscribes is buffered rather than dropped.
  final _records = StreamController<Uint8List>();
  final sent = <Uint8List>[];
  bool resetCalled = false;
  bool finishCalled = false;

  @override
  Stream<Uint8List> get records => _records.stream;

  @override
  Future<PeerSendOutcome> send(Uint8List record) async {
    sent.add(record);
    return PeerSendOutcome.accepted;
  }

  final sentRaw = <Uint8List>[];

  @override
  Future<PeerSendOutcome> sendRaw(Uint8List bytes) async {
    sentRaw.add(bytes);
    return PeerSendOutcome.accepted;
  }

  @override
  Future<void> reset() async => resetCalled = true;

  @override
  Future<void> finish() async => finishCalled = true;

  void injectStreamReady(String projectId) => _injectJson({
    'type': 'stream-ready',
    'projectId': projectId,
  });

  void _injectJson(Map<String, dynamic> json) {
    if (!_records.isClosed) {
      _records.add(Uint8List.fromList(utf8.encode(jsonEncode(json))));
    }
  }
}

/// Opens [projectId] on [session] and answers its native stream's first
/// record, as the bridge does once it admits the open.
Future<StreamTransport> _openBound(
  _RecordingRelay relay,
  MachineSession session,
  String projectId,
) async {
  final openBefore = relay.openedStreams.length;
  final opening = session.openProject(projectId, {
    'type': 'project:start',
    'projectId': projectId,
  }, timeout: const Duration(seconds: 2));
  for (var i = 0; i < 50 && relay.openedStreams.length == openBefore; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  relay.openedStreams.last.injectStreamReady(projectId);
  return opening;
}

/// Advertises [projectId] ready on the control plane, plaintext, exactly as
/// an unprompted `agent:projects` push would — this is what lets a later
/// `openProject` skip the `project:start` round trip. Awaits a
/// beat for the session's broadcast listener to process the injected frame
/// before returning.
Future<void> _advertiseReady(_RecordingRelay relay, String projectId) async {
  relay.inject(
    IncomingSessionRecord(
      payload: Uint8List.fromList(
        utf8.encode(
          jsonEncode({'type': 'stream-ready', 'projectId': projectId}),
        ),
      ),
    ),
  );
  await Future<void>.delayed(const Duration(milliseconds: 20));
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
    IncomingSessionRecord(
      payload: Uint8List.fromList(
        utf8.encode(
          jsonEncode({'type': kSessionEstablished, 'attemptId': attemptId}),
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
/// `FixedPeerConnector`'s `TestPayloadLink` forwards `openStream` straight to
/// the carrier, which is what lets `openProject` open native streams on
/// [relay].
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

    // Two distinct project streams, ONE underlying session/relay — each
    // needs its own control-plane ready notice before its native stream
    // binds.
    await _advertiseReady(relay, 'proj-a');
    await _advertiseReady(relay, 'proj-b');
    final streamA = await _openBound(relay, session1, 'proj-a');
    await streamA.connect();
    final streamB = await _openBound(relay, session1, 'proj-b');
    await streamB.connect();

    expect(identical(streamA, streamB), isFalse);
    expect(streamA.session, same(session1));
    expect(streamB.session, same(session1));
    expect(conn.relay, same(relay), reason: 'exactly one RelayService');
  });

  test('drill-in binds via a control-plane stream-ready advert at 0 RTT — no '
      'new project:start once the project is already known ready', () async {
    final conn = MachineConnection(
      machineDeviceId: _machineId,
      crypto: CryptoService(),
      relayOverride: relay,
    );
    addTearDown(conn.dispose);

    final session = await _openConnection(conn);

    // The agent advertises a project ready unprompted (e.g. as part of
    // `agent:projects` on connect) — plaintext, exactly as MachineSession's
    // own outbound traffic is.
    await _advertiseReady(relay, 'proj-a');

    final sentBefore = relay.sent.length;
    final openBefore = relay.openedStreams.length;
    final openFuture = session.openProject('proj-a', {
      'type': 'project:start',
      'projectId': 'proj-a',
    }, timeout: const Duration(seconds: 2));
    for (var i = 0; i < 50 && relay.openedStreams.length == openBefore; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(
      relay.openedStreams.length,
      openBefore + 1,
      reason: 'a project already known ready opens its native stream at once',
    );
    relay.openedStreams.last.injectStreamReady('proj-a');
    final transport = await openFuture;

    expect(
      relay.sent.length,
      sentBefore,
      reason:
          'a project already known ready resolves at 0 RTT — openProject '
          'must not send project:start when readiness is already known',
    );
    expect(
      transport.session,
      same(session),
      reason:
          'the drilled-in project stream still lives on the SAME '
          'machine session — no new socket/handshake',
    );
  });
}
