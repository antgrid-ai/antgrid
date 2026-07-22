import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:antgrid_relay_client/src/frame.dart';

void main() {
  group('encodeRouteFrame', () {
    test('produces [0x02][kind][len BE u16][header][payload] layout', () {
      final header = {'type': 'message', 'to': 'agent-1', 'channel': 'control'};
      final payload = Uint8List.fromList([0xde, 0xad, 0xbe, 0xef]);

      final frame = encodeRouteFrame(header, payload, FrameKind.sealed);

      expect(frame[0], 0x02);
      expect(frame[1], 0x00); // FrameKind.sealed
      final headerLen = (frame[2] << 8) | frame[3];
      final headerJson = utf8.decode(frame.sublist(4, 4 + headerLen));
      expect(jsonDecode(headerJson), header);
      expect(frame.sublist(4 + headerLen).toList(), [0xde, 0xad, 0xbe, 0xef]);
    });

    test('handshake kind is written to the kind byte', () {
      final frame = encodeRouteFrame(
        {'type': 'message', 'to': 'a', 'channel': 'control'},
        Uint8List(0),
        FrameKind.handshake,
      );
      expect(frame[0], 0x02);
      expect(frame[1], 0x01); // FrameKind.handshake
    });

    test('rejects headers larger than 1024 bytes', () {
      final header = {
        'type': 'message',
        'to': 'a' * 2000,
        'channel': 'control',
      };
      expect(
        () => encodeRouteFrame(header, Uint8List(0), FrameKind.sealed),
        throwsA(isA<FrameException>()
            .having((e) => e.reason, 'reason', FrameErrorReason.headerTooLarge)),
      );
    });
  });

  group('decodeRouteFrame', () {
    test('round-trips both kinds preserving header, payload and kind', () {
      final header = {'type': 'message', 'to': 'agent-1', 'channel': 'preview'};
      final payload = Uint8List.fromList(List.generate(1024, (i) => i & 0xff));

      for (final kind in FrameKind.values) {
        final frame = encodeRouteFrame(header, payload, kind);
        final decoded = decodeRouteFrame(frame);
        expect(decoded.header, header);
        expect(decoded.payload, payload);
        expect(decoded.kind, kind);
      }
    });

    test('handles empty payload', () {
      final header = {'type': 'message', 'to': 'a', 'channel': 'control'};
      final decoded = decodeRouteFrame(
        encodeRouteFrame(header, Uint8List(0), FrameKind.sealed),
      );
      expect(decoded.payload.length, 0);
      expect(decoded.kind, FrameKind.sealed);
    });

    test('rejects frame shorter than 4 bytes', () {
      expect(
        () => decodeRouteFrame(Uint8List.fromList([0x02, 0x00, 0x00])),
        throwsA(isA<FrameException>()
            .having((e) => e.reason, 'reason', FrameErrorReason.truncated)),
      );
    });

    test('rejects old v1 version byte (0x01) with badVersion', () {
      expect(
        () => decodeRouteFrame(Uint8List.fromList([0x01, 0x00, 0x00, 0x00])),
        throwsA(isA<FrameException>()
            .having((e) => e.reason, 'reason', FrameErrorReason.badVersion)),
      );
    });

    test('rejects unknown kind byte with badKind', () {
      expect(
        () => decodeRouteFrame(Uint8List.fromList([0x02, 0x7f, 0x00, 0x00])),
        throwsA(isA<FrameException>()
            .having((e) => e.reason, 'reason', FrameErrorReason.badKind)),
      );
    });

    test('rejects header_len > 1024', () {
      // [version, kind, headerLen BE u16 = 0x0401 = 1025]
      final buf = Uint8List.fromList([0x02, 0x00, 0x04, 0x01]);
      expect(
        () => decodeRouteFrame(buf),
        throwsA(isA<FrameException>()
            .having((e) => e.reason, 'reason', FrameErrorReason.headerTooLarge)),
      );
    });
  });
}
