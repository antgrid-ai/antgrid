// MachineSession session-stream wire coverage. Every record is one bare
// JSON body — a session frame or a control-plane `AbMessage`, told apart by
// the JSON `type` alone (`isSessionFrameType`). A bare `ping`/`pong` is not a
// session-frame name, so a record naming it is control plane, never liveness.
import 'dart:async';
import 'dart:convert';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

import 'support/fake_live_relay.dart';

/// A capture that just collects, standing in for `app/lib/util/netwatch.dart`
/// — see `netwatch_tap_test.dart` for the same shape.
class _Capture {
  final events = <Map<String, Object?>>[];
  RelayNetTap get tap => events.add;

  Iterable<Map<String, Object?>> get frames =>
      events.where((e) => e['op'] != 'annotate');
  Iterable<Map<String, Object?>> get drops =>
      frames.where((e) => e['kind'] == 'drop');
}

void main() {
  late FakeLiveRelay relay;
  late FakeHandshaker handshaker;
  late MachineSession session;
  late _Capture capture;

  setUp(() async {
    capture = _Capture();
    relay = FakeLiveRelay(netTap: capture.tap);
    handshaker = FakeHandshaker();
    session = await establishSession(relay, handshaker: handshaker);
    capture.events.clear(); // establishment traffic is not what is under test
  });

  tearDown(() async {
    await session.dispose();
    await relay.closeStreams();
  });

  test('E1: a bare AbMessage dispatches on the control plane', () async {
    final control = session.control;
    final seen = <Map<String, dynamic>>[];
    final sub = control.messages.listen((m) => seen.add(m.json));

    relay.injectRecord(
      encodeFromAgent(jsonEncode({'type': 'project:list', 'projects': []})),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(seen, hasLength(1));
    expect(seen.single['type'], 'project:list');
    await sub.cancel();
  });

  test('E2: a `{m: …}` body is dropped unrecognized-plaintext', () async {
    relay.injectRecord(
      encodeFromAgent(
        jsonEncode({
          'm': {'type': 'project:list'},
        }),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final drop = capture.drops.single;
    expect(drop['reason'], 'unrecognized-plaintext');
  });

  test(
    'E3: an old-name ping from the bridge is control plane, not a session '
    'frame — no session:pong answers it',
    () async {
      final control = session.control;
      final seen = <Map<String, dynamic>>[];
      final sub = control.messages.listen((m) => seen.add(m.json));
      // Let the control transport's own auto `state.snapshot` pull land
      // first, so it isn't counted as a reply to the ping below.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final sentBefore = relay.sent.length;

      relay.injectRecord(encodeFromAgent(jsonEncode({'type': 'ping'})));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(
        seen.map((j) => j['type']),
        contains('ping'),
        reason: 'an old-name ping is an ordinary control-plane AbMessage',
      );
      expect(
        relay.sent.skip(sentBefore),
        isEmpty,
        reason: 'only a session:ping triggers the liveness pong',
      );
      await sub.cancel();
    },
  );

  test('E4: a session:ping is answered with exactly one session:pong', () async {
    final sentBefore = relay.sent.length;
    relay.injectRecord(encodeFromAgent(jsonEncode({'type': kSessionPing})));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final pongs = relay.sent
        .skip(sentBefore)
        .where((f) => f.json['type'] == kSessionPong);
    expect(pongs, hasLength(1));
  });

  test('E6: sendOnSession writes the bare message with no header', () async {
    await session.sendOnSession({'type': 'project:list'}, 'control');

    expect(relay.sent, hasLength(1));
    expect(relay.sent.single.json, {'type': 'project:list'});
  });

  test('E7: a send whose link write throws does not wedge the sends behind it', () async {
    final gate = Completer<void>();
    relay.sendGate = gate;
    final first = session.sendOnSession({'type': 'project:list'}, 'control');
    final second = session.sendOnSession({'type': 'agent:list'}, 'control');
    gate.completeError(StateError('native write failed'));

    await expectLater(first, throwsStateError);
    await second.timeout(const Duration(seconds: 2));
    expect(relay.sent, hasLength(1));
    expect(relay.sent.single.json, {'type': 'agent:list'});
  });
}
