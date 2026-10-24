import 'package:flutter/material.dart'
    show Tooltip, TooltipState, TooltipTriggerMode;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../ab_colors.dart';
import '../ab_tokens.dart';

/// Antgrid-styled tooltip: zinc surface, 1px border, no elevation/shadow.
/// Wraps Material's [Tooltip] so its default bubble never leaks into the UI —
/// use this instead of importing Tooltip directly (see Design Rules).
///
/// Follows the APG tooltip pattern where Material's does not: keyboard focus
/// landing on the trigger shows the tooltip and losing it hides it, and Escape
/// dismisses a visible tooltip without moving focus. Material only reacts to
/// pointers, so a keyboard user otherwise never sees an icon button's name.
class AbTooltip extends StatefulWidget {
  const AbTooltip({
    super.key,
    required this.message,
    required this.child,
    this.triggerMode,
    this.excludeFromSemantics = false,
  });

  final String message;
  final Widget child;

  /// Null keeps Material's default (long-press on touch, hover on a pointer).
  /// Pass [TooltipTriggerMode.tap] where the child is a bare glyph carrying
  /// meaning no label spells out — a long-press is not discoverable enough to
  /// be that glyph's only explanation on touch.
  final TooltipTriggerMode? triggerMode;

  /// For a child that already carries [message] as its own accessible name,
  /// where announcing the tooltip as well would read it twice.
  final bool excludeFromSemantics;

  // Cap long messages without hiding their text inside a WidgetSpan, whose
  // plain-text representation loses the tooltip's accessibility label.
  static const double _kMaxWidth = 280;

  @override
  State<AbTooltip> createState() => _AbTooltipState();
}

class _AbTooltipState extends State<AbTooltip> {
  final _tooltipKey = GlobalKey<TooltipState>();
  bool _shownForFocus = false;

  void _onFocusChange(bool focused) {
    // Keyboard focus only: a click also focuses the trigger, and the pointer
    // already drives the tooltip on its own.
    final keyboard =
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    if (focused && keyboard) {
      _shownForFocus =
          _tooltipKey.currentState?.ensureTooltipVisible() ?? false;
    } else if (!focused && _shownForFocus) {
      _shownForFocus = false;
      Tooltip.dismissAllToolTips();
    }
  }

  KeyEventResult _onKeyEvent(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape) {
      return KeyEventResult.ignored;
    }
    // Only a tooltip that was actually showing consumes Escape; otherwise it
    // carries on to whatever closes the surrounding dialog or panel.
    _shownForFocus = false;
    return Tooltip.dismissAllToolTips()
        ? KeyEventResult.handled
        : KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.antgrid;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: _onFocusChange,
      onKeyEvent: _onKeyEvent,
      child: Tooltip(
        key: _tooltipKey,
        message: widget.message,
        constraints: const BoxConstraints(maxWidth: AbTooltip._kMaxWidth),
        textStyle: AbTokens.sansStyle(
          fontSize: AbTokens.fontSm,
          color: c.textPrimary,
        ),
        triggerMode: widget.triggerMode,
        excludeFromSemantics: widget.excludeFromSemantics,
        decoration: BoxDecoration(
          color: c.bgElevated,
          borderRadius: AbTokens.borderRadius,
          border: Border.all(color: c.borderDefault),
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: AbTokens.space8,
          vertical: AbTokens.space4,
        ),
        child: widget.child,
      ),
    );
  }
}
