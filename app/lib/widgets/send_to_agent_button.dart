import 'package:flutter/material.dart';
import '../design/widgets/ab_icon.dart';

import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/ab_colors.dart';

/// A floating pill-shaped "Send to Agent" button.
/// Place inside a Stack, positioned top-right.
class SendToAgentButton extends StatelessWidget {
  final VoidCallback onPressed;

  /// Tracks this button's position so the follow-up comment popover
  /// (`showSendToAgentComment`'s `anchorLink`) can hang off it instead of
  /// opening in the window's centre — the caller owns the link so it can
  /// pass the SAME one to that call.
  final LayerLink link;

  const SendToAgentButton({
    super.key,
    required this.onPressed,
    required this.link,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: AbTokens.space8,
      right: AbTokens.space8,
      child: CompositedTransformTarget(
        link: link,
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
                  AbIcon(
                    AbIcons.send,
                    size: 12,
                    color: context.antgrid.accent,
                  ),
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
      ),
    );
  }
}
