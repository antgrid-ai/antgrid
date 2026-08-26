// The demo transport is the whole demo: every surface a reviewer sees is a
// real widget reducing frames this class hands it. These tests pin the two
// properties that make it safe to ship — it answers everything it is asked,
// and it holds nothing open once disposed.
import 'package:antgrid/demo/demo_identity.dart';
import 'package:antgrid/demo/demo_transport.dart';
import 'package:antgrid/demo/fixtures/demo_workspace_fixtures.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// Subscribes [into] to everything published on [DemoTransport.messages],
/// snapshot replay included (the stream replays `snapshotCache` to each new
/// subscriber).
void _collect(DemoTransport transport, List<InboundMessage> into) {
  transport.messages.listen(into.add);
}

Iterable<String> _types(List<InboundMessage> messages) =>
    messages.map((m) => m.json['type'] as String? ?? '');

void main() {
  test('connect replays the snapshot and reports connected', () async {
    final transport = DemoTransport();
    addTearDown(transport.dispose);

    await transport.connect();

    expect(transport.currentState, TransportState.connected);
    expect(transport.isEstablished, isTrue);
    expect(transport.isLocal, isTrue);
    expect(_types(transport.snapshotCache), contains('agent:status'));
    expect(_types(transport.snapshotCache), contains('git:status'));
    // The composer refuses to render a session it has no capabilities for.
    expect(_types(transport.snapshotCache), contains('agent:capabilities'));
  });

  test('every replayed frame carries an id and a timestamp', () async {
    final transport = DemoTransport();
    addTearDown(transport.dispose);

    await transport.connect();

    for (final message in transport.snapshotCache) {
      expect(message.json['id'], isA<String>());
      expect(message.json['timestamp'], isA<int>());
    }
  });

  test('a late subscriber still receives the snapshot', () async {
    final transport = DemoTransport();
    addTearDown(transport.dispose);
    await transport.connect();

    final seen = <InboundMessage>[];
    _collect(transport, seen);
    await Future<void>.delayed(Duration.zero);

    expect(_types(seen), contains('agent:status'));
  });

  test(
    'drainScript plays the opening beats without waiting them out',
    () async {
      final transport = DemoTransport();
      addTearDown(transport.dispose);
      await transport.connect();

      final seen = <InboundMessage>[];
      _collect(transport, seen);
      await Future<void>.delayed(Duration.zero);
      seen.clear();

      transport.drainScript();
      await Future<void>.delayed(Duration.zero);

      expect(_types(seen), contains('terminal:output'));
      expect(_types(seen), contains('ports:update'));
      expect(_types(seen), contains('preview:url'));
    },
  );

  group('RPC', () {
    test('state.snapshot returns the opening frames', () async {
      final transport = DemoTransport();
      addTearDown(transport.dispose);
      await transport.connect();

      final result = await transport.request(
        'state.snapshot',
        params: {
          'types': ['*'],
        },
      );

      final frames = (result['frames'] as List).cast<Map<String, Object?>>();
      expect(frames.map((f) => f['type']), contains('agent:status'));
    });

    test('session.transcriptSnapshot answers per session', () async {
      final transport = DemoTransport();
      addTearDown(transport.dispose);
      await transport.connect();

      final result = await transport.request(
        'session.transcriptSnapshot',
        params: {'sessionId': kDemoSessionCheckoutId},
      );

      final frames = (result['frames'] as List).cast<Map<String, Object?>>();
      expect(frames, isNotEmpty);
      expect(
        frames.map((f) => f['sessionId']),
        everyElement(kDemoSessionCheckoutId),
      );
    });

    test('an unknown session gets an empty transcript, never a hang', () async {
      final transport = DemoTransport();
      addTearDown(transport.dispose);
      await transport.connect();

      final result = await transport.request(
        'session.transcriptSnapshot',
        params: {'sessionId': 'nope'},
      );

      expect(result['frames'], isEmpty);
    });

    // The one failure a demo cannot recover from is silence: the caller sits on
    // a spinner until its own timeout and the surface never settles.
    test('an unsupported method is refused rather than dropped', () async {
      final transport = DemoTransport();
      addTearDown(transport.dispose);
      await transport.connect();

      await expectLater(
        transport.request('host.restart'),
        throwsA(
          isA<RpcException>().having(
            (e) => e.code,
            'code',
            'E_DEMO_UNSUPPORTED',
          ),
        ),
      );
    });
  });

  group('messages', () {
    test('session:list is answered with the canned rows', () async {
      final transport = DemoTransport();
      addTearDown(transport.dispose);
      await transport.connect();

      final seen = <InboundMessage>[];
      _collect(transport, seen);
      await transport.send({
        'type': 'session:list',
        'requestId': 'req-1',
        'checkoutId': 'main',
      });
      transport.drainScript();
      await Future<void>.delayed(Duration.zero);

      final result = seen.firstWhere(
        (m) => m.json['type'] == 'session:list:result',
      );
      expect(result.json['requestId'], 'req-1');
      final sessions = (result.json['sessions'] as List)
          .cast<Map<String, Object?>>();
      expect(
        sessions.map((s) => s['id']),
        containsAll(<String>[kDemoSessionCheckoutId, kDemoSessionCartId]),
      );
    });

    test('a mutating session verb is refused, not ignored', () async {
      final transport = DemoTransport();
      addTearDown(transport.dispose);
      await transport.connect();

      final seen = <InboundMessage>[];
      _collect(transport, seen);
      await transport.send({
        'type': 'session:create',
        'requestId': 'req-2',
        'checkoutId': 'main',
      });
      transport.drainScript();
      await Future<void>.delayed(Duration.zero);

      final result = seen.firstWhere((m) => m.json['type'] == 'session:result');
      expect(result.json['requestId'], 'req-2');
      expect(result.json['ok'], isFalse);
      expect(result.json['errorCode'], 'E_DEMO_UNSUPPORTED');
    });

    test('file:read serves a sample file and refuses anything else', () async {
      final transport = DemoTransport();
      addTearDown(transport.dispose);
      await transport.connect();

      final seen = <InboundMessage>[];
      _collect(transport, seen);
      final path = kDemoFileContents.keys.first;
      await transport.send({'type': 'file:read', 'path': path});
      await transport.send({'type': 'file:read', 'path': 'etc/shadow'});
      transport.drainScript();
      await Future<void>.delayed(Duration.zero);

      final contents = seen
          .where((m) => m.json['type'] == 'file:content')
          .toList();
      expect(contents, hasLength(2));
      expect(contents.first.json['content'], kDemoFileContents[path]);
      // The refusal arrives as CONTENT in a successful frame, never as the
      // envelope's `error`: an error-bearing frame is classified onto the
      // status tier, which `FileService` does not handle `file:content` on, so
      // an honest error would strand the viewer on its spinner.
      expect(contents.last.json['error'], isNull);
      expect(contents.last.json['content'], contains(kDemoRefusalText));
    });

    test('file:search really searches the sample bodies', () async {
      final transport = DemoTransport();
      addTearDown(transport.dispose);
      await transport.connect();

      final seen = <InboundMessage>[];
      _collect(transport, seen);
      await transport.send({
        'type': 'file:search',
        'requestId': 'req-3',
        'query': 'quantity',
      });
      transport.drainScript();
      await Future<void>.delayed(Duration.zero);

      final done = seen.firstWhere((m) => m.json['type'] == 'file:search-done');
      expect(done.json['requestId'], 'req-3');
      expect(done.json['totalMatches'], greaterThan(0));
    });

    test('a prompt streams a canned reply and closes its turn', () async {
      final transport = DemoTransport();
      addTearDown(transport.dispose);
      await transport.connect();

      final seen = <InboundMessage>[];
      _collect(transport, seen);
      await transport.send({
        'type': 'agent:prompt',
        'sessionId': kDemoSessionCheckoutId,
        'text': 'add a coupon field',
      });
      transport.drainScript();
      await Future<void>.delayed(Duration.zero);

      expect(_types(seen), contains('agent:turn-start'));
      expect(_types(seen), contains('agent:item-delta'));
      expect(_types(seen), contains('agent:turn-end'));
      // The user's own text has to come back as an item, or the transcript
      // shows a reply to nothing.
      final userItem = seen.firstWhere(
        (m) =>
            m.json['type'] == 'agent:item-added' &&
            ((m.json['item'] as Map)['role'] == 'user'),
      );
      expect((userItem.json['item'] as Map)['text'], 'add a coupon field');
    });

    test('cancel drops the queued deltas and ends the turn', () async {
      final transport = DemoTransport();
      addTearDown(transport.dispose);
      await transport.connect();

      final seen = <InboundMessage>[];
      _collect(transport, seen);
      await transport.send({
        'type': 'agent:prompt',
        'sessionId': kDemoSessionCheckoutId,
        'text': 'hello',
      });
      await Future<void>.delayed(Duration.zero);
      final turnId = seen
          .firstWhere((m) => m.json['type'] == 'agent:turn-start')
          .json['turnId'];
      seen.clear();

      await transport.send({
        'type': 'agent:cancel',
        'sessionId': kDemoSessionCheckoutId,
        'turnId': turnId,
      });
      transport.drainScript();
      await Future<void>.delayed(Duration.zero);

      expect(_types(seen), isNot(contains('agent:item-delta')));
      final end = seen.firstWhere((m) => m.json['type'] == 'agent:turn-end');
      expect(end.json['stopReason'], 'cancelled');
    });

    test('terminal input echoes and says plainly that nothing ran', () async {
      final transport = DemoTransport();
      addTearDown(transport.dispose);
      await transport.connect();

      final seen = <InboundMessage>[];
      _collect(transport, seen);
      await transport.send({
        'type': 'terminal:input',
        'terminalId': kDemoTerminalId,
        'data': 'ls\r',
      });
      transport.drainScript();
      await Future<void>.delayed(Duration.zero);

      final output = seen.firstWhere(
        (m) => m.json['type'] == 'terminal:output',
      );
      expect(output.json['data'], contains('sample project'));
    });
  });

  group('dispose', () {
    test('fails in-flight RPCs instead of leaving them pending', () async {
      final transport = DemoTransport();
      await transport.connect();

      // Never answered on its own: drainScript is the only thing that flushes
      // the queued reply, and dispose happens first. The matcher is attached
      // BEFORE dispose so the rejection is never momentarily unhandled.
      final pending = expectLater(
        transport.request('state.snapshot'),
        throwsA(
          isA<RpcException>().having((e) => e.code, 'code', 'E_DISPOSED'),
        ),
      );
      await transport.dispose();
      await pending;
    });

    test('drops the script and closes every controller', () async {
      final transport = DemoTransport();
      await transport.connect();

      await transport.dispose();

      expect(transport.snapshotCache, isEmpty);
      expect(transport.outbound.isClosed, isTrue);
      expect(transport.stateController.isClosed, isTrue);
      expect(transport.droppedFrameController.isClosed, isTrue);
      // A second dispose is what an evicted-then-disposed project does; it must
      // not throw on the already-closed controllers.
      await transport.dispose();
      // Nothing queued can fire after teardown.
      transport.drainScript();
    });

    test('a send after dispose is a no-op', () async {
      final transport = DemoTransport();
      await transport.connect();
      await transport.dispose();

      await transport.send({'type': 'session:list', 'requestId': 'x'});
    });
  });
}
