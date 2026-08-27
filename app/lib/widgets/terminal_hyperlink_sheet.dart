import 'package:flutter/material.dart';

import '../design/ab_colors.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_adaptive_sheet.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_dialog.dart';

/// Asks whether to open [target], showing where it actually goes.
///
/// OSC 8 lets a link's visible text disagree with its destination, so the text
/// a user taps is not evidence of anything: `https://github.com@evil.example/`
/// reads as GitHub and resolves to `evil.example`. This is what names the real
/// host wherever nothing else did — a pointer gets `TerminalHyperlinkPreview`
/// instead, and a finger gets no readout at all. Nor is a browser a backstop:
/// an activation may never reach one, because a verified App Link opens its own
/// app.
///
/// Returns false when dismissed, so a stray tap outside the sheet cancels.
Future<bool> showTerminalHyperlinkSheet(
  BuildContext context,
  Uri target,
) async {
  final confirmed = await showAbAdaptiveSheet<bool>(
    context,
    child: _TerminalHyperlinkConfirm(target: target),
  );
  return confirmed ?? false;
}

class _TerminalHyperlinkConfirm extends StatelessWidget {
  const _TerminalHyperlinkConfirm({required this.target});

  final Uri target;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: abDialogTitlePadding,
          child: abDialogTitle(
            'Open link',
            onClose: () => Navigator.pop(context, false),
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
              // The host leads, on its own line: it is the whole of what an
              // impostor URL misrepresents, and burying it inside the full
              // string is how a userinfo prefix goes unread.
              Text(
                target.host,
                style: AbTokens.monoStyle(
                  fontSize: AbTokens.fontBody,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: AbTokens.space6),
              Text(
                target.toString(),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: AbTokens.monoStyle(
                  fontSize: AbTokens.fontXs,
                  color: p.textMuted,
                ),
              ),
              const SizedBox(height: AbTokens.space8),
              Text(
                'This link was printed by the terminal, not typed by you.',
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontXs,
                  color: p.textMuted,
                ),
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
                onTap: () => Navigator.pop(context, false),
              ),
              const SizedBox(width: AbTokens.space8),
              AbButton(
                label: 'Open',
                variant: AbButtonVariant.primary,
                onTap: () => Navigator.pop(context, true),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
