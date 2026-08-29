// The `state.snapshot` pull is the only carrier of a checkout's durable
// `agent:status` for a relay app, and a reply that lands after the RPC's
// timeout is discarded like any late response — so a single fixed wait lost a
// large or slow reply silently, with nothing left to re-send it until the next
// establishment. The pull must retry a timeout, with a longer wait each time,
// and stop retrying once the reply lands, once the failure is one a retry
// cannot change, or once the transport is gone.
//
// It is also two pulls, split by weight: the file tree — the one unbounded
// frame — travels in a round trip of its own, so a slow or lost tree can cost
// the explorer but never the terminal's status.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

import 'support/fake_live_relay.dart';

Future<String?> _openFromPhone(SessionKeys keys, Uint8List payload) =>
    E2eTransportDart(sendKey: keys.a2p, recvKey: keys.p2a).open(payload);

Future<Uint8List> _sealFromAgent(SessionKeys keys, String plaintext) =>
    E2eTransportDart(sendKey: keys.a2p, recvKey: keys.p2a).seal(plaintext);

const _baseTimeout = Duration(milliseconds: 40);

void main() {
  late FakeLiveRelay relay;
  late FakeHandshaker handshaker;
  late SessionKeys keys;
  late MachineSession session;

  setUp(() async {
    relay = FakeLiveRelay();
    keys = fixedKeys(1);
    handshaker = FakeHandshaker(keys);
    session = MachineSession(
      relay: relay,
      machineDeviceId: 'machine-1',
      handshaker: handshaker,
      snapshotTimeout: _baseTimeout,
      treeSnapshotTimeout: _baseTimeout,
    );
    session.start();
    await session.ensureEstablished();
  });

  tearDown(() async {
    await session.dispose();
    await relay.closeStreams();
  });

  /// Every `state.snapshot` request sent so far on [stream] (null: the
  /// control plane), in order.
  Future<List<({String id, Map<String, dynamic> params})>> snapshotRequests({
    String? stream,
  }) async {
    final out = <({String id, Map<String, dynamic> params})>[];
    for (final f in relay.sent) {
      final pt = await _openFromPhone(keys, f.payload);
      if (pt == null) continue;
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
  Future<List<String>> snapshotRequestIds() async => [
    for (final r in await snapshotRequests()) r.id,
  ];

  bool isTreePull(Map<String, dynamic> params) {
    final types = params['types'];
    return types is List && types.length == 1 && types.single == 'tree:full';
  }

  Future<void> injectControl(Map<String, dynamic> m, {String? stream}) async {
    relay.inject(
      IncomingRouteMessage(
        from: 'machine-1',
        channel: 'control',
        kind: FrameKind.sealed,
        payload: await _sealFromAgent(
          keys,
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
            {'projectId': 'proj-a', 'running': true, 'streamId': 's-42'},
          ],
        },
      ],
    },
  };

  test('a timed-out pull is retried with a longer wait, and the retry\'s '
      'reply is applied', () async {
    session.streamFor(kControlStreamId);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(await snapshotRequestIds(), hasLength(1));

    // Past the first wait: the reply never came, so a second request is out.
    await Future<void>.delayed(_baseTimeout);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final ids = await snapshotRequestIds();
    expect(ids, hasLength(2), reason: 'the timeout must be retried');

    await injectControl(snapshotReply(ids.last));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(
      session.streamIdForProject('proj-a'),
      's-42',
      reason: 'the retry\'s reply is the durable state the app runs on',
    );

    // A landed reply ends the chain — no third request, even past what the
    // doubled second wait would have allowed.
    await Future<void>.delayed(_baseTimeout * 3);
    expect(await snapshotRequestIds(), hasLength(2));
  });

  test('a reply that lands in time is not followed by a retry', () async {
    session.streamFor(kControlStreamId);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final ids = await snapshotRequestIds();
    expect(ids, hasLength(1));
    await injectControl(snapshotReply(ids.single));

    await Future<void>.delayed(_baseTimeout * 4);
    expect(await snapshotRequestIds(), hasLength(1));
  });

  test('an error the agent answers with is not retried', () async {
    session.streamFor(kControlStreamId);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final ids = await snapshotRequestIds();
    expect(ids, hasLength(1));
    // A pre-RPC agent: the answer will not change on a second ask.
    await injectControl({
      'type': 'response',
      'requestId': ids.single,
      'ok': false,
      'error': {'code': 'E_UNKNOWN_METHOD', 'message': 'no such method'},
    });

    await Future<void>.delayed(_baseTimeout * 4);
    expect(await snapshotRequestIds(), hasLength(1));
  });

  test('retries stop at the attempt cap', () async {
    session.streamFor(kControlStreamId);
    // Waits of 1x, 2x, 4x the base: well past the sum, plus slack.
    await Future<void>.delayed(_baseTimeout * 9);
    expect(await snapshotRequestIds(), hasLength(3));
  });

  test('disposing the transport ends its retries', () async {
    final st = session.streamFor(kControlStreamId);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(await snapshotRequestIds(), hasLength(1));
    await st.dispose();

    await Future<void>.delayed(_baseTimeout * 4);
    expect(await snapshotRequestIds(), hasLength(1));
  });

  group('the pull is split by weight', () {
    const stream = 's-42';

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

    test('a project stream asks for the tree in a round trip of its own; the '
        'control plane, which has none, does not', () async {
      session.streamFor(kControlStreamId);
      session.streamFor(stream);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final sent = await snapshotRequests(stream: stream);
      expect(sent, hasLength(2));
      final state = sent.where((r) => !isTreePull(r.params)).single;
      expect(state.params, {
        'types': ['*'],
        'exclude': ['tree:full'],
      });
      expect(sent.where((r) => isTreePull(r.params)), hasLength(1));

      // The control transport pulled state alone.
      final control = await snapshotRequests();
      expect(control, hasLength(1));
      expect(isTreePull(control.single.params), isFalse);
    });

    test('the status lands, and stays, whatever the tree does', () async {
      final transport = session.streamFor(stream);
      final seen = <String>[];
      transport.messages.listen((m) => seen.add(m.json['type'] as String));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final sent = await snapshotRequests(stream: stream);
      final stateId = sent.where((r) => !isTreePull(r.params)).single.id;
      final treeId = sent.where((r) => isTreePull(r.params)).single.id;

      await injectControl(reply(stateId, [status]), stream: stream);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(seen, ['agent:status'], reason: 'no waiting on the tree');

      await injectControl(reply(treeId, [tree]), stream: stream);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(seen, ['agent:status', 'tree:full']);

      // A late subscriber is served both halves from the cache: the tree
      // landing replaced only the tree.
      final replayed = <String>[];
      transport.messages.listen((m) => replayed.add(m.json['type'] as String));
      await Future<void>.delayed(Duration.zero);
      expect(replayed, unorderedEquals(['agent:status', 'tree:full']));
    });

    test(
      'a slow tree is retried alone, and never re-asks for the status',
      () async {
        session.streamFor(stream);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        final first = await snapshotRequests(stream: stream);
        final stateId = first.where((r) => !isTreePull(r.params)).single.id;
        await injectControl(reply(stateId, [status]), stream: stream);

        // Past the tree's first wait: a second tree request, no second state
        // one.
        await Future<void>.delayed(_baseTimeout);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        final sent = await snapshotRequests(stream: stream);
        expect(sent.where((r) => isTreePull(r.params)), hasLength(2));
        expect(sent.where((r) => !isTreePull(r.params)), hasLength(1));
      },
    );

    test('tree timeouts never force a rekey', () async {
      session.streamFor(stream);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final stateId = (await snapshotRequests(
        stream: stream,
      )).where((r) => !isTreePull(r.params)).single.id;
      await injectControl(reply(stateId, [status]), stream: stream);

      // Every tree attempt times out: waits of 1x, 2x, 4x the base.
      await Future<void>.delayed(_baseTimeout * 9);
      final sent = await snapshotRequests(stream: stream);
      expect(sent.where((r) => isTreePull(r.params)), hasLength(3));
      // A rekey would re-establish and start a fresh state pull on every
      // stream — the one state request is the proof none happened.
      expect(sent.where((r) => !isTreePull(r.params)), hasLength(1));
    });
  });
}
