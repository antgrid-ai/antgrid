import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../../models/handler_state.dart';
import 'handler_why.dart';

/// What the ask sheet came back with.
///
/// Three outcomes, not two: `null` from the sheet means the user backed out
/// without deciding and Handler is told nothing, whereas [HandlerAskDecline] is
/// itself a decision the bridge records and parks so the judge learns not to
/// ask again. Collapsing the two would leave a standing ask with no exit but
/// answering it — the row survives a submitted line by design, so a user who
/// does not want to engage would be stuck with it until the work it named
/// finished and it was promoted into a question they must then answer anyway.
sealed class HandlerAskSheetResult {
  const HandlerAskSheetResult();
}

/// The user answered, in their own words. [text] is exactly what they typed.
class HandlerAskAnswer extends HandlerAskSheetResult {
  const HandlerAskAnswer(this.text);
  final String text;
}

/// The user chose not to answer this question.
class HandlerAskDecline extends HandlerAskSheetResult {
  const HandlerAskDecline();
}

/// Collects the user's answer to an ask, in their own words, or their refusal
/// to answer it — or null if they backed out without doing either.
///
/// Its own widget rather than a `nonBlocking` branch inside
/// `showHandlerReplySheet`, and with no prefill parameter anywhere in its API.
/// The text in this field is the one thing on the ask path that mints an
/// authorization lift, so the composer must open EMPTY: a judge-authored string
/// seeded into it would be laundered into a session-long grant the user never
/// composed, and the failure is invisible — the grant lands, and for a bare
/// host even the feed row that would have named it reports nothing. A branch
/// inside the reply sheet is one refactor away from re-seeding the controller
/// from `escalation.draftReply`; a separate widget with no such parameter is
/// not. The reply sheet's own prefill stays right where it is and stays
/// correct: there the draft is what a blocking escalation is asking the user to
/// approve.
Future<HandlerAskSheetResult?> showHandlerAskSheet(
  BuildContext context,
  HandlerEscalation escalation,
) {
  return showCarbonModal<HandlerAskSheetResult>(
    context,
    builder: (_) => _HandlerAskForm(escalation: escalation),
  );
}

class _HandlerAskForm extends StatefulWidget {
  const _HandlerAskForm({required this.escalation});
  final HandlerEscalation escalation;

  @override
  State<_HandlerAskForm> createState() => _HandlerAskFormState();
}

class _HandlerAskFormState extends State<_HandlerAskForm> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.escalation;
    final t = CarbonTheme.of(context);
    // Disabled while the field is blank: an answer of nothing retires the
    // question on this side and is refused on the other, which the user reads
    // as an answer given and then lost. Rebuilds on each keystroke via the
    // controller's own ValueListenable.
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _controller,
      builder: (context, value, _) => CarbonModal(
        // Deliberately not the reply sheet's 'Handler needs you': the agent
        // is still working, and a title that says it stopped is the one
        // thing this whole shape exists to stop telling the user.
        title: 'Handler has a question',
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              e.question,
              style: t.typography.body.copyWith(
                color: t.colors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
            // Behind a disclosure, exactly as on the card: the judge is told
            // its reasoning is read afterward and never in order to answer,
            // and this sheet is where the answer is actually composed. An
            // always-open block here would push the field the user came for
            // below the fold and make that promise false where it counts.
            if (e.reasoning.trim().isNotEmpty) ...[
              const SizedBox(height: CarbonSpacing.spacing03),
              HandlerWhyDisclosure(escalation: e),
            ],
            const SizedBox(height: CarbonSpacing.spacing05),
            CarbonTextInput(
              controller: _controller,
              variant: CarbonTextInputVariant.multiline,
              minLines: 2,
              maxLines: 6,
              semanticLabel: 'Your answer',
              placeholder: 'Your answer',
              autofocus: true,
            ),
          ],
        ),
        actions: [
          // Distinct from closing the sheet, which decides nothing. This is
          // the only exit from a standing ask that is not an answer, and it
          // reaches the bridge's own decline path — which parks the refusal so
          // the judge does not simply ask again.
          CarbonModalAction(
            label: "Don't answer",
            kind: CarbonButtonKind.tertiary,
            onPressed: () => Navigator.pop(context, const HandlerAskDecline()),
          ),
          CarbonModalAction(
            label: 'Cancel',
            kind: CarbonButtonKind.secondary,
            onPressed: () => Navigator.pop(context),
          ),
          CarbonModalAction(
            label: 'Send answer',
            onPressed: value.text.trim().isEmpty
                ? null
                : () => Navigator.pop(
                    context,
                    HandlerAskAnswer(_controller.text),
                  ),
          ),
        ],
      ),
    );
  }
}
