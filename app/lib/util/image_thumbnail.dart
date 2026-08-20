import 'dart:typed_data';
import 'dart:ui' as ui;

/// Target width in raw pixels. The chip renders the still far smaller than
/// this; the headroom is for high-DPR screens, where a thumbnail decoded at
/// the logical size would visibly soften.
const int kThumbnailWidth = 64;

/// Downscales [bytes] to a small PNG still, or null when they are not an image
/// this platform can decode.
///
/// An attachment releases its payload the moment the upload succeeds (up to
/// 20 MB), so a chip that wants to keep showing the picture has to keep its
/// own copy — bounded to a thumbnail rather than pinning the original. Decoding
/// straight to [kThumbnailWidth] means the full-size bitmap is never
/// materialised.
Future<Uint8List?> decodeThumbnail(
  Uint8List bytes, {
  int width = kThumbnailWidth,
}) async {
  ui.Codec? codec;
  ui.Image? image;
  try {
    codec = await ui.instantiateImageCodec(bytes, targetWidth: width);
    final frame = await codec.getNextFrame();
    image = frame.image;
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  } catch (_) {
    // Not an image, or a codec this platform lacks — the chip falls back to
    // its type glyph. Never fatal: a thumbnail is decoration.
    return null;
  } finally {
    image?.dispose();
    codec?.dispose();
  }
}
