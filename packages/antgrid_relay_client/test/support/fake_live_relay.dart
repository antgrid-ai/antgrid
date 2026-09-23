// Not a `_test.dart` file - shared PeerLink and handshaker fakes for
// MachineSession protocol tests.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';

class SentFrame {
  final String channel;
  final Uint8List payload;
  SentFrame(this.channel, this.payload);
}

class FakeLiveRelay implements PeerLink {
  FakeLiveRelay({
    RelayConnectionState initial = RelayConnectionState.authenticated,
    this.netTap,
  }) : _state = initial == RelayConnectionState.authenticated
           ? PeerLinkState.ready
           : PeerLinkState.connecting;

  final _messages = StreamController<IncomingPeerFrame>.broadcast();
  final _states = StreamController<PeerLinkState>.broadcast();
  final _errors = StreamController<PeerLinkFailure>.broadcast();
  final sent = <SentFrame>[];
  PeerLinkState _state;

  /// True once [close] has been called. There is no application-layer key to
  /// rotate any more, so a session that decides it is dead closes the whole
  /// link — this is how a test observes that decision without a real socket.
  bool closeCalled = false;

  @override
  Stream<IncomingPeerFrame> get messageStream => _messages.stream;
  @override
  Stream<PeerLinkState> get payloadStateStream => _states.stream;
  @override
  Stream<PeerPath> get pathStream => const Stream.empty();
  @override
  Stream<PeerLinkFailure> get failureStream => _errors.stream;
  @override
  bool get isDispatchAllowed => _state == PeerLinkState.ready;
  @override
  final RelayNetTap? netTap;

  @override
  Future<PeerSendOutcome> sendFrame(String channel, Uint8List payload) async {
    sent.add(SentFrame(channel, payload));
    return PeerSendOutcome.accepted;
  }

  void inject(IncomingPeerFrame msg) => _messages.add(msg);

  void setState(AppState state) {
    _state = switch (state.connectionState) {
      RelayConnectionState.authenticated => PeerLinkState.ready,
      RelayConnectionState.disconnected => PeerLinkState.closed,
      _ => PeerLinkState.connecting,
    };
    if (!_states.isClosed) _states.add(_state);
  }

  void injectError(PeerLinkFailure error) => _errors.add(error);

  Future<void> closeStreams() async {
    await _messages.close();
    await _states.close();
    await _errors.close();
  }

  @override
  Future<void> close() async {
    closeCalled = true;
    // Idempotent: a session with no application-layer key to rotate closes
    // the link from more than one trigger (RPC timeouts, missed liveness),
    // and only the first must actually transition the state.
    if (_state != PeerLinkState.closed) {
      _state = PeerLinkState.closed;
      if (!_states.isClosed) _states.add(PeerLinkState.closed);
    }
    await closeStreams();
  }
}

/// Resolves to [established] (or each of [sequence] in turn, one per call).
/// There is no key to fabricate any more — MachineSession only cares that
/// `perform()` eventually resolves true or false.
class FakeHandshaker implements SessionHandshaker {
  FakeHandshaker({bool established = true}) : _sequence = [established];
  FakeHandshaker.sequence(this._sequence);

  final List<bool> _sequence;
  int performCalls = 0;
  bool aborted = false;

  /// Optional per-call delay, keyed by call index (0-based) — lets a test hold
  /// an attempt "in flight" to observe ordering around it.
  Duration Function(int callIndex)? delayFor;

  @override
  Future<bool> perform() async {
    final idx = performCalls;
    performCalls++;
    final delay = delayFor?.call(idx);
    if (delay != null) await Future<void>.delayed(delay);
    if (idx < _sequence.length) return _sequence[idx];
    return _sequence.isEmpty ? false : _sequence.last;
  }

  @override
  void abort() => aborted = true;
}

/// Opens a frame MachineSession sent, as the agent would. Suites decode
/// outbound frames only through this and [encodeFromAgent], so the payload
/// encoding is swapped in one place. Synchronous: QUIC/TLS is the
/// confidentiality layer now, so there is no per-frame crypto step left.
String decodeFromPhone(Uint8List payload) => utf8.decode(payload);

/// Encodes [plaintext] as an inbound agent frame.
Uint8List encodeFromAgent(String plaintext) =>
    Uint8List.fromList(utf8.encode(plaintext));

/// Constructs a [MachineSession] over [relay], starts it and drives it to
/// established.
Future<MachineSession> establishSession(
  FakeLiveRelay relay, {
  required SessionHandshaker handshaker,
  String machineDeviceId = 'machine-1',
  Map<String, dynamic> Function(String projectId)? projectStartMessageBuilder,
  Duration snapshotTimeout = const Duration(seconds: 5),
  Duration pingSilence = const Duration(seconds: kPingSilenceSeconds),
  int? channelWindowBytes,
  int? socketInflightBytes,
  int creditBatchBytes = kCreditBatchBytes,
  Duration unknownStreamLogInterval = const Duration(seconds: 30),
  RelayLogger? logger,
}) async {
  final session = MachineSession(
    relay: relay,
    machineDeviceId: machineDeviceId,
    handshaker: handshaker,
    projectStartMessageBuilder: projectStartMessageBuilder,
    snapshotTimeout: snapshotTimeout,
    pingSilence: pingSilence,
    channelWindowBytes: channelWindowBytes,
    socketInflightBytes: socketInflightBytes,
    creditBatchBytes: creditBatchBytes,
    unknownStreamLogInterval: unknownStreamLogInterval,
    logger: logger,
  );
  session.start();
  await session.ensureEstablished();
  return session;
}
