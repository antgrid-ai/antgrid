import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../services/screen_share_backend.dart' show ScreenFrameSize;
import '../services/screen_viewer_input.dart';

/// Logical pixels Flutter reports for roughly one mouse-wheel notch.
///
/// Approximate by construction: Flutter normalises wheel motion to logical
/// pixels while the injector counts notches and re-multiplies by `WHEEL_DELTA`,
/// so the two ends only have to agree on an order of magnitude.
const double kLogicalPixelsPerWheelNotch = 60.0;

/// Captures pointer and keyboard input over the streamed video and hands it on
/// in FRAME coordinates.
///
/// The translation is the whole job: the video is `contain`-fitted, so a tap in
/// the letterbox belongs to no pixel of the shared window and is dropped rather
/// than clamped onto the nearest edge — a remote peer must not be able to steer
/// the cursor out of the one window it was granted.
class ScreenRemoteInputSurface extends StatefulWidget {
  const ScreenRemoteInputSurface({
    super.key,
    required this.frameSize,
    required this.enabled,
    required this.onPointer,
    required this.onScroll,
    required this.onKey,
    required this.onText,
    required this.child,
  });

  final ScreenFrameSize frameSize;

  /// False renders the video untouched: no focus stealing, no listeners, and a
  /// normal cursor, so a view-only session behaves like a picture.
  final bool enabled;

  final void Function(ViewerPointerAction action, Offset frame, String button)
  onPointer;
  final void Function(Offset frame, double deltaX, double deltaY) onScroll;
  final void Function(int virtualKeyCode, bool down) onKey;
  final ValueChanged<String> onText;
  final Widget child;

  @override
  State<ScreenRemoteInputSurface> createState() =>
      _ScreenRemoteInputSurfaceState();
}

class _ScreenRemoteInputSurfaceState extends State<ScreenRemoteInputSurface> {
  final _focusNode = FocusNode(debugLabel: 'ScreenRemoteInput');

  /// Keys whose press was forwarded as text. Their release must NOT be sent as
  /// a virtual key, or the host releases a key it never saw pressed.
  final Set<LogicalKeyboardKey> _sentAsText = {};

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  Offset? _frameOf(Offset local, Size viewport) => frameOffsetForLocal(
    local: local,
    viewport: viewport,
    frame: widget.frameSize,
  );

  void _pointer(ViewerPointerAction action, PointerEvent event, Size viewport) {
    final frame = _frameOf(event.localPosition, viewport);
    if (frame == null) return;
    widget.onPointer(action, frame, viewerButtonName(event.buttons));
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (!widget.enabled) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (event is KeyUpEvent) {
      if (_sentAsText.remove(key)) return KeyEventResult.handled;
      final vk = windowsVirtualKeyFor(key);
      if (vk == null) return KeyEventResult.ignored;
      widget.onKey(vk, false);
      return KeyEventResult.handled;
    }
    final keyboard = HardwareKeyboard.instance;
    final hasCommandModifier =
        keyboard.isControlPressed ||
        keyboard.isMetaPressed ||
        keyboard.isAltPressed;
    // Typing goes as text so the viewer's own layout and IME do the work; only
    // keys that produce no character need a virtual-key code.
    if (shouldSendAsText(
      event.character,
      hasCommandModifier: hasCommandModifier,
    )) {
      _sentAsText.add(key);
      widget.onText(event.character!);
      return KeyEventResult.handled;
    }
    final vk = windowsVirtualKeyFor(key);
    if (vk == null) return KeyEventResult.ignored;
    widget.onKey(vk, true);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return Focus(
      focusNode: _focusNode,
      onKeyEvent: _onKeyEvent,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final viewport = Size(constraints.maxWidth, constraints.maxHeight);
          return Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (e) {
              // Keys only reach the remote window once this surface holds focus,
              // and a click on the picture is the gesture that means "I am
              // driving this now".
              _focusNode.requestFocus();
              _pointer(ViewerPointerAction.down, e, viewport);
            },
            onPointerMove: (e) =>
                _pointer(ViewerPointerAction.move, e, viewport),
            onPointerHover: (e) =>
                _pointer(ViewerPointerAction.move, e, viewport),
            onPointerUp: (e) => _pointer(ViewerPointerAction.up, e, viewport),
            onPointerCancel: (e) =>
                _pointer(ViewerPointerAction.up, e, viewport),
            onPointerSignal: (e) {
              if (e is! PointerScrollEvent) return;
              final frame = _frameOf(e.localPosition, viewport);
              if (frame == null) return;
              // Flutter's positive dy scrolls content down; the OS convention the
              // injector follows is positive-is-away-from-the-user.
              widget.onScroll(
                frame,
                -e.scrollDelta.dx / kLogicalPixelsPerWheelNotch,
                -e.scrollDelta.dy / kLogicalPixelsPerWheelNotch,
              );
            },
            child: MouseRegion(
              cursor: SystemMouseCursors.precise,
              child: widget.child,
            ),
          );
        },
      ),
    );
  }
}
