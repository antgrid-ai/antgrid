// app/test/widgets/file_viewer_kind_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/widgets/file_viewer_kind.dart';

void main() {
  group('fileViewerKindFor', () {
    test('markdown by extension', () {
      expect(
        fileViewerKindFor('docs/readme.md', null),
        FileViewerKind.markdown,
      );
      expect(fileViewerKindFor('A.MARKDOWN', null), FileViewerKind.markdown);
    });
    test('svg by extension', () {
      expect(fileViewerKindFor('icons/logo.svg', null), FileViewerKind.svg);
    });
    test('image from base64 mimeType', () {
      expect(
        fileViewerKindFor('a.png', 'base64', 'image/png'),
        FileViewerKind.image,
      );
      // Bytes not present yet (still text-encoded) → code, not image.
      expect(
        fileViewerKindFor('a.png', 'utf8', 'image/png'),
        FileViewerKind.code,
      );
      // base64 but no mimeType → defensive fallback to code, not a guessed image.
      expect(fileViewerKindFor('a.png', 'base64'), FileViewerKind.code);
    });
    test('pdf from base64 mimeType', () {
      expect(
        fileViewerKindFor('a.pdf', 'base64', 'application/pdf'),
        FileViewerKind.pdf,
      );
      expect(
        fileViewerKindFor('a.pdf', 'utf8', 'application/pdf'),
        FileViewerKind.code,
      );
    });
    test('everything else is code', () {
      expect(fileViewerKindFor('main.dart', 'utf8'), FileViewerKind.code);
      expect(fileViewerKindFor('noext', null), FileViewerKind.code);
    });
  });
}
