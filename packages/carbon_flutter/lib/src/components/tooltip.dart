import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../foundations/theme.dart';
import '../foundations/tokens.dart';
import '../primitives/popup.dart';

/// Which edge of the trigger the tooltip lines up with, in the ambient text
/// direction.
enum CarbonTooltipAlignment {
  /// The tooltip's start edge meets the trigger's start edge.
  start,

  /// The tooltip's end edge meets the trigger's end edge.
  end,
}

/// A short supplementary description for [child], shown on hover and on
/// keyboard focus.
///
/// Triggers:
/// * Mouse hover, after [showDelay]; leaving hides it after [hideGrace], and
///   moving onto the tooltip itself keeps it open.
/// * Keyboard focus, immediately, when focus arrived through keyboard
///   navigation; a mouse click that focuses the child does not show it.
/// * Touch: a long press shows it until the user taps elsewhere. Touch users
///   get no hover, so never rely on the tooltip for anything they must read.
///
/// Dismissal: Escape (without closing an enclosing dialog), pointer leave,
/// blur, a pointer press on the child, a tap elsewhere, and the child
/// scrolling out of view. The tooltip never takes focus and does not
/// intercept the child's taps.
///
/// Accessibility: the message is exposed as the child's tooltip semantics, a
/// supplement to its name. It does NOT replace a label: an icon-only control
/// still needs its own accessible name, and instructions or validation errors
/// must be visible elsewhere because hover is unavailable on touch. The
/// tooltip holds text only; anything interactive belongs in a different
/// surface.
///
/// The tooltip aligns to the trigger's start or end edge; centering on the
/// trigger is not offered.
class CarbonTooltip extends StatefulWidget {
  const CarbonTooltip({
    super.key,
    required this.message,
    required this.child,
    this.alignment = CarbonTooltipAlignment.start,
    this.preferAbove = true,
    this.caret = true,
    this.maxWidth = 288,
    this.showDelay = const Duration(milliseconds: 200),
    this.hideGrace = const Duration(milliseconds: 100),
    this.enabled = true,
  });

  final String message;
  final Widget child;
  final CarbonTooltipAlignment alignment;

  /// Places the tooltip above the trigger when it fits, else below.
  final bool preferAbove;

  /// Draws the small pointer toward the trigger.
  final bool caret;

  final double maxWidth;
  final Duration showDelay;

  /// How long a pointer may be outside both trigger and tooltip before the
  /// tooltip hides.
  final Duration hideGrace;

  /// False renders only [child], with no tooltip semantics either.
  final bool enabled;

  @override
  State<CarbonTooltip> createState() => _CarbonTooltipState();
}

class _CarbonTooltipState extends State<CarbonTooltip> {
  final CarbonPopupController _controller = CarbonPopupController();
  Timer? _showTimer;
  Timer? _hideTimer;
  bool _hover = false;
  bool _focus = false;
  bool _touch = false;
  bool _keyHandlerAttached = false;
  bool _opening = false;

