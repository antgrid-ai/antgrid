import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/util/image_thumbnail.dart';

/// Encodes a [width]x[height] PNG so the crop can be measured against known
/// dimensions rather than a hand-pasted base64 blob whose size is invisible.
Future<Uint8List> _png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = const Color(0xFF3366CC),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  picture.dispose();
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

Future<ui.Image> _decode(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  return (await codec.getNextFrame()).image;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('cropImageToRegion', () {
    test('scales the region from its own space into image pixels', () async {
      // A 2x capture: 800 CSS px of viewport rasterized 1600 px wide.
      final source = await _png(1600, 1200);
      final out = await cropImageToRegion(
        source,
        region: const Rect.fromLTWH(100, 100, 200, 50),
        regionSpace: const Size(800, 600),
        padding: 0,
      );

      expect(out, isNotNull);
      final image = await _decode(out!);
      expect(image.width, 400);
      expect(image.height, 100);
      image.dispose();
    });

    test('padding widens the crop in region units, not image pixels', () async {
      final source = await _png(1600, 1200);
      final out = await cropImageToRegion(
        source,
        region: const Rect.fromLTWH(100, 100, 200, 50),
        regionSpace: const Size(800, 600),
        padding: 10,
      );

      final image = await _decode(out!);
      // 10 region px each side at 2x = 40 image px added per axis.
      expect(image.width, 440);
      expect(image.height, 140);
      image.dispose();
    });

    test(
      'an element hanging off the edge crops to what was captured',
      () async {
        final source = await _png(400, 300);
        final out = await cropImageToRegion(
          source,
          // Starts above the viewport and runs past its right edge.
          region: const Rect.fromLTWH(300, -50, 200, 100),
          regionSpace: const Size(400, 300),
          padding: 0,
        );

        final image = await _decode(out!);
        expect(image.width, 100);
        expect(image.height, 50);
        image.dispose();
      },
    );

    test('a region entirely outside the capture is a failure, not an empty '
        'image', () async {
      final source = await _png(400, 300);
      expect(
        await cropImageToRegion(
          source,
          region: const Rect.fromLTWH(900, 900, 100, 100),
          regionSpace: const Size(400, 300),
          padding: 0,
        ),
        isNull,
      );
    });

    test('undecodable bytes report failure rather than throwing', () async {
      expect(
        await cropImageToRegion(
          Uint8List.fromList([1, 2, 3]),
          region: const Rect.fromLTWH(0, 0, 10, 10),
          regionSpace: const Size(100, 100),
        ),
        isNull,
      );
    });

    test('a degenerate region space is refused', () async {
      final source = await _png(400, 300);
      expect(
        await cropImageToRegion(
          source,
          region: const Rect.fromLTWH(0, 0, 10, 10),
          regionSpace: Size.zero,
        ),
        isNull,
      );
    });
  });
}
