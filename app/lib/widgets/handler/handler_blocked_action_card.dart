import 'package:flutter/widgets.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_button.dart';
import '../../models/handler_state.dart';
import 'handler_layout.dart';

/// Retires the report. The only thing that does, on either side of the wire.
const handlerDismissLabel = 'Dismiss';

/// The way out to the free-text reply sheet, prefilled with the refused text.
const handlerReplyInsteadLabel = 'Reply instead…';

/// Inline card for an escalation the bridge raised because a harness guard —
/// the reply-shape rules, the §5.3 destructive floor, or the runaway guard —
/// refused an action Handler wanted to take (`kind: 'guard_blocked'`).
///
/// It is a REPORT, not a question: the action was never taken, so nothing the
/// agent or the user does next answers it and no later pause supersedes it.
/// That is why it carries an explicit [onDismiss] where every other row is
/// retired by the user simply carrying on.
///
/// The refused text is rendered in full rather than summarised. It is the one
/// thing the card exists to show — a rejection the user cannot read is one they
/// cannot judge — and it is deliberately NOT offered as a one-tap: a chip here
/// would re-send the exact text a guard just refused, with the thinnest possible
/// human in the loop.
class HandlerBlockedActionCard extends StatelessWidget {
  const HandlerBlockedActionCard({
    super.key,
    required this.escalation,
    required this.onDismiss,
    required this.onReply,
    this.trailing,
  });

  final HandlerEscalation escalation;

  /// Puts `handler:dismiss` on the wire. Null disables the button — the report
  /// stays readable either way, which is the state it is worth most in.
  final VoidCallback? onDismiss;

  /// Opens the free-text reply sheet on the refused draft. Offered because the
  /// user reading what Handler wanted to send is often the moment they decide to
  /// send some of it themselves.
  final VoidCallback? onReply;

  /// Session/time metadata, supplied by the caller so it matches the free-text
  /// rows sharing the section.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final e = escalation;
    // The same full-bleed band the decision card uses, so a report and a card
    // stacked in one section share a left edge and one background fill.
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: handlerGutter,
        vertical: AbTokens.space12,
      ),
      decoration: BoxDecoration(
        color: p.bgSurface,
        border: Border(
          top: BorderSide(color: p.borderDefault),
          bottom: BorderSide(color: p.borderDefault),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              HandlerRail(icon: AbIcons.shield, color: p.warning),
              const SizedBox(width: AbTokens.space8),
              Expanded(
                child: Text(
                  e.question,
                  style: AbTokens.sansStyle(fontWeight: FontWeight.w600),
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: AbTokens.space8),
                trailing!,
              ],
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: handlerRailInset),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (e.floorRule != null) ...[
                  const SizedBox(height: AbTokens.space2),
                  Text(
                    'Safety floor: ${e.floorRule}',
                    style: AbTokens.sansStyle(
                      fontSize: AbTokens.fontXs,
                      fontWeight: FontWeight.w600,
                      color: p.warning,
                    ),
                  ),
                ],
                const SizedBox(height: AbTokens.space2),
                Text(
                  e.reasoning,
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontXs,
                    color: p.textMuted,
                  ),
                ),
                if (e.draftReply.isNotEmpty) ...[
                  const SizedBox(height: AbTokens.space8),
                  Text(
                    'Handler wanted to send',
                    style: AbTokens.sansStyle(
                      fontSize: AbTokens.fontXs,
                      color: p.textMuted,
                    ),
                  ),
                  const SizedBox(height: AbTokens.space2),
                  Text(
                    e.draftReply,
                    // Mono: this is verbatim what would have landed in the
                    // session, not chrome. Unbounded for the same reason the
                    // decision card's choice text is — an ellipsis hides the
                    // half the user has to read to judge the refusal.
                    style: AbTokens.monoStyle(
                      fontSize: AbTokens.fontXs,
                      color: p.textMuted,
                    ),
                  ),
                ],
                const SizedBox(height: AbTokens.space8),
                Row(
                  children: [
                    AbButton(
                      label: handlerDismissLabel,
                      variant: AbButtonVariant.primary,
                      onTap: onDismiss,
                    ),
                    const SizedBox(width: AbTokens.space8),
                    AbButton(label: handlerReplyInsteadLabel, onTap: onReply),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
