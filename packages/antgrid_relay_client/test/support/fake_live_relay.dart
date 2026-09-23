// Not a `_test.dart` file - shared PeerLink and handshaker fakes for
// MachineSession protocol tests.
import 'dart:async';
import 'dart:typed_data';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';

class SentFrame {
  final String channel;
  final Uint8List payload;
  final FrameKind kind;
  SentFrame(this.channel, this.payload, this.kind);
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
  Future<PeerSendOutcome> sendFrame(
    String channel,
    Uint8List payload, {
    FrameKind kind = FrameKind.sealed,
  }) async {
    sent.add(SentFrame(channel, payload, kind));
    return PeerSendOutcome.accepted;
  }

  void inject(IncomingPeerFrame msg) => _messages.add(msg);

  void setState(AppState state) {
    _state = switch (state.connectionState) {
      RelayConnectionState.authenticated => PeerLinkState.ready,
      RelayConnectionState.disconnected => PeerLinkState.closed,
      _ => PeerLinkState.connecting,
    };
    _states.add(_state);
  }

  void injectError(PeerLinkFailure error) => _errors.add(error);

  Future<void> closeStreams() async {
    await _messages.close();
    await _states.close();
    await _errors.close();
  }

  @override
  Future<void> close() => closeStreams();
}

/// Resolves [keys] (or each of [sequence] in turn, one per call) with no real
/// crypto — MachineSession only cares that `perform()` eventually resolves.
class FakeHandshaker implements SessionHandshaker {
  FakeHandshaker(SessionKeys keys) : _sequence = [keys];
  FakeHandshaker.sequence(this._sequence);

  final List<SessionKeys?> _sequence;
  int performCalls = 0;
  bool aborted = false;

  /// Optional per-call delay, keyed by call index (0-based) — lets a test hold
  /// a rekey "in flight" to observe make-before-break behavior.
  Duration Function(int callIndex)? delayFor;

  @override
  Future<SessionKeys?> perform() async {
    final idx = performCalls;
    performCalls++;
    final delay = delayFor?.call(idx);
    if (delay != null) await Future<void>.delayed(delay);
    if (idx < _sequence.length) return _sequence[idx];
    return _sequence.isEmpty ? null : _sequence.last;
  }

  @override
  void abort() => aborted = true;
}

/// A fresh all-`seed`-valued 32-byte SessionKeys triple, distinguishable by
/// `seed` across a2p/p2a/confirm so mistaken key-direction bugs show up as a
/// decrypt failure rather than an accidental match.
SessionKeys fixedKeys(int seed) => SessionKeys(
  a2p: Uint8List(32)..fillRange(0, 32, seed),
  p2a: Uint8List(32)..fillRange(0, 32, (seed + 50) % 256),
  confirm: Uint8List(32)..fillRange(0, 32, (seed + 100) % 256),
);

/// Opens a frame MachineSession sent (sealed under p2a), as the agent would.
/// Suites decode outbound frames only through this and [sealFromAgent], so the
/// payload encoding is swapped in one place.
Future<String?> openFromPhone(SessionKeys keys, Uint8List payload) =>
    E2eTransportDart(sendKey: keys.a2p, recvKey: keys.p2a).open(payload);

/// Encodes [plaintext] as an inbound agent frame (sealed under a2p).
Future<Uint8List> sealFromAgent(SessionKeys keys, String plaintext) =>
    E2eTransportDart(sendKey: keys.a2p, recvKey: keys.p2a).seal(plaintext);

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
