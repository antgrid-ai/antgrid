import 'package:flutter/material.dart' show Tooltip;
import 'package:flutter/widgets.dart';

import '../ab_colors.dart';
import '../ab_tokens.dart';

/// Antgrid-styled tooltip: zinc surface, 1px border, no elevation/shadow.
/// Wraps Material's [Tooltip] so its default bubble never leaks into the UI —
/// use this instead of importing Tooltip directly (see Design Rules).
class AbTooltip extends StatelessWidget {
  const AbTooltip({super.key, required this.message, required this.child});

  final String message;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.antgrid;
    return Tooltip(
      message: message,
      decoration: BoxDecoration(
        color: c.bgElevated,
        borderRadius: AbTokens.borderRadius,
        border: Border.all(color: c.borderDefault),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AbTokens.space8,
        vertical: AbTokens.space4,
      ),
      textStyle: AbTokens.sansStyle(
        fontSize: AbTokens.fontSm,
        color: c.textPrimary,
      ),
      child: child,
    );
  }
}
