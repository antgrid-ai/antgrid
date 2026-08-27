// The `state.snapshot` pull is the only carrier of a checkout's durable
// `agent:status` for a relay app, and a reply that lands after the RPC's
// timeout is discarded like any late response — so a single fixed wait lost a
// large or slow reply silently, with nothing left to re-send it until the next
// establishment. The pull must retry a timeout, with a longer wait each time,
// and stop retrying once the reply lands, once the failure is one a retry
// cannot change, or once the transport is gone.
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
    );
    session.start();
    await session.ensureEstablished();
  });

  tearDown(() async {
    await session.dispose();
    await relay.closeStreams();
  });

  /// Every control-plane `state.snapshot` requestId sent so far, in order.
  Future<List<String>> snapshotRequestIds() async {
    final out = <String>[];
    for (final f in relay.sent) {
      final pt = await _openFromPhone(keys, f.payload);
      if (pt == null) continue;
      final e = jsonDecode(pt) as Map<String, dynamic>;
      final m = e['m'];
      if (m is Map &&
          m['type'] == 'request' &&
          m['method'] == 'state.snapshot' &&
          !e.containsKey('s')) {
        out.add(m['requestId'] as String);
      }
    }
    return out;
  }

  Future<void> injectControl(Map<String, dynamic> m) async {
    relay.inject(
      IncomingRouteMessage(
        from: 'machine-1',
        channel: 'control',
        kind: FrameKind.sealed,
        payload: await _sealFromAgent(keys, jsonEncode({'m': m})),
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
}
