import 'package:flutter/material.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_adaptive_sheet.dart';
import '../../design/widgets/ab_button.dart';
import '../../design/widgets/ab_dialog.dart';
import '../../design/widgets/ab_text_field.dart';
import '../../models/handler_state.dart';

Future<String?> showHandlerReplySheet(
  BuildContext context,
  HandlerEscalation escalation,
) {
  return showAbAdaptiveSheet<String>(
    context,
    child: _HandlerReplyForm(escalation: escalation),
  );
}

class _HandlerReplyForm extends StatefulWidget {
  const _HandlerReplyForm({required this.escalation});
  final HandlerEscalation escalation;

  @override
  State<_HandlerReplyForm> createState() => _HandlerReplyFormState();
}

class _HandlerReplyFormState extends State<_HandlerReplyForm> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.escalation.draftReply);

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
            'Handler needs you',
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
                hintText: 'Your reply',
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
              AbButton(
                label: 'Cancel',
                onTap: () => Navigator.pop(context),
              ),
              const SizedBox(width: AbTokens.space8),
              // Disabled while the field is blank: an empty answer would submit
              // a bare Enter into the PTY (see HandlerService.reply). Rebuilds
              // on each keystroke via the controller's own ValueListenable.
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _controller,
                builder: (_, value, _) => AbButton(
                  label: 'Approve & send',
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