  bool get _wanted => _hover || _focus || _touch;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_syncKeyHandler);
  }

  @override
  void dispose() {
    _showTimer?.cancel();
    _hideTimer?.cancel();
    _detachKeyHandler();
    _controller.removeListener(_syncKeyHandler);
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(CarbonTooltip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && oldWidget.enabled) _reset();
  }

  void _syncKeyHandler() {
    if (_controller.isOpen) {
      if (_keyHandlerAttached) return;
      _keyHandlerAttached = true;
      HardwareKeyboard.instance.addHandler(_handleKey);
    } else {
      _detachKeyHandler();
    }
  }

  void _detachKeyHandler() {
    if (!_keyHandlerAttached) return;
    _keyHandlerAttached = false;
    HardwareKeyboard.instance.removeHandler(_handleKey);
  }

  // Escape reaches the tooltip before the focus tree, so the first press
  // dismisses it without also closing a dialog it sits in.
  bool _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape ||
        !_controller.isOpen) {
      return false;
    }
    _reset();
    return true;
  }

  void _reset() {
    _showTimer?.cancel();
    _hideTimer?.cancel();
    _hover = false;
    _focus = false;
    _touch = false;
    _controller.close();
  }

  // Opening applies pending focus changes, which can call back into the focus
  // listener that is opening the tooltip.
  void _open() {
    if (_opening) return;
    _opening = true;
    try {
      _controller.open();
    } finally {
      _opening = false;
    }
  }

  void _requestShow({required bool immediate}) {
    _hideTimer?.cancel();
    if (_controller.isOpen) return;
    _showTimer?.cancel();
    if (immediate || widget.showDelay == Duration.zero) {
      _open();
      return;
    }
    _showTimer = Timer(widget.showDelay, () {
      if (mounted && _wanted) _open();
    });
  }

  void _requestHide({required bool graceful}) {
    _showTimer?.cancel();
    _hideTimer?.cancel();
    if (_wanted) return;
    if (!graceful || widget.hideGrace == Duration.zero) {
      _controller.close();
      return;
    }
    _hideTimer = Timer(widget.hideGrace, () {
      if (mounted && !_wanted) _controller.close();
    });
  }

  void _onHover(bool hovering) {
    if (!widget.enabled) return;
    _hover = hovering;
    if (hovering) {
      _requestShow(immediate: false);
    } else {
      _requestHide(graceful: true);
    }
  }

  void _onFocusChange(bool focused) {
    if (!widget.enabled) return;
    if (focused) {
      if (FocusManager.instance.highlightMode !=
          FocusHighlightMode.traditional) {
        return;
      }
      _focus = true;
      // Opening applies pending focus changes, which must not happen while
      // the focus manager is still delivering this one.
      scheduleMicrotask(() {
        if (mounted && _focus) _requestShow(immediate: true);
      });
    } else {
      _focus = false;
      _requestHide(graceful: false);
    }
  }

  void _onLongPress() {
    if (!widget.enabled) return;
    _touch = true;
    _requestShow(immediate: true);
  }

  void _onPointerDown() {
    if (!_wanted && !_controller.isOpen) {
      _showTimer?.cancel();
      return;
    }
    _reset();
  }

  void _onDismissed(CarbonPopupDismissReason reason) {
    _hover = false;
    _focus = false;
    _touch = false;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || widget.message.isEmpty) return widget.child;
    final theme = CarbonTheme.of(context);
    final caretHeight = widget.caret ? _kCaretHeight : 0.0;

    return CarbonAnchoredPopup(
      controller: _controller,
      preferAbove: widget.preferAbove,
      alignment: widget.alignment == CarbonTooltipAlignment.start
          ? CarbonPopupAlignment.start
          : CarbonPopupAlignment.end,
      gap: CarbonSpacing.spacing02 + caretHeight,
      maxWidth: widget.maxWidth,
      raiseLayer: false,
      dismissOnEscape: false,
      dismissOnBack: false,
      onDismissed: _onDismissed,
      popupBuilder: (context, available) => MouseRegion(
        onEnter: (_) => _onHover(true),
        onExit: (_) => _onHover(false),
        child: ExcludeSemantics(
          child: _CaretBox(
            enabled: widget.caret,
            color: theme.colors.backgroundInverse,
            anchor: () {
              final box = this.context.findRenderObject();
              return box is RenderBox && box.attached ? box : null;
            },
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: theme.colors.backgroundInverse,
                borderRadius: const BorderRadius.all(CarbonShape.tooltip),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: CarbonSpacing.spacing05,
                  vertical: CarbonSpacing.spacing03,
                ),
                child: Text(
                  widget.message,
                  style: theme.typography.helper.copyWith(
                    color: theme.colors.textInverse,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      child: MergeSemantics(
        child: Semantics(
          tooltip: widget.message,
          child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) => _onPointerDown(),
          child: MouseRegion(
            onEnter: (_) => _onHover(true),
            onExit: (_) => _onHover(false),
            child: GestureDetector(
              onLongPress: _onLongPress,
              child: Focus(
                canRequestFocus: false,
                skipTraversal: true,
                includeSemantics: false,
                onFocusChange: _onFocusChange,
                child: widget.child,
              ),
            ),
          ),
        ),
        ),
      ),
    );
  }
}

const double _kCaretHeight = 6;
const double _kCaretWidth = 12;

/// Paints the tooltip's caret on the side facing [anchor], which is decided at
/// paint time so it is right whichever way the popup flipped or was clamped.
class _CaretBox extends SingleChildRenderObjectWidget {
  const _CaretBox({
    required this.enabled,
    required this.color,
    required this.anchor,
    required super.child,
  });

  final bool enabled;
  final Color color;
  final RenderBox? Function() anchor;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderCaretBox(enabled: enabled, color: color, anchor: anchor);

  @override
  void updateRenderObject(BuildContext context, _RenderCaretBox renderObject) {
    renderObject
      ..enabled = enabled
      ..color = color
      ..anchor = anchor;
  }
}

class _RenderCaretBox extends RenderProxyBox {
  _RenderCaretBox({
    required bool enabled,
    required Color color,
    required RenderBox? Function() anchor,
  }) : _enabled = enabled,
       _color = color,
       _anchor = anchor;

  bool _enabled;
  Color _color;
  RenderBox? Function() _anchor;

  set enabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    markNeedsPaint();
  }

  set color(Color value) {
    if (_color == value) return;
    _color = value;
    markNeedsPaint();
  }

  set anchor(RenderBox? Function() value) {
    _anchor = value;
    markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    if (!_enabled) return;
    final anchor = _anchor();
    if (anchor == null || !anchor.hasSize) return;
    final center = globalToLocal(
      anchor.localToGlobal(anchor.size.center(Offset.zero)),
    );
    final below = center.dy < size.height / 2;
    final x = center.dx
        .clamp(_kCaretWidth, math.max(_kCaretWidth, size.width - _kCaretWidth))
        .toDouble();
    final path = Path();
    if (below) {
      path
        ..moveTo(x - _kCaretWidth / 2, 0)
        ..lineTo(x, -_kCaretHeight)
        ..lineTo(x + _kCaretWidth / 2, 0);
    } else {
      path
        ..moveTo(x - _kCaretWidth / 2, size.height)
        ..lineTo(x, size.height + _kCaretHeight)
        ..lineTo(x + _kCaretWidth / 2, size.height);
    }
    path.close();
    context.canvas.drawPath(
      path.shift(offset),
      Paint()..color = _color,
    );
  }
}
