import 'package:flutter/widgets.dart';

import '../ab_colors.dart';
import '../ab_icons.dart';
import '../ab_tokens.dart';
import 'ab_icon.dart';

/// The chevron that opens and closes a sidebar row's sub-tree, boxed to the
/// drawer's leading slot so a glyph swapped in beside it never shifts the title.
///
/// One widget rather than a copy per row: slot width, glyph size, tint and turn
/// duration have to agree down the whole column or the sidebar reads as ragged,
/// and four hand-rolled copies had already started to drift.
class AbDisclosureChevron extends StatelessWidget {
  const AbDisclosureChevron({super.key, required this.expanded, this.color});

  /// Points down when true, right when false.
  final bool expanded;

  /// Overrides the default muted tint. A caller wanting a dimmed chevron passes
  /// a pre-dimmed colour rather than wrapping this in `Opacity`, which would
  /// composite a layer to reach the same pixels.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: AbTokens.drawerLeadingSlot,
      height: AbTokens.drawerLeadingSlot,
      child: Center(
        child: AnimatedRotation(
          turns: expanded ? 0.25 : 0,
          duration: const Duration(milliseconds: 120),
          child: AbIcon(
            AbIcons.chevronRight,
            size: 10,
            color: color ?? context.antgrid.textMuted,
          ),
        ),
      ),
    );
  }
}
