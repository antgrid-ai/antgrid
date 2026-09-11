// The unbound-stream drop is diagnosed from app.log, on sessions nobody armed
// a capture for — so the fields that separate its causes have to survive with
// no netTap attached, including through the reassembler.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

import 'support/fake_live_relay.dart';

Future<Uint8List> _sealFromAgent(SessionKeys keys, String plaintext) =>
    E2eTransportDart(sendKey: keys.a2p, recvKey: keys.p2a).seal(plaintext);

const _ghostEnvelope = {
  's': 'ghost-stream',
  'm': {'type': 'terminal:output'},
};

/// Every `stream-unbound` in [relay]'s outbox that opens under [keys]. A frame
/// sealed under a superseded epoch simply will not open, which is what lets a
/// test count one session's notices without draining the outbox first.
Future<List<Map<String, dynamic>>> _noticesUnder(
  FakeLiveRelay relay,
  SessionKeys keys,
) async {
  final out = <Map<String, dynamic>>[];
  for (final f in relay.sent) {
    final plain = await E2eTransportDart(
      sendKey: keys.a2p,
      recvKey: keys.p2a,
    ).open(f.payload);
    if (plain == null) continue;
    final env = jsonDecode(plain) as Map<String, dynamic>;
    // The notice is a control-plane statement about the stream table, so it
    // rides stream "0" — sending it ON the dead stream would be circular.
    if (env['s'] != null) continue;
    final m = env['m'];
    if (m is Map<String, dynamic> && m['type'] == 'stream-unbound') out.add(m);
  }
  return out;
}

void main() {
  group('unknown-stream warn without a capture armed', () {
    late FakeLiveRelay relay;
    late SessionKeys keys;
    late MachineSession session;
    late List<Map<String, Object?>?> warns;

    setUp(() async {
      relay = FakeLiveRelay();
      keys = fixedKeys(1);
      warns = [];
      session = MachineSession(
        relay: relay,
        machineDeviceId: 'machine-1',
        handshaker: FakeHandshaker(keys),
        logger: (level, message, {fields}) {
          if (message == 'dropping inbound frame for unknown stream') {
            warns.add(fields);
          }
        },
      );
      session.start();
      await session.ensureEstablished();
    });

    tearDown(() async {
      await session.dispose();
      await relay.closeStreams();
    });

    Future<void> inject(Uint8List payload) async {
      relay.inject(
        IncomingRouteMessage(
          from: 'machine-1',
          channel: 'control',
          kind: FrameKind.sealed,
          payload: payload,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    test('carries the frame id and the epoch it arrived under', () async {
      final payload = await _sealFromAgent(keys, jsonEncode(_ghostEnvelope));
      await inject(payload);

      final w = warns.single!;
      expect(w['frameId'], frameIdOf(payload, FrameKind.sealed));
      // One establishment, so both read 1 — spelled out rather than compared to
      // each other, which two nulls would also satisfy.
      expect(w['openedUnder'], 1);
      expect(w['sessionEpoch'], 1);
    });

    test('a reassembled message names the fragment that completed it', () async {
      final frames = buildFragments(
        jsonEncode(_ghostEnvelope),
        'ghost-1',
        null,
        24,
      );
      expect(frames.length, greaterThan(1));
      final sealed = [for (final f in frames) await _sealFromAgent(keys, f)];

      // Out of index order so the completing fragment is not also the first:
      // the two would be indistinguishable if it were.
      await inject(sealed[1]);
      for (var i = 2; i < sealed.length; i++) {
        await inject(sealed[i]);
      }
      await inject(sealed[0]);

      final w = warns.single!;
      expect(w['frameId'], frameIdOf(sealed[0], FrameKind.sealed));
      expect(w['openedUnder'], 1);
    });

    test('answers the agent with stream-unbound, once per id per window', () async {
      // The log records that we are losing frames; this is what asks the agent
      // to stop sending them. Nothing else does — the agent's `stream-invalid`
      // covers only the opposite direction, so without this a live PTY on a
      // stream we never bound drops a frame per frame for as long as it runs.
      Future<void> injectGhost() async =>
          inject(await _sealFromAgent(keys, jsonEncode(_ghostEnvelope)));

      for (var i = 0; i < 4; i++) {
        await injectGhost();
      }

      final notices = await _noticesUnder(relay, keys);

      expect(notices, hasLength(1));
      expect(notices.single['streamId'], 'ghost-stream');
      // `id` is z.string().uuid() on the wire (bridge/src/protocol.ts) and this
      // package carries no uuid dependency, so the shape is worth pinning.
      expect(
        notices.single['id'],
        matches(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      );
      // The notice is a request, not a repair: all four frames were still
      // dropped. The log is throttled on its own window, so the remaining three
      // are carried in the suppressed count and reported by the next line.
      expect(warns, hasLength(1));
      expect(warns.single!['framesDropped'], 1);
    });
  });

  test('a rekey re-arms the notice throttle', () async {
    // The agent clears every mute on a fresh session (`notifyPeerOnline` in
    // bridge/src/stream-mux.ts), so a throttle carried across that boundary
    // would leave a stream it just resumed flooding with nothing left to ask
    // it to stop. A rekey is what a flooded control channel produces — three
    // timed-out RPCs re-handshake — so the loop would re-open its own cause.
    final relay = FakeLiveRelay();
    final handshaker = FakeHandshaker.sequence([fixedKeys(1), fixedKeys(2)]);
    final session = MachineSession(
      relay: relay,
      machineDeviceId: 'm1',
      handshaker: handshaker,
    );
    session.start();
    await session.ensureEstablished();

    Future<void> ghost(SessionKeys k) async {
      relay.inject(
        IncomingRouteMessage(
          from: 'm1',
          channel: 'control',
          kind: FrameKind.sealed,
          payload: await _sealFromAgent(k, jsonEncode(_ghostEnvelope)),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    await ghost(fixedKeys(1));
    expect(await _noticesUnder(relay, fixedKeys(1)), hasLength(1));

    relay.presence(false);
    relay.presence(true);
    for (var i = 0; i < 50 && handshaker.performCalls < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(handshaker.performCalls, 2);

    // Well inside _unboundNoticeInterval, so only the re-arm can explain a
    // second notice for the same id.
    await ghost(fixedKeys(2));
    expect(await _noticesUnder(relay, fixedKeys(2)), hasLength(1));

    await session.dispose();
    await relay.closeStreams();
  });
}
