import 'package:antgrid/native/win32_input.dart';
import 'package:flutter_test/flutter_test.dart';

// Only the pure arithmetic is covered here. Everything else in win32_input.dart
// moves the real desktop — raising windows and pushing events into whatever
// holds the foreground — which is not something a unit test may do.
void main() {
  group('normalizeToVirtualDesktop', () {
    test('maps a single 1920x1080 desktop onto the full 0..65535 range', () {
      expect(
        normalizeToVirtualDesktop(
          0,
          0,
          originX: 0,
          originY: 0,
          width: 1920,
          height: 1080,
        ),
        (dx: 0, dy: 0),
      );
      expect(
        normalizeToVirtualDesktop(
          1919,
          1079,
          originX: 0,
          originY: 0,
          width: 1920,
          height: 1080,
        ),
        (dx: 65535, dy: 65535),
      );
      expect(
        normalizeToVirtualDesktop(
          960,
          540,
          originX: 0,
          originY: 0,
          width: 1920,
          height: 1080,
        ),
        (dx: 32785, dy: 32798),
      );
    });

    test('rebases a monitor left of and above the primary one', () {
      // A second monitor at (-1920,-1080) puts the virtual desktop origin
      // negative; absolute coordinates are relative to that origin, not to the
      // primary display.
      expect(
        normalizeToVirtualDesktop(
          -1920,
          -1080,
          originX: -1920,
          originY: -1080,
          width: 3840,
          height: 2160,
        ),
        (dx: 0, dy: 0),
      );
      expect(
        normalizeToVirtualDesktop(
          1919,
          1079,
          originX: -1920,
          originY: -1080,
          width: 3840,
          height: 2160,
        ),
        (dx: 65535, dy: 65535),
      );
    });

    test('survives a degenerate desktop size instead of dividing by zero', () {
      expect(
        normalizeToVirtualDesktop(
          0,
          0,
          originX: 0,
          originY: 0,
          width: 1,
          height: 1,
        ),
        (dx: 0, dy: 0),
      );
      expect(
        normalizeToVirtualDesktop(
          0,
          0,
          originX: 0,
          originY: 0,
          width: 0,
          height: 0,
        ),
        (dx: 0, dy: 0),
      );
    });
  });

  test('constructing the injector holds the 40-byte INPUT invariant', () {
    // The constructor asserts sizeOf<INPUT>() == 40 for both variants. A wrong
    // cbSize does not throw at runtime — SendInput just returns 0 and every
    // remote click disappears — so this is the only place it fails loudly.
    expect(Win32InputInjector().isActive, isFalse);
  });
}
