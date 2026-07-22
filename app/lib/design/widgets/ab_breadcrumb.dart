import 'package:flutter/material.dart';

import '../ab_colors.dart';
import '../ab_tokens.dart';

/// Mono breadcrumb chip. All but the last segment render dimmed; the last
/// segment ("leaf") renders in the brightest foreground tone, matching the
/// Antgrid workspace head pattern.
class AbBreadcrumb extends StatelessWidget {
  const AbBreadcrumb({super.key, required this.segments, this.leafOverride});

  final List<String> segments;

  /// Optional widget rendered in place of the last ("leaf") segment's [Text].
  /// Wrapped in the same [Flexible] as the default leaf and given the leaf's
  /// [DefaultTextStyle], so layout and text appearance are inherited — the
  /// caller supplies content (e.g. a tappable label) without restating the
  /// style. When null, the leaf renders as plain text.
  final Widget? leafOverride;

  @override
  Widget build(BuildContext context) {
    final palette = context.antgrid;
    final children = <Widget>[];
    for (var i = 0; i < segments.length; i++) {
      final isLast = i == segments.length - 1;
      if (i > 0) {
        children.add(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AbTokens.space4),
            child: Text(
              '/',
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontSm,
                color: palette.textDisabled,
              ),
            ),
          ),
        );
      }
      // The breadcrumb owns segment appearance; an override inherits it via
      // DefaultTextStyle so callers never restate the leaf style.
      final style = AbTokens.sansStyle(
        fontSize: AbTokens.fontSm,
        color: isLast ? palette.textPrimary : palette.textMuted,
        fontWeight: isLast ? FontWeight.w500 : FontWeight.w400,
      );
      children.add(
        Flexible(
          fit: FlexFit.loose,
          child: isLast && leafOverride != null
              ? DefaultTextStyle.merge(style: style, child: leafOverride!)
              : Text(
                  segments[i],
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: style,
                ),
        ),
      );
    }
    return Row(mainAxisSize: MainAxisSize.min, children: children);
  }
}
