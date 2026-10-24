import 'package:flutter/widgets.dart';

import '../ab_colors.dart';
import '../ab_icons.dart';
import '../ab_tokens.dart';
import 'ab_focus_ring.dart';
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
class AbDisclosure extends StatefulWidget {
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
  State<AbDisclosure> createState() => _AbDisclosureState();
}

class _AbDisclosureState extends State<AbDisclosure> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // APG disclosure: the toggle is a focusable button that Enter and
        // Space operate, so a keyboard user can reach the hidden text too.
        // The detector sits outside the Semantics below so its focus state
        // survives that node's `excludeSemantics`.
        FocusableActionDetector(
          mouseCursor: SystemMouseCursors.click,
          onShowFocusHighlight: (v) {
            if (_focused != v) setState(() => _focused = v);
          },
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                widget.onToggle();
                return null;
              },
            ),
          },
          child: Semantics(
            button: true,
            label: widget.label,
            expanded: widget.expanded,
            // The real tap lands on AbTapTarget's own GestureDetector below;
            // this is the ACCESSIBLE action a screen reader invokes instead.
            // Excluding the subtree takes that GestureDetector's tap action
            // with it, and the chevron+label Text nodes too — without it a
            // screen reader reads "Why, Why" (this node's label, then the
            // descendant Text's own) and the un-excluded GestureDetector is a
            // button assistive tech can see and cannot press.
            onTap: widget.onToggle,
            excludeSemantics: true,
            child: AbTapTarget(
              onTap: widget.onToggle,
              child: AbFocusRing(
                focused: _focused,
                borderRadius: AbTokens.borderRadius3,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AbIcon(
                      widget.expanded
                          ? AbIcons.chevronDown
                          : AbIcons.chevronRight,
                      size: AbTokens.fontSm,
                      color: p.textMuted,
                    ),
                    const SizedBox(width: AbTokens.space4),
                    Text(
                      widget.label,
                      style: AbTokens.sansStyle(
                        fontSize: AbTokens.fontXs,
                        color: p.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (widget.expanded)
          Padding(
            padding: const EdgeInsets.only(
              left: AbTokens.space16,
              top: AbTokens.space4,
            ),
            child: widget.child,
          ),
      ],
    );
  }
}
