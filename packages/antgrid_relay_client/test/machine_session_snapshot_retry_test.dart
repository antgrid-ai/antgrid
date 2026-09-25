// The `state.snapshot` pull is the only carrier of a checkout's durable
// `agent:status` for a relay app, and a reply that lands after the RPC's
// timeout is discarded like any late response — so a single fixed wait lost a
// large or slow reply silently, with nothing left to re-send it until the next
// establishment. The pull must retry a timeout, with a longer wait each time,
// and stop retrying once the reply lands, once the failure is one a retry
// cannot change, or once the transport is gone.
//
// It also leaves the file tree out — the one unbounded frame — and does not
// pull it in a round trip of its own either: the per-checkout hydrators ask
// for it, and a second carrier sent the same megabytes again on every connect,
// enough on a slow uplink to starve the bridge's relay pongs and drop the
// socket the pull had just come up on.
import 'dart:async';
import 'dart:convert';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

import 'support/fake_live_relay.dart';

const _baseTimeout = Duration(milliseconds: 40);

void main() {
  late FakeLiveRelay relay;
  late FakeHandshaker handshaker;
  late MachineSession session;

  setUp(() async {
    relay = FakeLiveRelay();
    handshaker = FakeHandshaker();
    session = await establishSession(
      relay,
      handshaker: handshaker,
      snapshotTimeout: _baseTimeout,
    );
  });

  tearDown(() async {
    await session.dispose();
    await relay.closeStreams();
  });

  /// Every `state.snapshot` request sent so far on [stream] (null: the
  /// control plane), in order.
  List<({String id, Map<String, dynamic> params})> snapshotRequests({
    String? stream,
  }) {
    final out = <({String id, Map<String, dynamic> params})>[];
    for (final f in relay.sent) {
      final pt = decodeFromPhone(f.payload);
      final e = jsonDecode(pt) as Map<String, dynamic>;
      final m = e['m'];
      if (m is Map &&
          m['type'] == 'request' &&
          m['method'] == 'state.snapshot' &&
          e['s'] == stream) {
        out.add((
          id: m['requestId'] as String,
          params: (m['params'] as Map).cast<String, dynamic>(),
        ));
      }
    }
    return out;
  }

  /// The control plane's `state.snapshot` requestIds so far, in order.
  List<String> snapshotRequestIds() => [
    for (final r in snapshotRequests()) r.id,
  ];

  bool isTreePull(Map<String, dynamic> params) {
    final types = params['types'];
    return types is List && types.length == 1 && types.single == 'tree:full';
  }

  void injectControl(Map<String, dynamic> m, {String? stream}) {
    relay.inject(
      IncomingPeerFrame(
        channel: 'control',
        payload: encodeFromAgent(
          jsonEncode({if (stream != null) 's': stream, 'm': m}),
        ),
      ),
    );
  }

  Map<String, dynamic> snapshotReply(String requestId) => {
    'type': 'response',
    'requestId': requestId,
    'ok': true,
    'result': {
      'frames': [
        {
          'type': 'agent:projects',
          'projects': [
            {'projectId': 'proj-a', 'running': true},
          ],
        },
      ],
    },
  };

  test('a timed-out pull is retried with a longer wait, and the retry\'s '
      'reply is applied', () async {
    final control = session.control;
    final seen = <Map<String, dynamic>>[];
    final sub = control.messages.listen((m) => seen.add(m.json));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(snapshotRequestIds(), hasLength(1));

    // Past the first wait: the reply never came, so a second request is out.
    await Future<void>.delayed(_baseTimeout);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final ids = snapshotRequestIds();
    expect(ids, hasLength(2), reason: 'the timeout must be retried');

    injectControl(snapshotReply(ids.last));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(
      seen.map((j) => j['type']),
      contains('agent:projects'),
      reason: 'the retry\'s reply is the durable state the app runs on',
    );
    await sub.cancel();

    // A landed reply ends the chain — no third request, even past what the
    // doubled second wait would have allowed.
    await Future<void>.delayed(_baseTimeout * 3);
    expect(snapshotRequestIds(), hasLength(2));
  });

  test('a reply that lands in time is not followed by a retry', () async {
    session.control;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final ids = snapshotRequestIds();
    expect(ids, hasLength(1));
    injectControl(snapshotReply(ids.single));

    await Future<void>.delayed(_baseTimeout * 4);
    expect(snapshotRequestIds(), hasLength(1));
  });

  test('an error the agent answers with is not retried', () async {
    session.control;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final ids = snapshotRequestIds();
    expect(ids, hasLength(1));
    // A pre-RPC agent: the answer will not change on a second ask.
    injectControl({
      'type': 'response',
      'requestId': ids.single,
      'ok': false,
      'error': {'code': 'E_UNKNOWN_METHOD', 'message': 'no such method'},
    });

    await Future<void>.delayed(_baseTimeout * 4);
    expect(snapshotRequestIds(), hasLength(1));
  });

  test('retries stop at the attempt cap', () async {
    session.control;
    // Waits of 1x, 2x, 4x the base: well past the sum, plus slack.
    await Future<void>.delayed(_baseTimeout * 9);
    expect(snapshotRequestIds(), hasLength(3));
  });

  test('disposing the transport ends its retries', () async {
    final st = session.control;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(snapshotRequestIds(), hasLength(1));
    await st.dispose();

    await Future<void>.delayed(_baseTimeout * 4);
    expect(snapshotRequestIds(), hasLength(1));
  });

  test('refreshDurableState re-pulls the durable state', () async {
    session.control;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final seeded = snapshotRequestIds();
    expect(seeded, hasLength(1));
    injectControl(snapshotReply(seeded.single));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final st = session.control;
    final seen = <Map<String, dynamic>>[];
    final sub = st.messages.listen((m) => seen.add(m.json));
    unawaited(st.refreshDurableState());
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final sent = snapshotRequests();
    expect(sent, hasLength(2));
    expect(sent.last.params, {
      'types': ['*'],
      'exclude': ['tree:full'],
    });

    injectControl(snapshotReply(sent.last.id));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(
      seen.map((j) => j['type']),
      contains('agent:projects'),
      reason: "refreshDurableState's reply is applied like any other pull",
    );
    await sub.cancel();
  });

  test('refreshDurableState leaves the hydrators alone', () async {
    final st = session.control;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final seeded = snapshotRequestIds();
    expect(seeded, hasLength(1));
    injectControl(snapshotReply(seeded.single));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    var hydrated = 0;
    await st.hydrate('probe', () async {
      hydrated++;
    });
    expect(
      hydrated,
      1,
      reason: 'hydrate runs once immediately when established',
    );

    unawaited(st.refreshDurableState());
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final afterDurable = snapshotRequestIds();
    expect(afterDurable, hasLength(2));
    injectControl(snapshotReply(afterDurable.last));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(
      hydrated,
      1,
      reason: 'a checkout retry must not fan a tree:full out to every checkout',
    );

    unawaited(st.refreshSnapshot());
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final afterFull = snapshotRequestIds();
    expect(afterFull, hasLength(3));
    injectControl(snapshotReply(afterFull.last));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(
      hydrated,
      2,
      reason: 'refreshSnapshot still redrives hydrators, unchanged',
    );
  });

  group('the tree is left to the hydrators (now on a project\'s own native '
      'stream, Stage A A4)', () {
    Map<String, dynamic> reply(
      String requestId,
      List<Map<String, Object?>> frames,
    ) => {
      'type': 'response',
      'requestId': requestId,
      'ok': true,
      'result': {'frames': frames},
    };
    const status = <String, Object?>{
      'type': 'agent:status',
      'checkoutId': 'main',
      'terminals': <Object?>[],
    };
    const tree = <String, Object?>{
      'type': 'tree:full',
      'checkoutId': 'main',
      'root': <String, Object?>{},
    };

    /// Opens `proj-a`'s own native stream and binds it (the agent's
    /// `stream-ready` first record), returning the fake bridge-side stream a
    /// test injects on and the resulting [StreamTransport].
    Future<(FakePeerStream, StreamTransport)> openBoundProject() async {
      injectControl({'type': 'stream-ready', 'projectId': 'proj-a'});
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final opening = session.openProject('proj-a', {
        'type': 'project:start',
        'projectId': 'proj-a',
      });
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final stream = relay.openedStreams.last;
      stream.injectStreamReady('proj-a');
      final transport = await opening;
      return (stream, transport);
    }

    /// This project's own `state.snapshot` requests seen on [stream] so far,
    /// decoded, in order.
    List<Map<String, dynamic>> snapshotRequestsOn(FakePeerStream stream) => [
      for (final record in stream.sent)
        if ((jsonDecode(utf8.decode(record)) as Map<String, dynamic>)['type'] ==
            'request' &&
            (jsonDecode(utf8.decode(record))
                    as Map<String, dynamic>)['method'] ==
                'state.snapshot')
          jsonDecode(utf8.decode(record)) as Map<String, dynamic>,
    ];

    test('a project stream pulls the durable state with the tree excluded, '
        'and never asks for the tree in a round trip of its own', () async {
      // Creating the control transport seeds the control plane's own pull.
      expect(session.control.projectId, isNull);
      final (stream, _) = await openBoundProject();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final sent = snapshotRequestsOn(stream);
      expect(sent, hasLength(1));
      expect(sent.single['params'], {
        'types': ['*'],
        'exclude': ['tree:full'],
      });
      stream.injectJson(reply(sent.single['requestId'] as String, [status]));

      // Nothing follows the landed pull — in particular no tree pull on the
      // longer cadence the tree used to get.
      await Future<void>.delayed(_baseTimeout * 9);
      final later = snapshotRequestsOn(stream);
      expect(later, hasLength(1));
      expect(
        later.where((r) => isTreePull((r['params'] as Map).cast())),
        isEmpty,
      );

      // The control plane's own pull never asks for the tree either.
      final control = snapshotRequests();
      expect(control, isNotEmpty);
      expect(control.where((r) => isTreePull(r.params)), isEmpty);
    });

    test('a tree an older bridge folds into the reply is delivered and cached '
        'like any other frame', () async {
      final (stream, transport) = await openBoundProject();
      final seen = <String>[];
      transport.messages.listen((m) => seen.add(m.json['type'] as String));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final sent = snapshotRequestsOn(stream);
      // A bridge that predates `exclude` answers with the tree in it too.
      stream.injectJson(
        reply(sent.single['requestId'] as String, [status, tree]),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(seen, ['agent:status', 'tree:full']);

      final replayed = <String>[];
      transport.messages.listen((m) => replayed.add(m.json['type'] as String));
      await Future<void>.delayed(Duration.zero);
      expect(replayed, unorderedEquals(['agent:status', 'tree:full']));
    });
  });
}
