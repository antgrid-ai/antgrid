import 'package:flutter/material.dart' show Tooltip, TooltipTriggerMode;
import 'package:flutter/widgets.dart';

import '../ab_colors.dart';
import '../ab_tokens.dart';

/// Antgrid-styled tooltip: zinc surface, 1px border, no elevation/shadow.
/// Wraps Material's [Tooltip] so its default bubble never leaks into the UI —
/// use this instead of importing Tooltip directly (see Design Rules).
class AbTooltip extends StatelessWidget {
  const AbTooltip({
    super.key,
    required this.message,
    required this.child,
    this.triggerMode,
  });

  final String message;
  final Widget child;

  /// Null keeps Material's default (long-press on touch, hover on a pointer).
  /// Pass [TooltipTriggerMode.tap] where the child is a bare glyph carrying
  /// meaning no label spells out — a long-press is not discoverable enough to
  /// be that glyph's only explanation on touch.
  final TooltipTriggerMode? triggerMode;

  // A plain [Tooltip.message] renders as one unwrapped line sized to the
  // text's own intrinsic width — Flutter clamps the bubble's POSITION to the
  // overlay (the whole window), never its width to the widget it's anchored
  // under, so a long message (a commit subject, a full timestamp) renders
  // wide enough to spill over neighboring panes on both sides. Routing
  // through [Tooltip.richMessage] instead lets a [ConstrainedBox] cap the
  // bubble's width and wrap the text inside it.
  static const double _kMaxWidth = 280;

  @override
  Widget build(BuildContext context) {
    final c = context.antgrid;
    return Tooltip(
      richMessage: WidgetSpan(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _kMaxWidth),
          child: Text(
            message,
            softWrap: true,
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontSm,
              color: c.textPrimary,
            ),
          ),
        ),
      ),
      triggerMode: triggerMode,
      decoration: BoxDecoration(
        color: c.bgElevated,
        borderRadius: AbTokens.borderRadius,
        border: Border.all(color: c.borderDefault),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AbTokens.space8,
        vertical: AbTokens.space4,
      ),
      child: child,
    );
  }
}
