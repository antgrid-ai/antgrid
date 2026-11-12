import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
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
/// A tooltip nested inside another active one yields to it, so an icon-only
/// control that already names itself in a tooltip does not stack a second one
/// when the host wraps it with a richer message.
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
    this.excludeFromSemantics = false,
    this.mergeChildSemantics = true,
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

  /// False shows no tooltip and exposes no tooltip semantics; [child] keeps
  /// its place in the tree either way, so its state and focus survive the
  /// toggle.
  final bool enabled;

  /// Leaves the message out of the semantics tree. For a trigger whose
  /// accessible name already is the message, which a screen reader would
  /// otherwise read twice.
  final bool excludeFromSemantics;

  /// True (default) merges the child's semantics into one node that carries the
  /// tooltip, which is right for a single control. A child made of several
  /// controls (a field with its own clear button, a row of buttons) needs false:
  /// the tooltip then labels a group and every control inside stays a separate,
  /// reachable node.
  final bool mergeChildSemantics;

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
  bool _yielded = false;
  bool _pointerDown = false;
  Timer? _pointerTimer;
  Timer? _longPressTimer;
  Offset _pressOrigin = Offset.zero;

  bool get _active =>
      widget.enabled && widget.message.isNotEmpty && !_yielded;

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
    _pointerTimer?.cancel();
    _longPressTimer?.cancel();
    _detachKeyHandler();
    _controller.removeListener(_syncKeyHandler);
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final outer = context.dependOnInheritedWidgetOfExactType<_TooltipScope>();
    _yielded = outer != null && outer.active;
    if (!_active) _reset();
  }

  @override
  void didUpdateWidget(CarbonTooltip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_active) _reset();
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
    if (_opening || !_active) return;
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
    if (!_active) return;
    _hover = hovering;
    if (hovering) {
      _requestShow(immediate: false);
    } else {
      _requestHide(graceful: true);
    }
  }

  void _onFocusChange(bool focused) {
    if (!_active) return;
    if (focused) {
      // A mouse press also puts the focus manager in traditional mode, so the
      // pointer itself has to be ruled out.
      if (_pointerDown ||
          FocusManager.instance.highlightMode !=
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
    if (!_active) return;
    _touch = true;
    _requestShow(immediate: true);
  }

  // Focus a press hands to the child arrives after the pointer-up has been
  // dispatched, in a microtask, so the flag outlives the event by one timer.
  void _onPointerEnd() {
    _longPressTimer?.cancel();
    _pointerTimer?.cancel();
    _pointerTimer = Timer(Duration.zero, () => _pointerDown = false);
  }

  // Timed from raw pointer events rather than a long-press recognizer: a
  // recognizer in the arena holds back the child's tap-down until
  // kPressTimeout, so pressed feedback on the trigger would lag the press.
  //
  // A long press is a request for the description, not an activation: with
  // no recognizer in the arena to win it, the press is cancelled once the
  // tooltip shows, so the child sees a tap cancel instead of a tap.
  void _startLongPress(PointerDownEvent event) {
    _longPressTimer?.cancel();
    _pressOrigin = event.position;
    final pointer = event.pointer;
    _longPressTimer = Timer(kLongPressTimeout, () {
      if (!mounted) return;
      _onLongPress();
      GestureBinding.instance.cancelPointer(pointer);
    });
  }

  void _moveLongPress(PointerMoveEvent event) {
    if ((event.position - _pressOrigin).distance > kTouchSlop) {
      _longPressTimer?.cancel();
    }
  }

  void _onPointerDown() {
    _pointerTimer?.cancel();
    _pointerDown = true;
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
    final active = _active;
    final theme = CarbonTheme.of(context);

    return CarbonAnchoredPopup(
      controller: _controller,
      preferAbove: widget.preferAbove,
      alignment: widget.alignment == CarbonTooltipAlignment.start
          ? CarbonPopupAlignment.start
          : CarbonPopupAlignment.end,
      // Carbon offsets a caret tooltip 12 px from its trigger, the caret
      // included.
      gap: widget.caret ? _kCaretOffset : CarbonSpacing.spacing02,
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
                padding: const EdgeInsets.all(CarbonSpacing.spacing05),
                child: Text(
                  widget.message,
                  style: theme.typography.body.copyWith(
                    color: theme.colors.textInverse,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      child: _TooltipSemantics(
        mode: !active || widget.excludeFromSemantics
            ? _TooltipSemanticsMode.none
            : widget.mergeChildSemantics
            ? _TooltipSemanticsMode.merge
            : _TooltipSemanticsMode.group,
        message: widget.message,
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (e) {
            _onPointerDown();
            if (active) _startLongPress(e);
          },
          onPointerMove: _moveLongPress,
          onPointerUp: (_) => _onPointerEnd(),
          onPointerCancel: (_) => _onPointerEnd(),
          child: MouseRegion(
            onEnter: (_) => _onHover(true),
            onExit: (_) => _onHover(false),
            child: Focus(
              canRequestFocus: false,
              skipTraversal: true,
              includeSemantics: false,
              onFocusChange: _onFocusChange,
              child: _TooltipScope(active: active, child: widget.child),
            ),
          ),
        ),
      ),
    );
  }
}

enum _TooltipSemanticsMode { none, merge, group }

/// Attaches the tooltip string to the semantics of its child. One render
/// object serves every mode so that toggling the tooltip never changes the
/// shape of the tree, which would remount the child.
class _TooltipSemantics extends SingleChildRenderObjectWidget {
  const _TooltipSemantics({
    required this.mode,
    required this.message,
    required super.child,
  });

  final _TooltipSemanticsMode mode;
  final String message;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderTooltipSemantics(mode, message, Directionality.of(context));

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderTooltipSemantics renderObject,
  ) {
    renderObject
      ..mode = mode
      ..message = message
      ..textDirection = Directionality.of(context);
  }
}

class _RenderTooltipSemantics extends RenderProxyBox {
  _RenderTooltipSemantics(this._mode, this._message, this._textDirection);

  _TooltipSemanticsMode _mode;
  String _message;
  TextDirection _textDirection;

  set textDirection(TextDirection value) {
    if (_textDirection == value) return;
    _textDirection = value;
    markNeedsSemanticsUpdate();
  }

  set mode(_TooltipSemanticsMode value) {
    if (_mode == value) return;
    _mode = value;
    markNeedsSemanticsUpdate();
  }

  set message(String value) {
    if (_message == value) return;
    _message = value;
    markNeedsSemanticsUpdate();
  }

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    if (_mode == _TooltipSemanticsMode.none) return;
    config
      ..isSemanticBoundary = true
      ..textDirection = _textDirection
      ..tooltip = _message;
    if (_mode == _TooltipSemanticsMode.merge) {
      config.isMergingSemanticsOfDescendants = true;
    } else {
      config.explicitChildNodes = true;
    }
  }
}

/// Lets a nested [CarbonTooltip] see that an enclosing one is showing, so only
/// the outermost shows.
class _TooltipScope extends InheritedWidget {
  const _TooltipScope({required this.active, required super.child});

  final bool active;

  @override
  bool updateShouldNotify(_TooltipScope old) => old.active != active;
}

const double _kCaretHeight = 6;
const double _kCaretOffset = 12;
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
