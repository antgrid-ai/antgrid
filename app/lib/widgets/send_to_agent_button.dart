import 'package:flutter/material.dart';
import '../design/widgets/ab_icon.dart';

import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/ab_colors.dart';

/// A floating pill-shaped "Send to Agent" button.
/// Place inside a Stack, positioned top-right.
class SendToAgentButton extends StatelessWidget {
  final VoidCallback onPressed;

  const SendToAgentButton({super.key, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: AbTokens.space8,
      right: AbTokens.space8,
      child: GestureDetector(
        onTap: onPressed,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AbTokens.space10,
              vertical: AbTokens.space6,
            ),
            decoration: BoxDecoration(
              color: context.antgrid.bgElevated,
              borderRadius: AbTokens.borderRadius5,
              border: Border.all(
                color: context.antgrid.accent.withValues(alpha: 0.3),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AbIcon(AbIcons.send, size: 12, color: context.antgrid.accent),
                const SizedBox(width: AbTokens.space4),
                Text(
                  'Send to Agent',
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontXs,
                    color: context.antgrid.accent,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
