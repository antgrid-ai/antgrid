import 'package:flutter/widgets.dart';

import '../ab_colors.dart';
import '../ab_icons.dart';
import '../ab_tokens.dart';
import 'ab_icon.dart';
import 'ab_tap_target.dart';

/// A labelled toggle that reveals [child] on tap, collapsed by default.
///
/// For text that is justification to read afterward rather than input to
/// whatever decision sits above it — the reader should not have to scan past
/// it to find the thing that actually needs an answer. State is owned by the
/// caller ([expanded]/[onToggle]) rather than internally, so a caller that
/// recycles this widget across different subjects (a `State` reused by
/// position in a list, for instance) can reset it the same way it resets any
/// other field.
///
/// The header goes through [AbTapTarget] rather than a bare gesture region:
/// this toggle is the only way to reach the reasoning behind the one card
/// built to be answered from a phone, so it gets the same 44dp floor as any
/// other tappable control rather than the width of its own chevron and label.
///
/// Pattern shared with `widgets/transcript/rows/reasoning_block.dart`'s
/// inline "Thought" disclosure; built here so a second caller does not
/// hand-roll its own chevron+label+padding.
class AbDisclosure extends StatelessWidget {
  const AbDisclosure({
    super.key,
    required this.label,
    required this.expanded,
    required this.onToggle,
    required this.child,
  });

  final String label;
  final bool expanded;
  final VoidCallback onToggle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          button: true,
          label: label,
          expanded: expanded,
          // The real tap lands on AbTapTarget's own GestureDetector below;
          // this is the ACCESSIBLE action a screen reader invokes instead.
          // Excluding the subtree takes that GestureDetector's tap action
          // with it, and the chevron+label Text nodes too — without it a
          // screen reader reads "Why, Why" (this node's label, then the
          // descendant Text's own) and the un-excluded GestureDetector is a
          // button assistive tech can see and cannot press.
          onTap: onToggle,
          excludeSemantics: true,
          child: AbTapTarget(
            onTap: onToggle,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AbIcon(
                  expanded ? AbIcons.chevronDown : AbIcons.chevronRight,
                  size: AbTokens.fontSm,
                  color: p.textMuted,
                ),
                const SizedBox(width: AbTokens.space4),
                Text(
                  label,
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontXs,
                    color: p.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (expanded)
          Padding(
            padding: const EdgeInsets.only(
              left: AbTokens.space16,
              top: AbTokens.space4,
            ),
            child: child,
          ),
      ],
    );
  }
}
