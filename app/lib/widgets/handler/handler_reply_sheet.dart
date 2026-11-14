import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../../models/handler_state.dart';
import 'handler_why.dart';

Future<String?> showHandlerReplySheet(
  BuildContext context,
  HandlerEscalation escalation,
) {
  return showCarbonModal<String>(
    context,
    builder: (_) => _HandlerReplyForm(escalation: escalation),
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
    final e = widget.escalation;
    final t = CarbonTheme.of(context);
    // Approve is disabled while the field is blank: an empty answer would
    // submit a bare Enter into the PTY (see HandlerService.reply). Rebuilds on
    // each keystroke via the controller's own ValueListenable.
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _controller,
      builder: (context, value, _) => CarbonModal(
        title: 'Handler needs you',
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
            if (e.floorRule != null) ...[
              _FloorBanner(rule: e.floorRule!),
              const SizedBox(height: CarbonSpacing.spacing03),
            ],
            CarbonTextInput(
              controller: _controller,
              variant: CarbonTextInputVariant.multiline,
              minLines: 2,
              maxLines: 6,
              semanticLabel: 'Your reply',
              placeholder: 'Your reply',
              autofocus: true,
            ),
          ],
        ),
        actions: [
          CarbonModalAction(
            label: 'Cancel',
            kind: CarbonButtonKind.secondary,
            onPressed: () => Navigator.pop(context),
          ),
          CarbonModalAction(
            label: 'Approve & send',
            onPressed: value.text.trim().isEmpty
                ? null
                : () => Navigator.pop(context, _controller.text),
          ),
        ],
      ),
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
    return CarbonNotification(
      kind: CarbonNotificationKind.warning,
      subtitle: 'Safety floor: $rule — approving sends this as YOUR reply',
    );
  }
}
