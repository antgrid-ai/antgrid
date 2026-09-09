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
  });
}
