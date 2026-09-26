// The `state.snapshot` pull is the only carrier of a checkout's durable
// `agent:status` for a relay app. It is a SINGLE request under one long
// deadline (`kSnapshotPullDeadline`): a reply that lands after the caller's
// own wait but before that deadline is still applied, since the request is
// still outstanding, and a pull superseded by a fresher one discards whatever
// its own reply turns out to be.
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

  /// Every `state.snapshot` request the control plane has sent so far, in
  /// order. A project's own pull rides its own native stream (Stage A A4) and
  /// never reaches [relay.sent] at all.
  List<({String id, Map<String, dynamic> params})> snapshotRequests() {
    final out = <({String id, Map<String, dynamic> params})>[];
    for (final f in relay.sent) {
      if (f.kind != kPeerFrameMessage) continue;
      final pt = decodeFromPhone(f.payload);
      final m = jsonDecode(pt) as Map<String, dynamic>;
      if (m['type'] == 'request' && m['method'] == 'state.snapshot') {
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

  void injectControl(Map<String, dynamic> m) {
    relay.injectFrame(encodeFromAgent(jsonEncode(m)));
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

  test('a timed-out pull sends exactly one request', () async {
    session.control;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(snapshotRequestIds(), hasLength(1));

    // Well past the caller's own wait: nothing follows it — the request's own
    // deadline governs the one outstanding pull.
    await Future<void>.delayed(_baseTimeout * 6);
    expect(snapshotRequestIds(), hasLength(1));
  });

  test('a pull whose own deadline expires is not re-asked', () async {
    final shortRelay = FakeLiveRelay();
    final shortSession = await establishSession(
      shortRelay,
      handshaker: FakeHandshaker(),
      snapshotTimeout: _baseTimeout,
      snapshotDeadline: _baseTimeout * 3,
    );
    int pulls() => shortRelay.sent.where((f) {
      if (f.kind != kPeerFrameMessage) return false;
      final m = jsonDecode(decodeFromPhone(f.payload)) as Map<String, dynamic>;
      return m['type'] == 'request' && m['method'] == 'state.snapshot';
    }).length;

    shortSession.control;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(pulls(), 1);
    // Well past the request's own deadline: the timeout ends the pull, and
    // the next establishment, bind or refreshDurableState is the next ask.
    await Future<void>.delayed(_baseTimeout * 10);
    expect(pulls(), 1);
    expect(shortRelay.closeCalled, isFalse);

    await shortSession.dispose();
    await shortRelay.closeStreams();
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

  test(
    "a reply after the caller's wait but before the deadline is applied",
    () async {
      final control = session.control;
      final seen = <Map<String, dynamic>>[];
      final sub = control.messages.listen((m) => seen.add(m.json));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final ids = snapshotRequestIds();
      expect(ids, hasLength(1));

      // Well past the caller's own wait, nowhere near the request's own
      // deadline (`kSnapshotPullDeadline`).
      await Future<void>.delayed(_baseTimeout * 4);
      injectControl(snapshotReply(ids.single));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(
        seen.map((j) => j['type']),
        contains('agent:projects'),
        reason: 'the pull is still outstanding under its own deadline even '
            "once the caller's own wait has elapsed",
      );
      await sub.cancel();

      // And nothing else was ever sent to re-ask for it.
      expect(snapshotRequestIds(), hasLength(1));
    },
  );

  test("a superseded pull's reply is discarded", () async {
    final control = session.control;
    final seen = <Map<String, dynamic>>[];
    final sub = control.messages.listen((m) => seen.add(m.json));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(snapshotRequestIds(), hasLength(1), reason: 'pull A');

    unawaited(control.refreshDurableState()); // pull B supersedes pull A
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final ids = snapshotRequestIds();
    expect(ids, hasLength(2));

    injectControl(snapshotReply(ids[0])); // A's late reply
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(
      seen,
      isEmpty,
      reason: "a superseded pull's reply must never be applied",
    );

    injectControl(snapshotReply(ids[1])); // B's reply
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(seen.map((j) => j['type']), contains('agent:projects'));
    await sub.cancel();
  });

  test('disposing mid-pull applies nothing', () async {
    final control = session.control;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final ids = snapshotRequestIds();
    expect(ids, hasLength(1));

    await control.dispose();
    injectControl(snapshotReply(ids.single));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(control.snapshotCache, isEmpty);
  });

  test('an answered error sends no second pull', () async {
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
