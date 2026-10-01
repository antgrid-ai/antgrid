import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/services/screen_share_backend.dart';
import 'package:antgrid/services/screen_viewer_input.dart';

void main() {
  group('frameOffsetForLocal', () {
    const frame = ScreenFrameSize(1000, 500);

    test('maps the centre of an exactly-fitting viewport', () {
      final offset = frameOffsetForLocal(
        local: const Offset(100, 50),
        viewport: const Size(1000, 500),
        frame: frame,
      );
      expect(offset, const Offset(100, 50));
    });

    test('undoes the horizontal letterbox of a too-wide viewport', () {
      // 2000x500 viewport, 2:1 frame -> scale 1.0, 500px of pillarbox each side.
      final offset = frameOffsetForLocal(
        local: const Offset(600, 100),
        viewport: const Size(2000, 500),
        frame: frame,
      );
      expect(offset, const Offset(100, 100));
    });

    test('undoes the scale of a half-size viewport', () {
      final offset = frameOffsetForLocal(
        local: const Offset(100, 50),
        viewport: const Size(500, 250),
        frame: frame,
      );
      expect(offset, const Offset(200, 100));
    });

    test('returns null in the letterbox rather than clamping to the edge', () {
      // A remote peer must not be able to steer the cursor out of the window it
      // was granted, so a bar pixel maps to nothing at all.
      expect(
        frameOffsetForLocal(
          local: const Offset(10, 100),
          viewport: const Size(2000, 500),
          frame: frame,
        ),
        isNull,
      );
      expect(
        frameOffsetForLocal(
          local: const Offset(1990, 100),
          viewport: const Size(2000, 500),
          frame: frame,
        ),
        isNull,
      );
    });

    test('returns null for a degenerate frame or viewport', () {
      expect(
        frameOffsetForLocal(
          local: Offset.zero,
          viewport: const Size(100, 100),
          frame: const ScreenFrameSize(0, 0),
        ),
        isNull,
      );
      expect(
        frameOffsetForLocal(
          local: Offset.zero,
          viewport: Size.zero,
          frame: frame,
        ),
        isNull,
      );
    });
  });

  group('wire encoding', () {
    test('pointer payload matches the shape the host switches on', () {
      final decoded =
          jsonDecode(
                encodePointerInput(
                  action: ViewerPointerAction.down,
                  frame: const Offset(12.5, 34),
                  button: 'right',
                ),
              )
              as Map<String, dynamic>;
      expect(decoded, {'t': 'down', 'x': 12.5, 'y': 34.0, 'b': 'right'});
    });

    test('every pointer action has a distinct wire verb', () {
      final verbs = ViewerPointerAction.values
          .map(
            (a) =>
                (jsonDecode(encodePointerInput(action: a, frame: Offset.zero))
                    as Map<String, dynamic>)['t'],
          )
          .toList();
      expect(verbs, ['move', 'down', 'up']);
    });

    test('scroll, key and text payloads', () {
      expect(
        jsonDecode(
          encodeScrollInput(frame: const Offset(1, 2), deltaX: 0, deltaY: -1.5),
        ),
        {'t': 'scroll', 'x': 1.0, 'y': 2.0, 'dx': 0.0, 'dy': -1.5},
      );
      expect(jsonDecode(encodeKeyInput(0x25, down: true)), {
        't': 'key',
        'vk': 0x25,
        'down': true,
      });
      expect(jsonDecode(encodeTextInput('hi')), {'t': 'text', 's': 'hi'});
    });

    test('button names follow the pointer bitmask', () {
      expect(viewerButtonName(kPrimaryButton), 'left');
      expect(viewerButtonName(kSecondaryButton), 'right');
      expect(viewerButtonName(kTertiaryButton), 'middle');
      expect(viewerButtonName(0), 'left');
    });
  });

  group('windowsVirtualKeyFor', () {
    test('maps the navigation and modifier keys that produce no character', () {
      expect(windowsVirtualKeyFor(LogicalKeyboardKey.arrowLeft), 0x25);
      expect(windowsVirtualKeyFor(LogicalKeyboardKey.enter), 0x0D);
      expect(windowsVirtualKeyFor(LogicalKeyboardKey.escape), 0x1B);
      expect(windowsVirtualKeyFor(LogicalKeyboardKey.controlLeft), 0x11);
      expect(windowsVirtualKeyFor(LogicalKeyboardKey.f5), 0x74);
    });

    test('letters and digits fall back to their ASCII virtual key', () {
      // Needed for chords: ctrl+C produces no character, so it can only travel
      // as a virtual key.
      expect(windowsVirtualKeyFor(LogicalKeyboardKey.keyC), 0x43);
      expect(windowsVirtualKeyFor(LogicalKeyboardKey.digit7), 0x37);
    });

    test('an unmapped key is null so the caller sends nothing', () {
      expect(windowsVirtualKeyFor(LogicalKeyboardKey.mediaPlay), isNull);
    });
  });

  group('shouldSendAsText', () {
    test('plain typing goes as text', () {
      expect(shouldSendAsText('a', hasCommandModifier: false), isTrue);
      expect(shouldSendAsText('€', hasCommandModifier: false), isTrue);
    });

    test('a ctrl/meta chord is a command, not typing', () {
      expect(shouldSendAsText('c', hasCommandModifier: true), isFalse);
    });

    test('control characters and no character take the key path', () {
      expect(shouldSendAsText('\n', hasCommandModifier: false), isFalse);
      expect(shouldSendAsText('', hasCommandModifier: false), isFalse);
      expect(shouldSendAsText(null, hasCommandModifier: false), isFalse);
    });
  });
}
