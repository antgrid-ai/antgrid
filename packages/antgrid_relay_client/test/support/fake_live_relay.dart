// Not a `_test.dart` file — shared fakes for MachineSession-level tests.
//
// A fake RelayService that starts on a live (`authenticated`) socket and
// records every outbound sendMessage call, plus an instant
// [SessionHandshaker] that resolves to fixed
// [SessionKeys] with no real crypto exchange — these tests are about
// MachineSession's envelope/fragmentation/stream-demux/rekey plumbing, not the
// E2E handshake itself (that lives in app/lib/relay/connection_handshake.dart
// and is covered by app-side tests against the real crypto).
import 'dart:async';
import 'dart:typed_data';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';

class SentFrame {
  final String to;
  final String channel;
  final Uint8List payload;
  final FrameKind kind;
  SentFrame(this.to, this.channel, this.payload, this.kind);
}

class FakeLiveRelay extends RelayService {
  FakeLiveRelay({
    RelayConnectionState initial = RelayConnectionState.authenticated,
  }) : super(crypto: CryptoService()) {
    _current = AppState(connectionState: initial);
  }

  final _messages = StreamController<IncomingRouteMessage>.broadcast();
  final _states = StreamController<AppState>.broadcast();
  final _presence = StreamController<bool>.broadcast();
  final sent = <SentFrame>[];
  late AppState _current;

  @override
  Stream<IncomingRouteMessage> get messageStream => _messages.stream;
  @override
  Stream<AppState> get stateStream => _states.stream;
  @override
  Stream<bool> get peerPresenceStream => _presence.stream;
  @override
  AppState get currentState => _current;

  @override
  void sendMessage(
    String to,
    String channel,
    Uint8List payload, {
    FrameKind kind = FrameKind.sealed,
  }) {
    sent.add(SentFrame(to, channel, payload, kind));
  }

  void inject(IncomingRouteMessage msg) => _messages.add(msg);

  void setState(AppState s) {
    _current = s;
    _states.add(s);
  }

  void presence(bool online) => _presence.add(online);

  Future<void> closeStreams() async {
    await _messages.close();
    await _states.close();
    await _presence.close();
  }
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
