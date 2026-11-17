import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../../models/handler_state.dart';
import 'handler_layout.dart';

/// Retires the report. The only thing that does, on either side of the wire.
const handlerDismissLabel = 'Dismiss';

/// The way out to the free-text reply sheet, prefilled with the refused text.
const handlerReplyInsteadLabel = 'Reply instead…';

/// Inline card for an escalation the bridge raised because a harness guard —
/// the reply-shape rules, the hard destructive floor, or the runaway guard —
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
    final theme = CarbonTheme.of(context);
    final colors = theme.colors;
    final e = escalation;
    final helper = theme.typography.helper.copyWith(color: colors.textSecondary);
    // The same full-bleed band the decision card uses, so a report and a card
    // stacked in one section share a left edge and one background fill.
    return HandlerBand(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              HandlerRail(
                icon: CarbonIcons.security,
                color: colors.supportWarning,
              ),
              const SizedBox(width: CarbonSpacing.spacing03),
              Expanded(
                child: Text(
                  e.question,
                  style: theme.typography.body.copyWith(
                    color: colors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: CarbonSpacing.spacing03),
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
                  const SizedBox(height: CarbonSpacing.spacing01),
                  Text(
                    'Safety floor: ${e.floorRule}',
                    style: helper.copyWith(fontWeight: FontWeight.w600),
                  ),
                ],
                const SizedBox(height: CarbonSpacing.spacing01),
                Text(e.reasoning, style: helper),
                if (e.draftReply.isNotEmpty) ...[
                  const SizedBox(height: CarbonSpacing.spacing03),
                  Text('Handler wanted to send', style: helper),
                  const SizedBox(height: CarbonSpacing.spacing01),
                  Text(
                    e.draftReply,
                    // Verbatim what would have landed in the session, not
                    // chrome. Unbounded for the same reason the decision
                    // card's choice text is — an ellipsis hides the half the
                    // user has to read to judge the refusal.
                    style: theme.typography.code.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ],
                const SizedBox(height: CarbonSpacing.spacing04),
                Wrap(
                  spacing: CarbonSpacing.spacing03,
                  runSpacing: CarbonSpacing.spacing03,
                  children: [
                    CarbonButton(
                      label: handlerDismissLabel,
                      size: CarbonButtonSize.small,
                      onPressed: onDismiss,
                    ),
                    CarbonButton(
                      label: handlerReplyInsteadLabel,
                      kind: CarbonButtonKind.tertiary,
                      size: CarbonButtonSize.small,
                      onPressed: onReply,
                    ),
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
