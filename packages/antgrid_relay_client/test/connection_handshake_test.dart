// ConnectionHandshake coverage for the plaintext hello: QUIC/TLS between the
// two lease-authorized endpoints is the confidentiality layer now, so there
// is no crypto left in this driver to verify — only the wire shape of
// `session:hello`/`established`, the attemptId correlation, the timeout and
// the abort path.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

class _RecordingRelay implements PeerLink {
  final _messages = StreamController<IncomingPeerFrame>.broadcast();
  final sent = <({String channel, Uint8List payload})>[];
  PeerSendOutcome outcome = PeerSendOutcome.accepted;

  @override
  Stream<IncomingPeerFrame> get messageStream => _messages.stream;
  @override
  Stream<PeerLinkState> get payloadStateStream =>
      const Stream<PeerLinkState>.empty();
  @override
  Stream<PeerPath> get pathStream => const Stream<PeerPath>.empty();
  @override
  Stream<PeerLinkFailure> get failureStream =>
      const Stream<PeerLinkFailure>.empty();
  @override
  bool get isDispatchAllowed => true;
  @override
  PeerLinkDiagnostic? get netTap => null;

  @override
  Future<PeerSendOutcome> sendFrame(String channel, Uint8List payload) async {
    sent.add((channel: channel, payload: payload));
    return outcome;
  }

  void inject(IncomingPeerFrame msg) => _messages.add(msg);

  Future<void> closeStreams() => _messages.close();

  @override
  Future<void> close() => closeStreams();
}

Map<String, dynamic> _decode(Uint8List payload) =>
    jsonDecode(utf8.decode(payload)) as Map<String, dynamic>;

void _replyEstablished(
  _RecordingRelay relay,
  String attemptId, {
  String channel = 'control',
}) {
  relay.inject(
    IncomingPeerFrame(
      channel: channel,
      payload: Uint8List.fromList(
        utf8.encode(
          jsonEncode({'type': 'established', 'attemptId': attemptId}),
        ),
      ),
    ),
  );
}

void main() {
  late _RecordingRelay relay;

  setUp(() {
    relay = _RecordingRelay();
  });

  tearDown(() async {
    await relay.closeStreams();
  });

  test('run() sends session:hello on control with a fresh attemptId and the '
      'hello capability literal', () async {
    final hs = ConnectionHandshake(relay: relay);
    final runFuture = hs.run();
    await Future<void>.delayed(Duration.zero);

    expect(relay.sent, hasLength(1));
    expect(relay.sent.single.channel, 'control');
    final hello = _decode(relay.sent.single.payload);
    expect(hello['type'], 'session:hello');
    expect(hello['attemptId'], isA<String>());
    expect((hello['attemptId'] as String).isNotEmpty, isTrue);
    expect(hello['capabilities'], kSessionHelloCapabilities);

    _replyEstablished(relay, hello['attemptId'] as String);
    expect(await runFuture, isTrue);
  });

  test('an established with a mismatched attemptId is ignored — the attempt '
      'still times out', () async {
    final hs = ConnectionHandshake(
      relay: relay,
      attemptTimeout: const Duration(milliseconds: 100),
    );
    final runFuture = hs.run();
    await Future<void>.delayed(Duration.zero);

    _replyEstablished(relay, 'some-other-attempt-id');
    expect(await runFuture, isFalse);
  });

  test('an established on a non-control channel is ignored', () async {
    final hs = ConnectionHandshake(
      relay: relay,
      attemptTimeout: const Duration(milliseconds: 100),
    );
    final runFuture = hs.run();
    await Future<void>.delayed(Duration.zero);
    final attemptId = _decode(relay.sent.single.payload)['attemptId'] as String;

    _replyEstablished(relay, attemptId, channel: 'preview');
    expect(await runFuture, isFalse);
  });

  test('run() times out and resolves false when nothing answers', () async {
    final hs = ConnectionHandshake(
      relay: relay,
      attemptTimeout: const Duration(milliseconds: 50),
    );
    expect(await hs.run(), isFalse);
  });

  test('a duplicate established for the same attemptId is idempotent', () async {
    final hs = ConnectionHandshake(relay: relay);
    final runFuture = hs.run();
    await Future<void>.delayed(Duration.zero);
    final attemptId = _decode(relay.sent.single.payload)['attemptId'] as String;

    _replyEstablished(relay, attemptId);
    _replyEstablished(relay, attemptId);
    expect(await runFuture, isTrue);
  });

  test('a send the link refuses resolves the attempt false immediately', () async {
    relay.outcome = PeerSendOutcome.closed;
    final hs = ConnectionHandshake(
      relay: relay,
      attemptTimeout: const Duration(seconds: 5),
    );
    expect(await hs.run(), isFalse);
  });

  test('cancel() before established resolves the attempt false', () async {
    final hs = ConnectionHandshake(
      relay: relay,
      attemptTimeout: const Duration(seconds: 5),
    );
    final runFuture = hs.run();
    await Future<void>.delayed(Duration.zero);
    hs.cancel();
    expect(await runFuture, isFalse);
  });

  group('AppSessionHandshaker', () {
    test('each perform() call runs a fresh attempt with a new attemptId', () async {
      final handshaker = AppSessionHandshaker(relay: relay);

      final firstPerform = handshaker.perform();
      await Future<void>.delayed(Duration.zero);
      final attemptId1 = _decode(relay.sent.single.payload)['attemptId'] as String;
      _replyEstablished(relay, attemptId1);
      expect(await firstPerform, isTrue);

      final secondPerform = handshaker.perform();
      await Future<void>.delayed(Duration.zero);
      final attemptId2 = _decode(relay.sent.last.payload)['attemptId'] as String;
      expect(attemptId2, isNot(attemptId1));
      _replyEstablished(relay, attemptId2);
      expect(await secondPerform, isTrue);
    });

    test('abort() cancels the in-flight attempt and short-circuits later '
        'perform() calls', () async {
      final handshaker = AppSessionHandshaker(
        relay: relay,
        attemptTimeout: const Duration(seconds: 5),
      );
      final firstPerform = handshaker.perform();
      await Future<void>.delayed(Duration.zero);

      handshaker.abort();
      expect(await firstPerform, isFalse);
      expect(await handshaker.perform(), isFalse);
    });
  });
}
