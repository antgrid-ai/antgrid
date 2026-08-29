import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

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

/// Margin left around a cropped region, in the same units as [region] — enough
/// context that the crop reads as "this element, in place" rather than a
/// floating fragment with no edges.
const double kCropPadding = 12.0;

/// Crops [bytes] to [region], where [region] is expressed in [regionSpace]
/// coordinates rather than image pixels.
///
/// The two spaces differ by whatever ratio the capture was taken at (a page
/// screenshot is rasterized at the device pixel ratio, while a DOM rect is in
/// CSS pixels), so passing the space the region was measured in is what keeps
/// the caller from having to know the capture's scale. Returns null when the
/// bytes can't be decoded or the region has no area inside the image; a
/// degenerate crop is a failure, not an empty PNG.
Future<Uint8List?> cropImageToRegion(
  Uint8List bytes, {
  required Rect region,
  required Size regionSpace,
  double padding = kCropPadding,
}) async {
  if (regionSpace.width <= 0 || regionSpace.height <= 0) return null;

  ui.Codec? codec;
  ui.Image? image;
  ui.Image? cropped;
  try {
    codec = await ui.instantiateImageCodec(bytes);
    image = (await codec.getNextFrame()).image;
    final scale = image.width / regionSpace.width;
    final full = Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    // Clamped to the image: an element scrolled half out of view, or one
    // hanging past the right edge, still crops to the part that was actually
    // captured instead of producing a box with transparent margins.
    final src = Rect.fromLTRB(
      (region.left - padding) * scale,
      (region.top - padding) * scale,
      (region.right + padding) * scale,
      (region.bottom + padding) * scale,
    ).intersect(full);
    if (src.width < 1 || src.height < 1) return null;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImageRect(
      image,
      src,
      Rect.fromLTWH(0, 0, src.width, src.height),
      Paint(),
    );
    final picture = recorder.endRecording();
    try {
      cropped = await picture.toImage(
        src.width.round().clamp(1, image.width),
        src.height.round().clamp(1, image.height),
      );
    } finally {
      picture.dispose();
    }
    final data = await cropped.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  } catch (_) {
    return null;
  } finally {
    cropped?.dispose();
    image?.dispose();
    codec?.dispose();
  }
}
