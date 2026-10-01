import 'package:flutter/foundation.dart';

import 'win32_input.dart';

/// Why a remote-control session cannot start, or why it had to stop.
///
/// Every value here is a state the local user can be told about in words —
/// "my clicks do nothing" is otherwise unexplainable, especially for
/// [targetElevated], which no amount of retrying will fix.
enum InputInjectionFailure {
  /// No injector exists for this OS. Windows only today.
  unsupportedPlatform,

  /// The picked window closed between capture and control.
  targetGone,

  /// The window is minimised. It can neither be captured nor take input, and
  /// the OS will not route events to it while it stays that way.
  targetMinimised,

  /// The target runs at a higher integrity level, so UIPI silently drops every
  /// injected event. Permanently unreachable rather than merely failing: a
  /// Store MSIX can never set `uiAccess`, which is the only escape.
  targetElevated,

  /// The OS refused to bring the target to the foreground. Injecting anyway
  /// would type into whatever the local user has in front instead.
  foregroundDenied,
}

class InputInjectionException implements Exception {
  const InputInjectionException(this.failure, this.message);

  final InputInjectionFailure failure;
  final String message;

  @override
  String toString() => 'InputInjectionException(${failure.name}): $message';
}

/// Origin of the captured frame relative to the target's `GetWindowRect`,
/// measured by the Windows input spike at 100% display scaling.
///
/// The captured frame matches neither `GetWindowRect` nor the DWM extended
/// frame bounds — it sits +5,+2 inside the former and -2,+2 outside the latter
/// on every resizable window measured, but exactly on `GetWindowRect` for a
/// non-resizable dialog.
///
/// TODO(native-preview): read the true crop out of libwebrtc's window-capture
/// path instead of carrying these constants, and re-measure at display scaling
/// other than 100% — that is where a non-unit scale would first appear. Do not
/// replace this with runtime calibration: a product cannot click twice in the
/// user's app to discover where its own pixels are.
const double kFrameOriginOffsetX = 5.0;
const double kFrameOriginOffsetY = 2.0;

/// A point in virtual-desktop screen coordinates.
@immutable
class ScreenPoint {
  const ScreenPoint(this.x, this.y);

  final int x;
  final int y;

  @override
  bool operator ==(Object other) =>
      other is ScreenPoint && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'ScreenPoint($x, $y)';
}

/// The frame → screen seam.
///
/// Everything downstream of the capture pipeline speaks frame pixels; the OS
/// speaks screen pixels. Keeping the whole transform in one value means the
/// unresolved origin question above has exactly one place to be answered.
@immutable
class FrameToScreenTransform {
  const FrameToScreenTransform({
    required this.frameWidth,
    required this.frameHeight,
    required this.originX,
    required this.originY,
    this.scaleX = 1.0,
    this.scaleY = 1.0,
  });

  /// The transform for a window captured at 100% display scaling.
  ///
  /// Scale is deliberately 1.0 and is NOT derived from frame-size ÷ window-size:
  /// the frame is a *crop* of the window, not a resample, so that ratio would
  /// bake a spurious ~0.994 scale into every coordinate.
  factory FrameToScreenTransform.forCapturedWindow({
    required int frameWidth,
    required int frameHeight,
    required int windowLeft,
    required int windowTop,
  }) {
    return FrameToScreenTransform(
      frameWidth: frameWidth,
      frameHeight: frameHeight,
      originX: windowLeft + kFrameOriginOffsetX,
      originY: windowTop + kFrameOriginOffsetY,
    );
  }

  final int frameWidth;
  final int frameHeight;
  final double originX;
  final double originY;
  final double scaleX;
  final double scaleY;

  /// Null when the point falls outside the frame — a remote peer must not be
  /// able to steer the cursor out of the window it was granted.
  ScreenPoint? toScreen(double frameX, double frameY) {
    if (frameX < 0 || frameY < 0) return null;
    if (frameX >= frameWidth || frameY >= frameHeight) return null;
    return ScreenPoint(
      (originX + frameX * scaleX).round(),
      (originY + frameY * scaleY).round(),
    );
  }
}

enum PointerButton { left, right, middle }

enum PointerAction { move, down, up }

@immutable
class PointerInput {
  const PointerInput({
    required this.action,
    required this.frameX,
    required this.frameY,
    this.button = PointerButton.left,
  });

  final PointerAction action;
  final double frameX;
  final double frameY;
  final PointerButton button;
}

/// A wheel event, positioned like a pointer event because the OS routes the
/// wheel to whatever sits under the cursor.
///
/// Deltas are in wheel notches following the Windows sign convention: positive
/// [deltaY] scrolls away from the user. Viewer-side conventions are converted
/// before they reach here.
@immutable
class ScrollInput {
  const ScrollInput({
    required this.frameX,
    required this.frameY,
    this.deltaX = 0,
    this.deltaY = 0,
  });

  final double frameX;
  final double frameY;
  final double deltaX;
  final double deltaY;
}

@immutable
class KeyInput {
  const KeyInput({required this.virtualKeyCode, required this.down});

  final int virtualKeyCode;
  final bool down;
}

/// Virtual keys that must carry the extended-key flag, or the target reads them
/// as their numeric-keypad twins (arrows become 4/8/6/2 with NumLock on).
bool isExtendedVirtualKey(int vk) {
  const extended = <int>{
    0x21, // PRIOR
    0x22, // NEXT
    0x23, // END
    0x24, // HOME
    0x25, // LEFT
    0x26, // UP
    0x27, // RIGHT
    0x28, // DOWN
    0x2C, // SNAPSHOT
    0x2D, // INSERT
    0x2E, // DELETE
    0x6F, // DIVIDE
    0x90, // NUMLOCK
    0xA3, // RCONTROL
    0xA5, // RMENU
  };
  return extended.contains(vk);
}

/// Injects remote pointer and keyboard input into one locally captured window.
///
/// Sessions are explicit because the raise is: the target is brought to the
/// foreground once at [beginSession] and held there, rather than per event.
/// Per-event raise-and-restore measured ~155 ms each way and thrashes the local
/// user's focus on every remote tap.
abstract class InputInjector {
  bool get isActive;

  /// Binds to [targetWindowId] — the native window handle, which on both
  /// supported platforms is the capture source id verbatim — and raises it.
  ///
  /// Throws [InputInjectionException] when the target cannot be driven.
  Future<void> beginSession({
    required int targetWindowId,
    required FrameToScreenTransform transform,
  });

  /// Re-points the coordinate seam after the target is resized or moved.
  void updateTransform(FrameToScreenTransform transform);

  /// Whether the target still holds the foreground. False means injection is
  /// suspended: the local user has taken their machine back.
  bool get targetIsForeground;

  /// Re-raises the target after the local user took focus away. Only ever
  /// called from an explicit gesture — never on a timer, and never per event.
  Future<bool> ensureForeground();

  Future<void> endSession();

  /// Each returns false when the event was not delivered — the target lost the
  /// foreground, or the OS rejected the batch. Callers decide whether that is
  /// worth surfacing; a dropped mouse-move during a focus blip is not.
  bool injectPointer(PointerInput event);
  bool injectScroll(ScrollInput event);
  bool injectKey(KeyInput event);
  bool injectText(String text);
}

/// The injector for this OS, or null where remote control is not implemented.
InputInjector? createInputInjector() {
  if (kIsWeb) return null;
  return switch (defaultTargetPlatform) {
    TargetPlatform.windows => Win32InputInjector(),
    _ => null,
  };
}
