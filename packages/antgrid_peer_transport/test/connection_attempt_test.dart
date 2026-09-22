import 'dart:async';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:antgrid_peer_transport/antgrid_peer_transport.dart';

class FakeLink implements PeerLink {
  bool closed = false;
  @override
  bool get isDispatchAllowed => !closed;
  @override
  PeerLinkDiagnostic? get netTap => null;
  @override
  Stream<IncomingRouteMessage> get messageStream => const Stream.empty();
  @override
  Stream<PeerLinkState> get payloadStateStream => const Stream.empty();
  @override
  Stream<PeerPath> get pathStream => const Stream.empty();
  @override
  Stream<PeerLinkFailure> get failureStream => const Stream.empty();
  @override
  Stream<void> get peerRestartStream => const Stream.empty();
  @override
  Future<PeerSendOutcome> sendFrame(
    String to,
    String channel,
    Uint8List payload, {
    FrameKind kind = FrameKind.sealed,
  }) async => PeerSendOutcome.accepted;
  @override
  Future<void> close() async {
    closed = true;
  }
}

void main() {
  test('a timed-out uncancellable dial cannot accumulate retries', () async {
    final pending = Completer<PeerLink>();
    final attempt = PeerConnectionAttempt();
    var calls = 0;
    Future<PeerLink> dial() {
      calls++;
      return pending.future;
    }

    await expectLater(
      attempt.connect(iroh: dial, budget: Duration.zero),
      throwsA(isA<PeerConnectionFailure>()),
    );
    await expectLater(
      attempt.connect(iroh: dial),
      throwsA(
        isA<PeerConnectionFailure>().having(
          (e) => e.code,
          'code',
          'NATIVE_CONNECT_PENDING',
        ),
      ),
    );
    expect(calls, 1);
    final late = FakeLink();
    pending.complete(late);
    await Future<void>.delayed(Duration.zero);
    expect(late.closed, isTrue);
    final next = FakeLink();
    expect(await attempt.connect(iroh: () async => next), same(next));
  });

  test('timeout fails and closes late native completion', () async {
    final events = <Map<String, Object?>>[];
    final native = Completer<PeerLink>();
    await expectLater(
      PeerConnectionAttempt().connect(
        iroh: () => native.future,
        budget: Duration.zero,
        diagnostic: events.add,
      ),
      throwsA(
        isA<PeerConnectionFailure>().having(
          (e) => e.terminal,
          'terminal',
          false,
        ),
      ),
    );
    final late = FakeLink();
    native.complete(late);
    await Future<void>.delayed(Duration.zero);
    expect(late.closed, isTrue);
    expect(
      events.map((e) => e['msgType']),
      contains('peer:connection-timeout'),
    );
    expect(events.every((e) => e['transport'] == 'iroh'), isTrue);
  });
  for (final terminal in [true, false]) {
    test('native failure propagates with terminal=$terminal', () async {
      final failure = PeerConnectionFailure('private-data', terminal: terminal);
      final events = <Map<String, Object?>>[];
      await expectLater(
        PeerConnectionAttempt().connect(
          iroh: () async => throw failure,
          diagnostic: events.add,
        ),
        throwsA(same(failure)),
      );
      expect(events.toString(), isNot(contains('private-data')));
      expect(events.map((e) => e['msgType']), isNot(contains('peer:fallback')));
    });
  }
  test('diagnostic failure cannot change native connection', () async {
    final native = FakeLink();
    expect(
      await PeerConnectionAttempt().connect(
        iroh: () async => native,
        diagnostic: (_) => throw StateError('observer'),
      ),
      same(native),
    );
    expect(native.closed, isFalse);
  });
  test('cancelled attempt closes its result', () async {
    final native = Completer<PeerLink>();
    final selector = PeerConnectionAttempt();
    final rejected = expectLater(
      selector.connect(iroh: () => native.future),
      throwsA(isA<PeerConnectionFailure>()),
    );
    selector.cancel();
    final link = FakeLink();
    native.complete(link);
    await rejected;
    await Future<void>.delayed(Duration.zero);
    expect(link.closed, isTrue);
  });
}
