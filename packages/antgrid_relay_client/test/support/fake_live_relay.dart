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
  final _restarts = StreamController<void>.broadcast();
  final _errors = StreamController<PeerLinkFailure>.broadcast();
  final sent = <SentFrame>[];
  PeerLinkState _state;
  bool _wasOffline = false;

  @override
  Stream<IncomingPeerFrame> get messageStream => _messages.stream;
  @override
  Stream<PeerLinkState> get payloadStateStream => _states.stream;
  @override
  Stream<PeerPath> get pathStream => const Stream.empty();
  @override
  Stream<void> get peerRestartStream => _restarts.stream;
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

  void presence(bool online) {
    if (!online) {
      _wasOffline = true;
    } else if (_wasOffline) {
      _wasOffline = false;
      _restarts.add(null);
    }
  }

  void injectError(PeerLinkFailure error) => _errors.add(error);

  Future<void> closeStreams() async {
    await _messages.close();
    await _states.close();
    await _restarts.close();
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
