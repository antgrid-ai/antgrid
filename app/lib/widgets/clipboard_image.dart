import 'dart:async';
import 'dart:typed_data';

import 'package:super_clipboard/super_clipboard.dart';

import 'data_reader_bytes.dart';

/// One image lifted off the system clipboard, ready for the attach pipeline.
class ClipboardImage {
  const ClipboardImage({
    required this.fileName,
    required this.mimeType,
    required this.bytes,
  });

  final String fileName;
  final String mimeType;
  final Uint8List bytes;
}

/// Probe order. PNG leads because Windows (from CF_DIB/CF_DIBV5) and macOS
/// (from `public.tiff`) synthesize a PNG on demand, so a screenshot or a
/// browser "copy image" lands there on both desktops. The rest earn their
/// place on Linux, Android and iOS, which synthesize nothing at all and hand
/// over only what the source app advertised. TIFF stays last: it is the one
/// format likely to blow the upload cap that PNG would have stayed under.
///
/// `Formats.svg` is deliberately absent — its `mimeTypes` carries the Apple UTI
/// string, so it can never match on Windows/Linux/Android, and it is vector
/// anyway.
const List<(FileFormat, String, String)> _kImageFormats = [
  (Formats.png, 'png', 'image/png'),
  (Formats.jpeg, 'jpg', 'image/jpeg'),
  (Formats.gif, 'gif', 'image/gif'),
  (Formats.webp, 'webp', 'image/webp'),
  (Formats.bmp, 'bmp', 'image/bmp'),
  (Formats.tiff, 'tiff', 'image/tiff'),
];

/// Reads the first image on the system clipboard, or null when there is none.
///
/// Never throws: a clipboard that cannot be read (no owner on a headless
/// session, no clipboard API at all on web/Firefox, no platform channel under
/// `flutter_test`) is indistinguishable from an empty one to the caller, which
/// is what lets the paste chord fall through to its plain-text path instead of
/// dying between the two.
///
/// Only ever call this from an explicit paste gesture: on iOS and web a read
/// raises the system paste-confirmation sheet.
Future<ClipboardImage?> readClipboardImage({
  Duration timeout = const Duration(seconds: 10),
}) async {
  try {
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) return null;
    final reader = await clipboard.read().timeout(timeout);

    for (final (format, extension, mimeType) in _kImageFormats) {
      if (!reader.canProvide(format)) continue;
      final bytes = await _readBytes(reader, format).timeout(timeout);
      if (bytes == null || bytes.isEmpty) continue;
      return ClipboardImage(
        fileName: pastedImageName(await reader.getSuggestedName(), extension),
        mimeType: mimeType,
        bytes: bytes,
      );
    }
    return null;
  } catch (_) {
    return null;
  }
}

/// The extension and MIME type for the first image format [canProvide]
/// answers for, or null when the item carries no image at all.
///
/// A dropped raw image has no name on any platform (`fileName` and
/// `getSuggestedName()` are both populated only when the user dragged a
/// *file*), so the format it advertises is the only thing left to name it by —
/// and an agent handed `photo.bin` has no way to know what it is holding.
(String extension, String mimeType)? imageFormatHint(
  bool Function(FileFormat format) canProvide,
) {
  for (final (format, extension, mimeType) in _kImageFormats) {
    if (canProvide(format)) return (extension, mimeType);
  }
  return null;
}

Future<Uint8List?> _readBytes(DataReader reader, FileFormat format) =>
    collectFileBytes(
      (onFile, onError) =>
          reader.getFile(
            format,
            (file) => onFile(file.readAll),
            onError: onError,
          ) !=
          null,
    );

/// A name the bridge's uploader will accept for a pasted image.
///
/// `sanitizeUploadFileName` keeps only `[A-Za-z0-9._ -]`, strips leading dots,
/// and rejects a name that sanitizes to empty — so the name is synthesized in
/// that alphabet rather than trusted from the platform. The extension always
/// comes from the format that matched: a Windows DIB read as PNG can still
/// suggest `.bmp`, and an iOS suggested name commonly has none at all.
String pastedImageName(String? suggested, String extension) {
  final base = (suggested ?? '').split(RegExp(r'[\\/]')).last;
  final dot = base.lastIndexOf('.');
  final stem = (dot > 0 ? base.substring(0, dot) : base)
      .replaceAll(RegExp(r'^\.+'), '')
      .replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '_')
      .trim();
  if (stem.isNotEmpty) return '$stem.$extension';

  final now = DateTime.now();
  String pad(int v) => v.toString().padLeft(2, '0');
  return 'pasted-${now.year}${pad(now.month)}${pad(now.day)}'
      '-${pad(now.hour)}${pad(now.minute)}${pad(now.second)}.$extension';
}
