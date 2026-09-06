import 'package:flutter/material.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_adaptive_sheet.dart';
import '../../design/widgets/ab_button.dart';
import '../../design/widgets/ab_dialog.dart';
import '../../design/widgets/ab_text_field.dart';
import '../../models/handler_state.dart';

/// Collects the user's answer to an ask, in their own words, and returns it —
/// or null if they backed out.
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
Future<String?> showHandlerAskSheet(
  BuildContext context,
  HandlerEscalation escalation,
) {
  return showAbAdaptiveSheet<String>(
    context,
    child: _HandlerAskForm(escalation: escalation),
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
    final p = context.antgrid;
    final e = widget.escalation;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: abDialogTitlePadding,
          child: abDialogTitle(
            // Deliberately not the reply sheet's 'Handler needs you': the agent
            // is still working, and a title that says it stopped is the one
            // thing this whole shape exists to stop telling the user.
            'Handler has a question',
            onClose: () => Navigator.pop(context),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AbTokens.space16,
            AbTokens.space8,
            AbTokens.space16,
            0,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                e.question,
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontBody,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: AbTokens.space8),
              Text(
                e.reasoning,
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontXs,
                  color: p.textMuted,
                ),
              ),
              const SizedBox(height: AbTokens.space12),
              AbTextField(
                controller: _controller,
                hintText: 'Your answer',
                autofocus: true,
              ),
            ],
          ),
        ),
        const SizedBox(height: AbTokens.space16),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AbTokens.space16,
            0,
            AbTokens.space16,
            AbTokens.space16,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              AbButton(label: 'Cancel', onTap: () => Navigator.pop(context)),
              const SizedBox(width: AbTokens.space8),
              // Disabled while the field is blank: an answer of nothing retires
              // the question on this side and is refused on the other, which
              // the user reads as an answer given and then lost. Rebuilds on
              // each keystroke via the controller's own ValueListenable.
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _controller,
                builder: (_, value, _) => AbButton(
                  label: 'Send answer',
                  variant: AbButtonVariant.primary,
                  onTap: value.text.trim().isEmpty
                      ? null
                      : () => Navigator.pop(context, _controller.text),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
