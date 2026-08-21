import 'dart:async';
import 'dart:typed_data';

import 'package:super_clipboard/super_clipboard.dart';

/// An image lifted off the system clipboard, ready to become an attachment.
class PastedImage {
  const PastedImage({
    required this.fileName,
    required this.bytes,
    required this.mimeType,
  });

  final String fileName;
  final Uint8List bytes;
  final String mimeType;
}

/// Reads one image off the system clipboard, or null when it holds none.
///
/// Injected so widget tests can drive the paste path without the platform
/// channels `super_clipboard` needs.
typedef ClipboardImageReader = Future<PastedImage?> Function();

typedef _ImageFormat = ({
  SimpleFileFormat format,
  String ext,
  // Spellings of [ext] a copied file may already carry, so its own name is not
  // "repaired" into photo.jpeg.jpg.
  List<String> altExts,
  String mime,
});

/// Probed in order, so the first match wins when a source offers several
/// encodings of the same picture. PNG leads because it is also what Windows
/// DIB/DIBV5 and macOS TIFF are synthesized into, making it the hit for a
/// plain screenshot on every desktop platform.
const _imageFormats = <_ImageFormat>[
  (format: Formats.png, ext: 'png', altExts: <String>[], mime: 'image/png'),
  (
    format: Formats.jpeg,
    ext: 'jpg',
    altExts: <String>['jpeg'],
    mime: 'image/jpeg',
  ),
  (format: Formats.gif, ext: 'gif', altExts: <String>[], mime: 'image/gif'),
  (format: Formats.webp, ext: 'webp', altExts: <String>[], mime: 'image/webp'),
];

/// Bounds the wait for a clipboard item that never arrives. `getFile` reports
/// through callbacks, so a provider that answers neither would otherwise leave
/// paste doing nothing forever with no way for the user to tell.
const _kReadTimeout = Duration(seconds: 15);

/// Throws when the clipboard advertised an image it then failed to hand over.
/// Absence of an image is not an error — that is a null return.
class ClipboardImageException implements Exception {
  const ClipboardImageException(this.message);
  final String message;

  @override
  String toString() => 'ClipboardImageException: $message';
}

Future<PastedImage?> readClipboardImage() async {
  final clipboard = SystemClipboard.instance;
  // Null on platforms without a clipboard API; callers fall back to text.
  if (clipboard == null) return null;
  final reader = await clipboard.read();

  // A source commonly advertises one picture in several encodings, so a format
  // that fails to hand its copy over says nothing about the next one. Keep the
  // first failure to report only if NONE of them yields an image.
  Object? firstError;
  StackTrace? firstStack;

  for (final entry in _imageFormats) {
    if (!reader.canProvide(entry.format)) continue;
    final ({Uint8List bytes, String? fileName})? file;
    try {
      file = await _readFile(reader, entry.format);
    } catch (error, stack) {
      firstError ??= error;
      firstStack ??= stack;
      continue;
    }
    // `canProvide` is a best guess, and a format that resolves to no value at
    // all is handed over as zero bytes rather than an error — attaching that
    // would upload an empty image instead of pasting whatever else is there.
    if (file == null || file.bytes.isEmpty) continue;
    // A copied FILE reaches us with its real name (getFile synthesizes files
    // from URIs on desktop); a raw bitmap has none, so it gets a stable
    // synthetic one. The bridge sanitizes either way.
    final name = file.fileName ?? await reader.getSuggestedName();
    return PastedImage(
      fileName: resolvePastedImageFileName(
        name,
        entry.ext,
        altExts: entry.altExts,
      ),
      bytes: file.bytes,
      mimeType: entry.mime,
    );
  }
  if (firstError != null) {
    Error.throwWithStackTrace(firstError, firstStack!);
  }
  return null;
}

/// Names the attachment. A raw bitmap carries no name at all, so it gets a
/// stable synthetic one; a copied file keeps its own, extension repaired only
/// when it does not already match the format we read it as.
String resolvePastedImageFileName(
  String? name,
  String ext, {
  List<String> altExts = const [],
}) {
  final trimmed = name?.trim() ?? '';
  if (trimmed.isEmpty) return 'pasted-image.$ext';
  final lower = trimmed.toLowerCase();
  for (final candidate in [ext, ...altExts]) {
    if (lower.endsWith('.$candidate')) return trimmed;
  }
  return '$trimmed.$ext';
}

/// Bridges `getFile`'s callback pair onto a future.
///
/// The stream is only valid inside the `onFile` callback, so the bytes are
/// drained there rather than handed out.
///
/// Unlike the file picker, this does NOT pre-check the declared size against
/// the upload cap: a clipboard image is bounded by what some app already held
/// in memory (megabytes, not the multi-GB file a picker can name), and the
/// caller's post-read check is what produces the specific TOO_LARGE message —
/// rejecting here could only fall back to pasting text, silently.
Future<({Uint8List bytes, String? fileName})?> _readFile(
  ClipboardDataReader reader,
  FileFormat format,
) {
  final completer = Completer<({Uint8List bytes, String? fileName})?>();
  void fail(Object error) {
    if (!completer.isCompleted) {
      completer.completeError(ClipboardImageException('$error'));
    }
  }

  try {
    // Null means no item ended up matching after all, and NEITHER callback will
    // ever run — without this the completer would sit out the whole timeout and
    // paste would appear dead for 15s before falling back to text.
    final started = reader.getFile(format, (file) async {
      try {
        final bytes = await file.readAll();
        if (!completer.isCompleted) {
          completer.complete((bytes: bytes, fileName: file.fileName));
        }
      } catch (e) {
        fail(e);
      }
    }, onError: fail);
    if (started == null && !completer.isCompleted) completer.complete(null);
  } catch (e) {
    fail(e);
  }
  return completer.future.timeout(
    _kReadTimeout,
    onTimeout: () =>
        throw const ClipboardImageException('Timed out reading the clipboard'),
  );
}
