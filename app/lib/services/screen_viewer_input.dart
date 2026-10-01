/// Viewer-side translation of local gestures and key presses into the input
/// datachannel's wire format.
///
/// Two conversions live here, both pure so they can be pinned without a peer
/// connection: viewer-local pixels → frame pixels, and Flutter key events →
/// Windows virtual-key codes. The payload shapes must stay in lockstep with
/// `ScreenShareService._applyInput`, which is the only consumer and treats
/// everything here as untrusted.
library;

import 'dart:convert';

import 'package:flutter/gestures.dart' show kSecondaryButton, kTertiaryButton;
import 'package:flutter/services.dart';

import 'screen_share_backend.dart' show ScreenFrameSize;

/// Frame position of [local] inside a `contain`-fitted render of a [frame]-sized
/// video filling [viewport].
///
/// Null in the letterbox: those pixels belong to no part of the shared window,
/// and passing them through would land the cursor on the nearest edge instead
/// of nowhere.
Offset? frameOffsetForLocal({
  required Offset local,
  required Size viewport,
  required ScreenFrameSize frame,
}) {
  if (frame.width <= 0 || frame.height <= 0) return null;
  if (viewport.width <= 0 || viewport.height <= 0) return null;
  final scale =
      (viewport.width / frame.width) < (viewport.height / frame.height)
      ? viewport.width / frame.width
      : viewport.height / frame.height;
  if (scale <= 0) return null;
  final renderedWidth = frame.width * scale;
  final renderedHeight = frame.height * scale;
  final frameX = (local.dx - (viewport.width - renderedWidth) / 2) / scale;
  final frameY = (local.dy - (viewport.height - renderedHeight) / 2) / scale;
  if (frameX < 0 || frameY < 0) return null;
  if (frameX >= frame.width || frameY >= frame.height) return null;
  return Offset(frameX, frameY);
}

/// Pointer actions, matching the `t` values the host switches on.
enum ViewerPointerAction { move, down, up }

const Map<ViewerPointerAction, String> _pointerWire = {
  ViewerPointerAction.move: 'move',
  ViewerPointerAction.down: 'down',
  ViewerPointerAction.up: 'up',
};

/// Flutter's pointer button bitmask → the host's button name. Anything that is
/// not a recognised secondary or tertiary press reads as the primary button,
/// matching the host's own default.
String viewerButtonName(int buttons) {
  if (buttons & kSecondaryButton != 0) return 'right';
  if (buttons & kTertiaryButton != 0) return 'middle';
  return 'left';
}

String encodePointerInput({
  required ViewerPointerAction action,
  required Offset frame,
  String button = 'left',
}) => jsonEncode({
  't': _pointerWire[action],
  'x': frame.dx,
  'y': frame.dy,
  'b': button,
});

/// Wheel deltas follow the Windows convention the injector expects: positive
/// [deltaY] scrolls away from the user, which is the opposite of Flutter's
/// scroll-down-is-positive signal, so callers negate before they get here.
String encodeScrollInput({
  required Offset frame,
  double deltaX = 0,
  double deltaY = 0,
}) => jsonEncode({
  't': 'scroll',
  'x': frame.dx,
  'y': frame.dy,
  'dx': deltaX,
  'dy': deltaY,
});

String encodeKeyInput(int virtualKeyCode, {required bool down}) =>
    jsonEncode({'t': 'key', 'vk': virtualKeyCode, 'down': down});

String encodeTextInput(String text) => jsonEncode({'t': 'text', 's': text});

/// Windows virtual-key code for [key], or null when the key has no stable
/// mapping and should travel as text instead.
///
/// Deliberately partial: printable characters are sent as `text` so the viewer's
/// keyboard layout and IME do the work, and only the keys that produce no
/// character — modifiers, navigation, function keys — need a code.
int? windowsVirtualKeyFor(LogicalKeyboardKey key) {
  final direct = _namedVirtualKeys[key];
  if (direct != null) return direct;
  final label = key.keyLabel;
  if (label.length != 1) return null;
  final code = label.codeUnitAt(0);
  // Letters and digits share their ASCII value with their virtual-key code, so
  // a ctrl/alt chord (which produces no character) can still be expressed.
  if (code >= 0x41 && code <= 0x5A) return code;
  if (code >= 0x61 && code <= 0x7A) return code - 0x20;
  if (code >= 0x30 && code <= 0x39) return code;
  return null;
}

/// Not const: a `LogicalKeyboardKey` overrides `==`, which a const map key may
/// not do, and its `keyId` is a field rather than a const expression.
final Map<LogicalKeyboardKey, int> _namedVirtualKeys = {
  LogicalKeyboardKey.backspace: 0x08,
  LogicalKeyboardKey.tab: 0x09,
  LogicalKeyboardKey.enter: 0x0D,
  LogicalKeyboardKey.numpadEnter: 0x0D,
  LogicalKeyboardKey.shift: 0x10,
  LogicalKeyboardKey.shiftLeft: 0x10,
  LogicalKeyboardKey.shiftRight: 0xA1,
  LogicalKeyboardKey.control: 0x11,
  LogicalKeyboardKey.controlLeft: 0x11,
  LogicalKeyboardKey.controlRight: 0xA3,
  LogicalKeyboardKey.alt: 0x12,
  LogicalKeyboardKey.altLeft: 0x12,
  LogicalKeyboardKey.altRight: 0xA5,
  LogicalKeyboardKey.capsLock: 0x14,
  LogicalKeyboardKey.escape: 0x1B,
  LogicalKeyboardKey.space: 0x20,
  LogicalKeyboardKey.pageUp: 0x21,
  LogicalKeyboardKey.pageDown: 0x22,
  LogicalKeyboardKey.end: 0x23,
  LogicalKeyboardKey.home: 0x24,
  LogicalKeyboardKey.arrowLeft: 0x25,
  LogicalKeyboardKey.arrowUp: 0x26,
  LogicalKeyboardKey.arrowRight: 0x27,
  LogicalKeyboardKey.arrowDown: 0x28,
  LogicalKeyboardKey.insert: 0x2D,
  LogicalKeyboardKey.delete: 0x2E,
  LogicalKeyboardKey.meta: 0x5B,
  LogicalKeyboardKey.metaLeft: 0x5B,
  LogicalKeyboardKey.metaRight: 0x5C,
  LogicalKeyboardKey.f1: 0x70,
  LogicalKeyboardKey.f2: 0x71,
  LogicalKeyboardKey.f3: 0x72,
  LogicalKeyboardKey.f4: 0x73,
  LogicalKeyboardKey.f5: 0x74,
  LogicalKeyboardKey.f6: 0x75,
  LogicalKeyboardKey.f7: 0x76,
  LogicalKeyboardKey.f8: 0x77,
  LogicalKeyboardKey.f9: 0x78,
  LogicalKeyboardKey.f10: 0x79,
  LogicalKeyboardKey.f11: 0x7A,
  LogicalKeyboardKey.f12: 0x7B,
};

/// Whether [character] should be forwarded verbatim as text rather than as a
/// virtual key. Control characters carry no glyph, and a chord with ctrl or meta
/// held is a command rather than typing — both need the key path.
bool shouldSendAsText(String? character, {required bool hasCommandModifier}) {
  if (character == null || character.isEmpty) return false;
  if (hasCommandModifier) return false;
  return !character.codeUnits.any((c) => c < 0x20 || c == 0x7F);
}
