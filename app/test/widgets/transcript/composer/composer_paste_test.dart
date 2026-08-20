import 'dart:typed_data';

import 'package:fleather/fleather.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/services/clipboard_image_reader.dart';
import 'package:antgrid/widgets/transcript/composer/composer_paste.dart';

void main() {
  PastedImage image() => PastedImage(
    fileName: 'pasted-image.png',
    bytes: Uint8List.fromList(const [1, 2, 3]),
    mimeType: 'image/png',
  );

  Future<FleatherClipboardData?> text(String value) async =>
      FleatherClipboardData(plainText: value);

  group('resolveComposerPaste', () {
    test('image → attached, nothing inserted, text never read', () async {
      final attached = <PastedImage>[];
      var textRead = false;
      final result = await resolveComposerPaste(
        readImage: () async => image(),
        onImagePasted: attached.add,
        readText: () async {
          textRead = true;
          return text('ignored');
        },
      );
      expect(result, isNull, reason: 'null inserts nothing into the document');
      expect(attached, hasLength(1));
      expect(attached.single.mimeType, 'image/png');
      expect(textRead, isFalse);
    });

    test('image wins over text the clipboard also carries', () async {
      final attached = <PastedImage>[];
      final result = await resolveComposerPaste(
        readImage: () async => image(),
        onImagePasted: attached.add,
        readText: () => text('<img src=...>'),
      );
      expect(result, isNull);
      expect(attached, hasLength(1));
    });

    test('no image → text pastes unchanged', () async {
      final attached = <PastedImage>[];
      final result = await resolveComposerPaste(
        readImage: () async => null,
        onImagePasted: attached.add,
        readText: () => text('hello'),
      );
      expect(result?.plainText, 'hello');
      expect(attached, isEmpty);
    });

    test('reader throws → reported, and paste still falls back to text',
        () async {
      final errors = <Object>[];
      final result = await resolveComposerPaste(
        readImage: () async => throw const ClipboardImageException('boom'),
        onImagePasted: (_) => fail('must not attach on a failed read'),
        readText: () => text('hello'),
        onImageReadError: (e, _) => errors.add(e),
      );
      expect(result?.plainText, 'hello');
      expect(errors, hasLength(1));
    });

    test('empty clipboard stays empty', () async {
      final result = await resolveComposerPaste(
        readImage: () async => null,
        onImagePasted: (_) => fail('nothing to attach'),
        readText: () async => null,
      );
      expect(result, isNull);
    });
  });

  group('resolvePastedImageFileName', () {
    test('raw bitmap has no name → synthetic one', () {
      expect(resolvePastedImageFileName(null, 'png'), 'pasted-image.png');
      expect(resolvePastedImageFileName('   ', 'png'), 'pasted-image.png');
    });

    test('copied file keeps its own name', () {
      expect(resolvePastedImageFileName('diagram.png', 'png'), 'diagram.png');
    });

    test('extension match is case-insensitive', () {
      expect(resolvePastedImageFileName('Shot.PNG', 'png'), 'Shot.PNG');
    });

    test('an alternate spelling of the extension is left alone', () {
      expect(
        resolvePastedImageFileName('photo.jpeg', 'jpg', altExts: const ['jpeg']),
        'photo.jpeg',
      );
    });

    test('name lacking the format extension gets it appended', () {
      expect(resolvePastedImageFileName('screenshot', 'png'), 'screenshot.png');
    });
  });
}
