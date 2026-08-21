import 'package:flutter/widgets.dart';

import '../ab_tokens.dart';
import '../ab_colors.dart';

/// Shared box chrome for single-row Antgrid controls — text fields, dropdown
/// triggers, and any other control that must line up in the same column.
///
/// Renders a fixed-[height] [Container] with the standard fill,
/// [AbTokens.borderRadius5] corners, and a 1px border that turns
/// [context.antgrid.accent] when [focused] (else [context.antgrid.borderDefault]).
///
/// Centralising the recipe keeps these controls aligned pixel-for-pixel by
/// construction: a token change (height, padding, radius, border colour)
/// updates every control at once instead of letting copies drift apart.
class AbControlBox extends StatelessWidget {
  const AbControlBox({
    super.key,
    required this.child,
    this.height,
    this.focused = false,
    this.fillColor,
    this.padding,
  });

  /// Box contents (typically a [Row]). Vertically centred within [height].
  final Widget child;

  /// Outer box height. Defaults to [AbTokens.rowHeightSm].
  final double? height;

  /// Paints the border in [context.antgrid.accent] when true.
  final bool focused;

  /// Background fill. Defaults to [context.antgrid.bgSurface].
  final Color? fillColor;

  /// Inner padding. Defaults to horizontal [AbTokens.space8].
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height ?? AbTokens.rowHeightSm,
      padding:
          padding ?? const EdgeInsets.symmetric(horizontal: AbTokens.space8),
      decoration: BoxDecoration(
        color: fillColor ?? context.antgrid.bgSurface,
        borderRadius: AbTokens.borderRadius5,
        border: Border.all(
          color: focused
              ? context.antgrid.accent
              : context.antgrid.borderDefault,
        ),
      ),
      child: child,
    );
  }
}
