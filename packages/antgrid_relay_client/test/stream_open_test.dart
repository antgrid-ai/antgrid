import 'dart:convert';
import 'dart:typed_data';

import 'package:antgrid_relay_client/src/models/stream_open.dart';
import 'package:test/test.dart';

Uint8List _json(Object? value) => Uint8List.fromList(utf8.encode(jsonEncode(value)));

void main() {
  group('StreamRefused.tryDecode', () {
    test('accepts a valid record', () {
      const refused = StreamRefused(
        code: StreamRefusedCode.notReady,
        message: 'core still starting',
      );

      final decoded = StreamRefused.tryDecode(_json(refused.toJson()));

      expect(decoded, refused);
    });

    test('returns null for bad UTF-8', () {
      final bytes = Uint8List.fromList([0xff, 0xfe, 0xfd]);

      expect(StreamRefused.tryDecode(bytes), isNull);
    });

    test('returns null for bad JSON', () {
      final bytes = Uint8List.fromList(utf8.encode('{not json'));

      expect(StreamRefused.tryDecode(bytes), isNull);
    });

    test('returns null for a non-map', () {
      expect(StreamRefused.tryDecode(_json(['stream:refused'])), isNull);
      expect(StreamRefused.tryDecode(_json('stream:refused')), isNull);
      expect(StreamRefused.tryDecode(_json(42)), isNull);
    });

    test('returns null for a wrong field type', () {
      expect(
        StreamRefused.tryDecode(
          _json({'type': 'stream:refused', 'code': 7, 'message': 'x'}),
        ),
        isNull,
      );
      expect(
        StreamRefused.tryDecode(
          _json({
            'type': 'stream:refused',
            'code': 'NOT_READY',
            'message': 7,
          }),
        ),
        isNull,
      );
    });

    test('returns null for an unknown code', () {
      expect(
        StreamRefused.tryDecode(
          _json({
            'type': 'stream:refused',
            'code': 'SOMETHING_ELSE',
            'message': 'x',
          }),
        ),
        isNull,
      );
    });
  });
}
