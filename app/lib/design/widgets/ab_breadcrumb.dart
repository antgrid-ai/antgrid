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
      final segment = isLast && leafOverride != null
          ? DefaultTextStyle.merge(style: style, child: leafOverride!)
          : Text(
              segments[i],
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            );
      // Only the LAST segment (the leaf — a session or file name, the thing
      // the user is actually looking for) is Flexible. A leading segment
      // (the project/agent name) is usually short but was given an EQUAL
      // flex share under `mainAxisSize.min` — Flutter's single-pass flex
      // layout hands each flex child its own slice of the free space and
      // never redistributes what a shorter sibling didn't use, so the leaf
      // ellipsized at half the row while the other half sat empty next to
      // it.
      //
      // A leading segment is capped with ConstrainedBox instead of left
      // unflexed: RenderFlex hands a NON-flex Row child an UNBOUNDED main-axis
      // constraint in its first layout pass (it's meant to report its own
      // natural size before free space is split among flex children) — so an
      // unflexed segment would render at its full, uncapped width and could
      // overflow the row outright for a long project/agent name, instead of
      // ellipsizing. The cap keeps it non-flex (natural width, no wasted
      // share) while still bounded; the leaf, still the sole flex child,
      // claims 100% of whatever's left after it.
      children.add(
        isLast
            ? Flexible(fit: FlexFit.loose, child: segment)
            : ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 140),
                child: segment,
              ),
      );
    }
    return Row(mainAxisSize: MainAxisSize.min, children: children);
  }
}
