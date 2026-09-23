// The unbound-stream drop is diagnosed from app.log, on sessions nobody armed
// a capture for — so the fields that separate its causes have to survive with
// no netTap attached, including through the reassembler.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

import 'support/fake_live_relay.dart';

const _ghostEnvelope = {
  's': 'ghost-stream',
  'm': {'type': 'terminal:output'},
};

/// Every `stream-unbound` in [relay]'s outbox.
List<Map<String, dynamic>> _notices(FakeLiveRelay relay) {
  final out = <Map<String, dynamic>>[];
  for (final f in relay.sent) {
    final env = jsonDecode(decodeFromPhone(f.payload)) as Map<String, dynamic>;
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
    late MachineSession session;
    late List<Map<String, Object?>?> warns;

    setUp(() async {
      relay = FakeLiveRelay();
      warns = [];
      session = await establishSession(
        relay,
        handshaker: FakeHandshaker(),
        logger: (level, message, {fields}) {
          if (message == 'dropping inbound frame for unknown stream') {
            warns.add(fields);
          }
        },
      );
    });

    tearDown(() async {
      await session.dispose();
      await relay.closeStreams();
    });

    Future<void> inject(Uint8List payload) async {
      relay.inject(IncomingPeerFrame(channel: 'control', payload: payload));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    test('carries the frame id and the epoch it arrived under', () async {
      final payload = encodeFromAgent(jsonEncode(_ghostEnvelope));
      await inject(payload);

      final w = warns.single!;
      expect(w['frameId'], frameIdOf(payload));
      // One establishment, so both read 1 — spelled out rather than compared to
      // each other, which two nulls would also satisfy.
      expect(w['openedUnder'], 1);
      expect(w['sessionEpoch'], 1);
    });

    test(
      'a reassembled message names the fragment that completed it',
      () async {
        final frames = buildFragments(
          jsonEncode(_ghostEnvelope),
          'ghost-1',
          null,
          24,
        );
        expect(frames.length, greaterThan(1));
        final encoded = [for (final f in frames) encodeFromAgent(f)];

        // Out of index order so the completing fragment is not also the first:
        // the two would be indistinguishable if it were.
        await inject(encoded[1]);
        for (var i = 2; i < encoded.length; i++) {
          await inject(encoded[i]);
        }
        await inject(encoded[0]);

        final w = warns.single!;
        expect(w['frameId'], frameIdOf(encoded[0]));
        expect(w['openedUnder'], 1);
      },
    );

    test('answers the agent with stream-unbound, once per id per window', () async {
      // The log records that we are losing frames; this is what asks the agent
      // to stop sending them. Nothing else does — the agent's `stream-invalid`
      // covers only the opposite direction, so without this a live PTY on a
      // stream we never bound drops a frame per frame for as long as it runs.
      Future<void> injectGhost() =>
          inject(encodeFromAgent(jsonEncode(_ghostEnvelope)));

      for (var i = 0; i < 4; i++) {
        await injectGhost();
      }

      final notices = _notices(relay);

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

  test('a fresh MachineSession — as the supervisor builds after a redial — '
      'starts with no muted streams of its own', () async {
    // The agent clears every mute on a fresh session (`notifyPeerOnline` in
    // bridge/src/stream-mux.ts); this side's own throttle state has to agree,
    // or a stream that just resumed flooding a NEW session finds nothing left
    // asking it to stop. There is no in-place rekey any more — "fresh session"
    // now means a brand-new MachineSession over a brand-new link, which is
    // exactly what the supervisor builds on redial.
    final relayA = FakeLiveRelay();
    final sessionA = await establishSession(relayA, handshaker: FakeHandshaker());
    relayA.inject(
      IncomingPeerFrame(
        channel: 'control',
        payload: encodeFromAgent(jsonEncode(_ghostEnvelope)),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(_notices(relayA), hasLength(1));
    await sessionA.dispose();
    await relayA.closeStreams();

    final relayB = FakeLiveRelay();
    final sessionB = await establishSession(relayB, handshaker: FakeHandshaker());
    relayB.inject(
      IncomingPeerFrame(
        channel: 'control',
        payload: encodeFromAgent(jsonEncode(_ghostEnvelope)),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(
      _notices(relayB),
      hasLength(1),
      reason: "the new session's throttle map starts empty, independent of A's",
    );

    await sessionB.dispose();
    await relayB.closeStreams();
  });
}
