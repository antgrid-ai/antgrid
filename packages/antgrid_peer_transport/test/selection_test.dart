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
  test('late native completion is closed after selecting WebSocket', () async {
    final events = <Map<String, Object?>>[];
    final native = Completer<PeerLink>();
    final fallback = FakeLink();
    final selector = PeerLinkSelector();
    final selected = await selector.select(
      mode: PeerTransportMode.irohPreferred,
      iroh: () => native.future,
      websocket: () async => fallback,
      budget: Duration.zero,
      diagnostic: events.add,
    );
    expect(selected, same(fallback));
    final late = FakeLink();
    native.complete(late);
    await Future<void>.delayed(Duration.zero);
    expect(late.closed, isTrue);
    expect(fallback.closed, isFalse);
    expect(events.map((e) => e['msgType']), [
      'peer:selection-start',
      'peer:selection-timeout',
      'peer:fallback',
      'peer:transport-selected',
    ]);
    expect(events.last['transport'], 'relay');
    for (final event in events) {
      expect(event['dir'], 'event');
      expect(event['kind'], 'lifecycle');
      expect(event.containsKey('bytes'), isFalse);
      expect(event.containsKey('frameId'), isFalse);
      final detail = event['detail'] as Map;
      expect(detail['elapsedMs'], greaterThanOrEqualTo(0));
      expect(detail['generation'], 1);
    }
  });
  test('authorization denial never selects fallback', () async {
    final events = <Map<String, Object?>>[];
    var fallbackCalls = 0;
    await expectLater(
      PeerLinkSelector().select(
        mode: PeerTransportMode.irohPreferred,
        diagnostic: events.add,
        iroh: () async =>
            throw const PeerSelectionFailure('DENIED', terminal: true),
        websocket: () async {
          fallbackCalls++;
          return FakeLink();
        },
      ),
      throwsA(isA<PeerSelectionFailure>()),
    );
    expect(fallbackCalls, 0);
    expect(events.last['msgType'], 'peer:selection-rejected');
    expect(
      (events.last['detail'] as Map)['reason'],
      'TERMINAL_OR_UNCLASSIFIED',
    );
  });
  test(
    'diagnostic failure cannot change successful native selection',
    () async {
      final native = FakeLink();
      final selected = await PeerLinkSelector().select(
        mode: PeerTransportMode.irohOnly,
        iroh: () async => native,
        websocket: () async => throw StateError('unexpected fallback'),
        diagnostic: (_) => throw StateError('observer failed'),
      );
      expect(selected, same(native));
      expect(native.closed, isFalse);
    },
  );

  test('unknown failure codes never escape into diagnostics', () async {
    final events = <Map<String, Object?>>[];
    await PeerLinkSelector().select(
      mode: PeerTransportMode.irohPreferred,
      iroh: () async =>
          throw const PeerSelectionFailure('private-data', terminal: false),
      websocket: () async => FakeLink(),
      diagnostic: events.add,
    );
    expect(events.toString(), isNot(contains('private-data')));
    final fallback = events.singleWhere((e) => e['msgType'] == 'peer:fallback');
    expect((fallback['detail'] as Map)['reason'], 'TRANSIENT_NATIVE_FAILURE');
  });
  test('cancelled selection closes its result', () async {
    final native = Completer<PeerLink>();
    final selector = PeerLinkSelector();
    final selection = selector.select(
      mode: PeerTransportMode.irohOnly,
      iroh: () => native.future,
      websocket: () async => FakeLink(),
    );
    final rejected = expectLater(
      selection,
      throwsA(isA<PeerSelectionFailure>()),
    );
    selector.cancel();
    final link = FakeLink();
    native.complete(link);
    await rejected;
    expect(link.closed, isTrue);
  });
}
