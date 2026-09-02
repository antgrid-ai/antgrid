import 'package:flutter/widgets.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_button.dart';
import '../../models/handler_state.dart';
import 'handler_layout.dart';

/// Worn by the tapped choice while its answer is in flight.
const handlerChoiceSendingLabel = 'Sending…';

/// The card's own way out to the free-text reply sheet.
const handlerCustomReplyLabel = 'Custom reply…';

/// Inline decision card for an escalation that carries quick choices. Rendered
/// exactly when [HandlerEscalation.choices] is non-null; an escalation without
/// them keeps the free-text row it has always had.
///
/// Every choice renders the `text` it would send beside its label rather than
/// behind it: the label is the judge's summary of a reply the judge also
/// composed, and a one-tap the user cannot read is one they cannot refuse.
/// For the same reason no choice is styled as the recommended one — the wire
/// states an order, not a preference.
class HandlerDecisionCard extends StatefulWidget {
  const HandlerDecisionCard({
    super.key,
    required this.escalation,
    required this.onChoice,
    required this.onCustomReply,
    this.trailing,
  });

  final HandlerEscalation escalation;

  /// Receives the tapped [HandlerEscalationChoice.choiceId] — the id, never the
  /// text, so this surface cannot put words of its own into the session — and
  /// answers whether it reached the wire. False leaves the card exactly as it
  /// was: an unanswered escalation must stay answerable, and a card latched on
  /// a send that never happened is unanswerable from this screen.
  ///
  /// Null disables every choice, which is also what keeps the card from
  /// latching into a pending state that no answer would ever clear.
  final bool Function(String choiceId)? onChoice;

  /// Opens the free-text reply sheet. Offered alongside the choices because
  /// two or three drafted options are not proof that one of them is the answer,
  /// and never disabled: the custom-reply escape hatch is worth least in
  /// exactly the states where something else on the card has gone wrong.
  final VoidCallback? onCustomReply;

  /// Session/time metadata, supplied by the caller so it matches the free-text
  /// rows sharing the section.
  final Widget? trailing;

  @override
  State<HandlerDecisionCard> createState() => _HandlerDecisionCardState();
}

class _HandlerDecisionCardState extends State<HandlerDecisionCard> {
  String? _pending;

  @override
  void didUpdateWidget(HandlerDecisionCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Answering removes one card from a section its siblings stay in, and the
    // survivor inherits the removed card's [State] by position — without this
    // it would inherit a pending flag for a choice nobody tapped, and sit
    // disabled over an unanswered escalation.
    if (oldWidget.escalation.escalationId != widget.escalation.escalationId) {
      _pending = null;
    }
  }

  void _tap(String choiceId) {
    final onChoice = widget.onChoice;
    // The disabled repaint is not itself the floor: the answer clears this card
    // within a frame, and a second tap landing in that frame still runs the
    // callback the old build handed to the gesture recognizer.
    if (onChoice == null || _pending != null) return;
    // Latched only on a send that happened. Every refusal path leaves the
    // escalation open, so latching first would trade one unsent answer for a
    // card that can never send another.
    if (!onChoice(choiceId)) return;
    setState(() => _pending = choiceId);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final e = widget.escalation;
    final choices = e.choices ?? const <HandlerEscalationChoice>[];
    final answering = _pending != null;
    // Full-bleed band, not a floating card: the horizontal margin it used to
    // carry stacked on top of the row gutter, so a card and the free-text
    // escalation directly beneath it in the same section could never share a
    // left edge. The `bgSurface` fill still marks it as the actionable block.
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
              HandlerRail(
                icon: e.floorRule != null ? AbIcons.shield : null,
                color: p.warning,
              ),
              const SizedBox(width: AbTokens.space8),
              Expanded(
                child: Text(
                  e.question,
                  style: AbTokens.sansStyle(fontWeight: FontWeight.w600),
                ),
              ),
              if (widget.trailing != null) ...[
                const SizedBox(width: AbTokens.space8),
                widget.trailing!,
              ],
            ],
          ),
          // Everything under the question hangs off it rather than off the
          // card edge, so the block reads as one answer to one question.
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
                for (final c in choices) ...[
                  const SizedBox(height: AbTokens.space8),
                  _ChoiceRow(
                    choice: c,
                    pending: _pending == c.choiceId,
                    onTap: answering || widget.onChoice == null
                        ? null
                        : () => _tap(c.choiceId),
                  ),
                ],
                const SizedBox(height: AbTokens.space8),
                AbButton(
                  label: handlerCustomReplyLabel,
                  onTap: widget.onCustomReply,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({
    required this.choice,
    required this.pending,
    required this.onTap,
  });

  final HandlerEscalationChoice choice;
  final bool pending;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AbButton(
          label: pending ? handlerChoiceSendingLabel : choice.label,
          onTap: onTap,
        ),
        const SizedBox(width: AbTokens.space8),
        Expanded(
          child: Text(
            choice.text,
            // Mono: this is verbatim what lands in the session, not chrome.
            style: AbTokens.monoStyle(
              fontSize: AbTokens.fontXs,
              color: p.textMuted,
            ),
            // Deliberately unbounded. The wire caps `text` at 400 characters
            // and an ellipsis at three lines hides most of that on a phone —
            // a one-tap the user cannot read is one they cannot refuse, which
            // is the whole reason this text is beside the label at all.
          ),
        ),
      ],
    );
  }
}
