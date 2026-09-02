import 'package:flutter/material.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_adaptive_sheet.dart';
import '../../design/widgets/ab_button.dart';
import '../../design/widgets/ab_dialog.dart';
import '../../design/widgets/ab_icon.dart';
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
  late final TextEditingController _controller = TextEditingController(
    text: widget.escalation.draftReply,
  );

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
              if (e.floorRule != null) ...[
                _FloorBanner(rule: e.floorRule!),
                const SizedBox(height: AbTokens.space8),
              ],
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
              AbButton(label: 'Cancel', onTap: () => Navigator.pop(context)),
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

/// Warns that approving sends the reply as the user, not the agent — shown
/// only when the escalation crossed a standing-order safety floor. That floor is
/// the one tier no instruction can lift, so it always costs a human who reads
/// the text behind this banner.
class _FloorBanner extends StatelessWidget {
  const _FloorBanner({required this.rule});
  final String rule;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AbTokens.space8,
        vertical: AbTokens.space6,
      ),
      decoration: BoxDecoration(
        border: Border.all(color: p.warning),
        borderRadius: AbTokens.borderRadius3,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The same shield every other floor surface uses — the Handler tab's
          // escalation rail and its `floor_warning` feed rows. An emoji here
          // rendered in whatever the platform's font stack supplied, at a size
          // and weight nothing in the design system controlled.
          AbIcon(AbIcons.shield, size: 12, color: p.warning),
          const SizedBox(width: AbTokens.space6),
          Expanded(
            child: Text(
              'Safety floor: $rule — approving sends this as YOUR reply',
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXs,
                fontWeight: FontWeight.w600,
                color: p.warning,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
