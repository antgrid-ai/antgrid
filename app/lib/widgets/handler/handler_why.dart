import 'package:flutter/widgets.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_disclosure.dart';
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
/// empty (`firstFilled(decision.notify?.body) ?? "Agent needs you"` in
/// `engine.ts`, and the same literal again in `push/compose.ts`). Read here to
/// decide whether the "Why" disclosure should open by default, and by
/// `workspace_shell.dart` for the notification body.
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
/// Owns its expanded state, unlike the [AbDisclosure] it wraps, so the one
/// recycling rule lives in one place: the card renders this through a `State`
/// reused by position in a list, and a card that scrolled onto a different
/// escalation must not open on that one's reasoning.
///
/// Callers still test [HandlerEscalation.reasoning] for emptiness themselves —
/// they own the gap that would otherwise be left above an absent row.
class HandlerWhyDisclosure extends StatefulWidget {
  const HandlerWhyDisclosure({super.key, required this.escalation});

  final HandlerEscalation escalation;

  @override
  State<HandlerWhyDisclosure> createState() => _HandlerWhyDisclosureState();
}

class _HandlerWhyDisclosureState extends State<HandlerWhyDisclosure> {
  late bool _expanded = handlerWhyOpenByDefault(widget.escalation);

  @override
  void didUpdateWidget(HandlerWhyDisclosure oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.escalation.escalationId !=
        widget.escalation.escalationId) {
      _expanded = handlerWhyOpenByDefault(widget.escalation);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return AbDisclosure(
      label: handlerWhyLabel,
      expanded: _expanded,
      onToggle: () => setState(() => _expanded = !_expanded),
      // A step up from the collapsed row's own size: this is prose the user
      // asked to see, not a caption they are meant to skim past.
      child: Text(
        widget.escalation.reasoning,
        style: AbTokens.sansStyle(
          fontSize: AbTokens.fontSm,
          color: p.textMuted,
        ),
      ),
    );
  }
}
