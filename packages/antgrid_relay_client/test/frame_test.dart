import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:antgrid_relay_client/src/frame.dart';

void main() {
  group('encodePeerFrame', () {
    test('produces [0x03][kind][len BE u16][header][payload] layout', () {
      final header = {'type': 'message', 'channel': 'control'};
      final payload = Uint8List.fromList([0xde, 0xad, 0xbe, 0xef]);

      final frame = encodePeerFrame(header, payload, FrameKind.sealed);

      expect(frame[0], 0x03);
      expect(frame[1], 0x00); // FrameKind.sealed
      final headerLen = (frame[2] << 8) | frame[3];
      final headerJson = utf8.decode(frame.sublist(4, 4 + headerLen));
      expect(jsonDecode(headerJson), header);
      expect(frame.sublist(4 + headerLen).toList(), [0xde, 0xad, 0xbe, 0xef]);
    });

    test('handshake kind is written to the kind byte', () {
      final frame = encodePeerFrame(
        {'type': 'message', 'channel': 'control'},
        Uint8List(0),
        FrameKind.handshake,
      );
      expect(frame[0], 0x03);
      expect(frame[1], 0x01); // FrameKind.handshake
    });

    test('rejects serialized peer identity and other extra header fields', () {
      final header = {'type': 'message', 'to': 'agent-1', 'channel': 'control'};
      expect(
        () => encodePeerFrame(header, Uint8List(0), FrameKind.sealed),
        throwsA(
          isA<FrameException>().having(
            (e) => e.reason,
            'reason',
            FrameErrorReason.badHeader,
          ),
        ),
      );
    });
  });

  group('decodePeerFrame', () {
    test('round-trips both kinds preserving header, payload and kind', () {
      final header = {'type': 'message', 'channel': 'preview'};
      final payload = Uint8List.fromList(List.generate(1024, (i) => i & 0xff));

      for (final kind in FrameKind.values) {
        final frame = encodePeerFrame(header, payload, kind);
        final decoded = decodePeerFrame(frame);
        expect(decoded.header, header);
        expect(decoded.payload, payload);
        expect(decoded.kind, kind);
      }
    });

    test('handles empty payload', () {
      final header = {'type': 'message', 'channel': 'control'};
      final decoded = decodePeerFrame(
        encodePeerFrame(header, Uint8List(0), FrameKind.sealed),
      );
      expect(decoded.payload.length, 0);
      expect(decoded.kind, FrameKind.sealed);
    });

    test('rejects frame shorter than 4 bytes', () {
      expect(
        () => decodePeerFrame(Uint8List.fromList([0x03, 0x00, 0x00])),
        throwsA(
          isA<FrameException>().having(
            (e) => e.reason,
            'reason',
            FrameErrorReason.truncated,
          ),
        ),
      );
    });

    test('rejects v2 with badVersion', () {
      expect(
        () => decodePeerFrame(Uint8List.fromList([0x02, 0x00, 0x00, 0x00])),
        throwsA(
          isA<FrameException>().having(
            (e) => e.reason,
            'reason',
            FrameErrorReason.badVersion,
          ),
        ),
      );
    });

    test('rejects unknown kind byte with badKind', () {
      expect(
        () => decodePeerFrame(Uint8List.fromList([0x03, 0x7f, 0x00, 0x00])),
        throwsA(
          isA<FrameException>().having(
            (e) => e.reason,
            'reason',
            FrameErrorReason.badKind,
          ),
        ),
      );
    });

    test('rejects header_len > 1024', () {
      // [version, kind, headerLen BE u16 = 0x0401 = 1025]
      final buf = Uint8List.fromList([0x03, 0x00, 0x04, 0x01]);
      expect(
        () => decodePeerFrame(buf),
        throwsA(
          isA<FrameException>().having(
            (e) => e.reason,
            'reason',
            FrameErrorReason.headerTooLarge,
          ),
        ),
      );
    });
  });
}
