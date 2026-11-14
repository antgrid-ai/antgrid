import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../../models/handler_state.dart';

/// Label on the disclosure that hides [HandlerEscalation.reasoning] until
/// asked for. Justification for auditing later, not input to the decision —
/// the question above it is.
///
/// Lockstep pointer: the bridge's judge prompt promises the reasoning it
/// writes is "shown to them behind a \"Why\" disclosure" — see the sentence
/// containing that phrase in `bridge/src/handler/decision.ts`. Renaming this
/// without renaming that sentence makes the prompt lie to the judge about
/// where its words go; `handler_why_label_gate_test.dart` reads the bridge's
/// own literal back out of that file and asserts it matches.
const handlerWhyLabel = 'Why';

/// What `escalate()` mints for `question` when the judge's `notify.body` was
/// empty; mirrored in `engine.ts` and `push/compose.ts`.
const handlerFallbackQuestion = 'Agent needs you';

/// Whether the reasoning should be showing the moment the surface is built.
///
/// Collapsed everywhere except on the one row that gives no other way to read
/// it: a `notify.body` the judge left empty means `reason` is the sole
/// informative text on screen, and hiding it too would leave a surface whose
/// visible half says nothing.
bool handlerWhyOpenByDefault(HandlerEscalation e) =>
    e.question == handlerFallbackQuestion;

/// The "Why" disclosure over an escalation's reasoning.
///
/// One widget rather than three hand-rolled disclosures because the bridge's
/// promise to the judge — reasoning is read *afterwards*, never in order to
/// answer — is only kept if every surface that renders `reasoning` keeps it.
/// The card, the reply sheet and the ask sheet all do, and the two sheets are
/// where it matters most: that is where the user actually composes the answer
/// the question above is asking for.
///
/// The accordion item is keyed by escalation id so the one recycling rule lives
/// here: the card renders this through an element reused by position in a list,
/// and a card that scrolled onto a different escalation must remount closed
/// (or open, for the fallback question) rather than inherit the last one's
/// state. A remount also skips the open animation a toggle would play.
///
/// Callers still test [HandlerEscalation.reasoning] for emptiness themselves —
/// they own the gap that would otherwise be left above an absent row.
class HandlerWhyDisclosure extends StatelessWidget {
  const HandlerWhyDisclosure({super.key, required this.escalation});

  final HandlerEscalation escalation;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    return CarbonAccordion(
      flush: true,
      size: CarbonAccordionSize.small,
      align: CarbonAccordionAlign.start,
      children: [
        CarbonAccordionItem(
          key: ValueKey(escalation.escalationId),
          initiallyOpen: handlerWhyOpenByDefault(escalation),
          title: const Text(handlerWhyLabel),
          child: Text(
            escalation.reasoning,
            style: theme.typography.body.copyWith(
              color: theme.colors.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}
