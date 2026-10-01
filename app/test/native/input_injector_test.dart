import 'package:antgrid/native/input_injector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FrameToScreenTransform.forCapturedWindow', () {
    // The spike solved the transform empirically against a Flutter window whose
    // GetWindowRect origin was (10,10) and whose captured frame was 1272x715:
    //   screenX = 15.0 + frameX * 1.0
    //   screenY = 12.0 + frameY * 1.0
    // These cases pin that solve, so a change to kFrameOriginOffset* has to be
    // a deliberate re-measurement.
    final transform = FrameToScreenTransform.forCapturedWindow(
      frameWidth: 1272,
      frameHeight: 715,
      windowLeft: 10,
      windowTop: 10,
    );

    test('reproduces both measured probe points', () {
      expect(transform.toScreen(319, 212), const ScreenPoint(334, 224));
      expect(transform.toScreen(952, 568), const ScreenPoint(967, 580));
    });

    test(
      'frame origin lands on the window origin plus the measured offset',
      () {
        expect(transform.toScreen(0, 0), const ScreenPoint(15, 12));
      },
    );

    test(
      'scale is 1.0 — the frame is a crop of the window, not a resample',
      () {
        expect(transform.scaleX, 1.0);
        expect(transform.scaleY, 1.0);
      },
    );

    test(
      'negative window origin (monitor left of primary) carries through',
      () {
        final offscreen = FrameToScreenTransform.forCapturedWindow(
          frameWidth: 800,
          frameHeight: 600,
          windowLeft: -1920,
          windowTop: -100,
        );
        expect(offscreen.toScreen(0, 0), const ScreenPoint(-1915, -98));
      },
    );
  });

  group('FrameToScreenTransform bounds', () {
    const transform = FrameToScreenTransform(
      frameWidth: 100,
      frameHeight: 50,
      originX: 0,
      originY: 0,
    );

    test('accepts the last in-frame pixel', () {
      expect(transform.toScreen(99, 49), const ScreenPoint(99, 49));
    });

    test('rejects points past the far edge', () {
      expect(transform.toScreen(100, 0), isNull);
      expect(transform.toScreen(0, 50), isNull);
    });

    test('rejects negative points', () {
      expect(transform.toScreen(-1, 0), isNull);
      expect(transform.toScreen(0, -0.5), isNull);
    });
  });

  group('FrameToScreenTransform scaling', () {
    test('applies an explicit non-unit scale per axis', () {
      const transform = FrameToScreenTransform(
        frameWidth: 640,
        frameHeight: 360,
        originX: 100,
        originY: 200,
        scaleX: 2.0,
        scaleY: 1.5,
      );
      expect(transform.toScreen(10, 10), const ScreenPoint(120, 215));
    });

    test('rounds rather than truncates', () {
      const transform = FrameToScreenTransform(
        frameWidth: 640,
        frameHeight: 360,
        originX: 0,
        originY: 0,
        scaleX: 1.5,
        scaleY: 1.5,
      );
      expect(transform.toScreen(3, 1), const ScreenPoint(5, 2));
    });
  });

  group('isExtendedVirtualKey', () {
    test('flags the keys that collide with the numeric keypad', () {
      expect(isExtendedVirtualKey(0x25), isTrue); // LEFT
      expect(isExtendedVirtualKey(0x2E), isTrue); // DELETE
      expect(isExtendedVirtualKey(0xA3), isTrue); // RCONTROL
    });

    test('leaves ordinary keys and left-hand modifiers alone', () {
      expect(isExtendedVirtualKey(0x41), isFalse); // A
      expect(isExtendedVirtualKey(0x0D), isFalse); // RETURN
      expect(isExtendedVirtualKey(0xA2), isFalse); // LCONTROL
    });
  });
}
