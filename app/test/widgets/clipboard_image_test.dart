// The bridge rejects a name that sanitizes to empty with INVALID_NAME, and the
// suggested name is null for exactly the case this feature exists for (a raw
// in-memory screenshot), so the synthesized fallback is the normal path.
import 'package:antgrid/widgets/clipboard_image.dart';
import 'package:super_clipboard/super_clipboard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('synthesizes a name when the platform suggests none', () {
    expect(
      pastedImageName(null, 'png'),
      matches(r'^pasted-\d{8}-\d{6}\.png$'),
    );
  });

  test('forces the extension of the format that actually matched', () {
    // A Windows DIB read as PNG still suggests the source's own extension.
    expect(pastedImageName('diagram.bmp', 'png'), 'diagram.png');
  });

  test('reduces a name to the alphabet the bridge keeps', () {
    expect(pastedImageName(r'C:\shots\screen#1?.png', 'png'), 'screen_1_.png');
  });

  test('falls back when the suggestion sanitizes to nothing', () {
    expect(pastedImageName('...', 'jpg'), matches(r'^pasted-.*\.jpg$'));
  });

  // The format table is the gate on BOTH gestures: it decides the name and mime
  // an agent is handed, and `onDropOver` returns `DropOperation.none` when it
  // answers null, so the OS refuses a dragged image outright. Reordering or
  // emptying it is otherwise silent.
  group('imageFormatHint', () {
    (String, String)? hintFor(Set<FileFormat> available) =>
        imageFormatHint(available.contains);

    test('prefers PNG when several formats are offered', () {
      expect(hintFor({Formats.tiff, Formats.png, Formats.jpeg}),
          ('png', 'image/png'));
    });

    test('answers each non-synthesized format Linux and mobile hand over', () {
      expect(hintFor({Formats.jpeg}), ('jpg', 'image/jpeg'));
      expect(hintFor({Formats.gif}), ('gif', 'image/gif'));
      expect(hintFor({Formats.webp}), ('webp', 'image/webp'));
      expect(hintFor({Formats.bmp}), ('bmp', 'image/bmp'));
      expect(hintFor({Formats.tiff}), ('tiff', 'image/tiff'));
    });

    test('ranks TIFF last — it is the one likely to blow the upload cap that '
        'the synthesized PNG would have stayed under', () {
      expect(hintFor({Formats.tiff, Formats.bmp}), ('bmp', 'image/bmp'));
    });

    test('answers null for anything off the table, which is what lets a text '
        'paste fall through and a drag be refused', () {
      // svg is excluded on purpose (its mimeTypes carries the Apple UTI, so it
      // can never match off-Apple, and it is vector anyway); heic/mp4 stand in
      // for the raster and non-image formats the table does not claim.
      expect(hintFor({Formats.svg, Formats.heic, Formats.mp4}), isNull);
      expect(hintFor(const {}), isNull);
    });
  });
}
