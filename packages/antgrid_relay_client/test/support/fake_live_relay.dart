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

class FakeLiveRelay implements PeerLink, MultiStreamPeerLink {
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

  /// Every stream a test's [MachineSession] has opened, in call order — a
  /// project that reopens (a stream end + backoff, or a fresh establishment)
  /// appends a SECOND [FakePeerStream] rather than replacing the first, so a
  /// test can tell a reopen happened from a bind that just took a while.
  final openedStreams = <FakePeerStream>[];

  /// Set to make the NEXT [openStream] call throw this instead of returning a
  /// stream — for a `STREAM_OPEN_FAILED`-shaped test. Consumed on use.
  Object? openStreamError;

  @override
  Future<PeerStream> openStream(
    StreamOpen open, {
    required int maxRecordBytes,
    required int maxQueuedBytes,
  }) async {
    final err = openStreamError;
    if (err != null) {
      openStreamError = null;
      throw err;
    }
    final stream = FakePeerStream(open);
    openedStreams.add(stream);
    return stream;
  }

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

/// One project's (or other purpose-specific) native stream a test drives
/// directly: the bridge side of [PeerStream]. A test injects the bridge's
/// first record ([injectStreamReady]/[injectRefusal]) and any record after
/// it ([injectJson]/[injectRecord]), and reads back what the app wrote in
/// [sent].
class FakePeerStream implements PeerStream {
  FakePeerStream(this.open);

  /// The open frame [MachineSession] sent to create this stream.
  final StreamOpen open;

  final _records = StreamController<Uint8List>.broadcast();
  final sent = <Uint8List>[];
  bool resetCalled = false;
  bool finishCalled = false;
  bool _ended = false;

  @override
  Stream<Uint8List> get records => _records.stream;

  @override
  Future<PeerSendOutcome> send(Uint8List record) async {
    if (_ended) return PeerSendOutcome.closed;
    sent.add(record);
    return PeerSendOutcome.accepted;
  }

  // Real semantics: our own reset()/finish() ends only OUR send half. The
  // bridge counts the stream until it ALSO sees its own half end (§4.3), so
  // records must keep flowing (or a test must explicitly call [end]) until
  // that happens — matching [end]'s own doc comment below.
  @override
  Future<void> reset() async {
    resetCalled = true;
  }

  @override
  Future<void> finish() async {
    finishCalled = true;
  }

  /// Injects the bridge's `stream-ready {projectId}` first record.
  void injectStreamReady(String projectId) =>
      injectJson({'type': 'stream-ready', 'projectId': projectId});

  /// Injects a `stream:refused` record, then ends the stream — a real bridge
  /// FINs right after refusing, since Dart cannot read a QUIC reset code.
  void injectRefusal(StreamRefusedCode code, [String message = 'refused']) {
    injectJson(StreamRefused(code: code, message: message).toJson());
    end();
  }

  void injectJson(Map<String, dynamic> json) =>
      injectRecord(Uint8List.fromList(utf8.encode(jsonEncode(json))));

  void injectRecord(Uint8List record) {
    if (!_ended && !_records.isClosed) _records.add(record);
  }

  /// Ends the bridge's send half, as a clean close or right after a refusal.
  /// Idempotent, and distinct from [reset]/[finish] (the APP's send half) —
  /// a test can end the bridge side without ever driving the app to close.
  void end() {
    if (_ended) return;
    _ended = true;
    unawaited(_records.close());
  }
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
    logger: logger,
  );
  session.start();
  await session.ensureEstablished();
  return session;
}
