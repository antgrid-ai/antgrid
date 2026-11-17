import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../../models/handler_state.dart';
import 'handler_ask_footer.dart';
import 'handler_layout.dart';
import 'handler_why.dart';

/// Worn by the tapped choice while its answer is in flight.
const handlerChoiceSendingLabel = 'Sending…';

/// The card's own way out to the free-text reply sheet.
const handlerCustomReplyLabel = 'Custom reply…';

/// Inline decision card for an escalation the user can answer with one tap.
/// Rendered for two different rows, and the difference between them decides
/// almost everything below.
///
/// A QUICK-CHOICE row carries [HandlerEscalation.choices]. Every choice renders
/// the `text` it would send below its label rather than behind it: the label is
/// the judge's summary of a reply the judge also composed, that reply is typed
/// verbatim into the session, and a one-tap the user cannot read is one they
/// cannot refuse. For the same reason no choice is styled as the recommended
/// one — the wire states an order, not a preference.
///
/// An ASK carries [HandlerEscalation.askOptions] and is
/// [HandlerEscalation.nonBlocking]; both are required, because the bridge
/// strips the options in the same mutation that promotes an ask to blocking, so
/// either one alone is a row mid-frame and never a row to put buttons on.
/// Both arms carry an optional `cost` line and a judge-authored label, so the
/// read-before-you-tap floor does not distinguish them — what does is the
/// `text`: a quick choice has one to render beneath the label, verbatim and in
/// mono, because a tap sends it into the session; an ask has none, because the
/// label IS the whole payload and a tap sends nothing.
class HandlerDecisionCard extends StatefulWidget {
  const HandlerDecisionCard({
    super.key,
    required this.escalation,
    required this.onChoice,
    required this.onCustomReply,
    this.onAskOption,
    this.trailing,
    this.footer,
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

  /// Receives the tapped [HandlerAskOption.choiceId] and answers whether it
  /// reached the wire, exactly as [onChoice] does — and, exactly as [onChoice]
  /// does, null disables every option rather than latching one. That is what
  /// makes a row promoted between the render and the tap show a dead-looking
  /// button instead of a live one that answers nothing.
  final bool Function(String choiceId)? onAskOption;

  /// Session/time metadata, supplied by the caller so it matches the free-text
  /// rows sharing the section.
  final Widget? trailing;

  /// Rendered under the options and above the custom-reply button. The ask's
  /// still-working footer goes here; it is a slot rather than a field because
  /// what it says has to be derived against the owning session's live backlog,
  /// which this widget is deliberately not given.
  final Widget? footer;

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

  /// [send] is whichever of the two answer callbacks owns this row — they carry
  /// the same contract (an id in, "did it reach the wire" out) so the latching
  /// rule below can be written once for both.
  void _tap(String choiceId, bool Function(String choiceId)? send) {
    // The disabled repaint is not itself the floor: the answer clears this card
    // within a frame, and a second tap landing in that frame still runs the
    // callback the old build handed to the gesture recognizer.
    if (send == null || _pending != null) return;
    // Latched only on a send that happened. Every refusal path leaves the
    // escalation open, so latching first would trade one unsent answer for a
    // card that can never send another.
    if (!send(choiceId)) return;
    setState(() => _pending = choiceId);
  }

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final colors = theme.colors;
    final helper = theme.typography.helper.copyWith(
      color: colors.textSecondary,
    );
    final e = widget.escalation;
    final choices = e.choices ?? const <HandlerEscalationChoice>[];
    // Both halves of the ask test, together, at the one place that draws
    // buttons: the bridge clears `nonBlocking` and `askOptions` in a single
    // mutation, so a row carrying one without the other is a frame in flight
    // and never something to offer a tap on.
    final askOptions = e.nonBlocking
        ? (e.askOptions ?? const <HandlerAskOption>[])
        : const <HandlerAskOption>[];
    final answering = _pending != null;
    const gap = SizedBox(height: CarbonSpacing.spacing03);
    return HandlerBand(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              HandlerRail(
                icon: e.floorRule != null ? CarbonIcons.security : null,
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
              if (widget.trailing != null) ...[
                const SizedBox(width: CarbonSpacing.spacing03),
                widget.trailing!,
              ],
            ],
          ),
          // Everything under the question hangs off it rather than off the
          // card edge, so the block reads as one answer to one question.
          Padding(
            padding: const EdgeInsets.only(left: handlerRailInset),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (e.floorRule != null) ...[
                  const SizedBox(height: CarbonSpacing.spacing01),
                  Text(
                    'Safety floor: ${e.floorRule}',
                    style: helper.copyWith(fontWeight: FontWeight.w600),
                  ),
                ],
                // Justification for reading afterward, not input to the
                // decision. Collapsed, never removed: the escalate path's
                // `reason` is the only place a stopped session explains
                // itself.
                if (e.reasoning.trim().isNotEmpty) ...[
                  const SizedBox(height: CarbonSpacing.spacing01),
                  HandlerWhyDisclosure(escalation: e),
                ],
                if (e.nonBlocking) ...[
                  const SizedBox(height: CarbonSpacing.spacing01),
                  Text(handlerAskLatencyNote, style: helper),
                ],
                for (final c in choices) ...[
                  gap,
                  _ChoiceRow(
                    choice: c,
                    pending: _pending == c.choiceId,
                    onTap: answering || widget.onChoice == null
                        ? null
                        : () => _tap(c.choiceId, widget.onChoice),
                  ),
                ],
                for (final o in askOptions) ...[
                  gap,
                  _AskOptionRow(
                    option: o,
                    pending: _pending == o.choiceId,
                    onTap: answering || widget.onAskOption == null
                        ? null
                        : () => _tap(o.choiceId, widget.onAskOption),
                  ),
                ],
                if (widget.footer != null) ...[gap, widget.footer!],
                gap,
                Align(
                  alignment: Alignment.centerLeft,
                  child: CarbonButton(
                    label: handlerCustomReplyLabel,
                    kind: CarbonButtonKind.ghost,
                    size: CarbonButtonSize.small,
                    onPressed: widget.onCustomReply,
                  ),
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
    final theme = CarbonTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Full width and unclamped: the judge's own words replace a fixed
        // literal here and may run long enough to want more than one line.
        CarbonButton(
          label: pending ? handlerChoiceSendingLabel : choice.label,
          kind: CarbonButtonKind.tertiary,
          expand: true,
          busy: pending,
          onPressed: onTap,
        ),
        if (choice.cost != null) ...[
          const SizedBox(height: CarbonSpacing.spacing01),
          Text(
            choice.cost!,
            style: theme.typography.helper.copyWith(
              color: theme.colors.textSecondary,
            ),
          ),
        ],
        const SizedBox(height: CarbonSpacing.spacing01),
        Text(
          choice.text,
          // Code face, and still deliberately unbounded: this is verbatim what
          // lands in the session. The label names it; it does not replace it,
          // and a one-tap the user cannot read is one they cannot refuse.
          style: theme.typography.code.copyWith(
            color: theme.colors.textSecondary,
          ),
        ),
      ],
    );
  }
}

/// One tap-to-answer option on an ask: the answer itself on the button, what
/// choosing it costs underneath.
///
/// [_ChoiceRow] stacks the same way, but for a different reason: there the
/// label names a reply shown in full beneath it; here the label IS the
/// answer and runs to a sentence, so it takes the full width and the cost —
/// the thing the user weighs it against — sits directly under it.
///
/// The cost is sans, never code: nothing on this row reaches a session, and the
/// code face on this screen is what says a string is verbatim wire data.
class _AskOptionRow extends StatelessWidget {
  const _AskOptionRow({
    required this.option,
    required this.pending,
    required this.onTap,
  });

  final HandlerAskOption option;
  final bool pending;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        CarbonButton(
          label: pending ? handlerChoiceSendingLabel : option.label,
          // The judge's own pick takes the card's primary treatment. Safe here
          // and not on a quick choice for the reason the class doc gives: a tap
          // sends the agent nothing, so an emphasis that turns out to be wrong
          // costs the user a sentence in a prompt, not a command in a shell.
          kind: option.recommended
              ? CarbonButtonKind.primary
              : CarbonButtonKind.tertiary,
          expand: true,
          busy: pending,
          onPressed: onTap,
        ),
        const SizedBox(height: CarbonSpacing.spacing01),
        Text(
          option.cost,
          style: theme.typography.helper.copyWith(
            color: theme.colors.textSecondary,
          ),
        ),
      ],
    );
  }
}
