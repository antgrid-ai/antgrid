import 'package:flutter/widgets.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_button.dart';
import '../../design/widgets/ab_icon.dart';
import '../../design/widgets/ab_inline_banner.dart';

class MemoryOffState extends StatelessWidget {
  const MemoryOffState({
    super.key,
    required this.onTurnOn,
    this.busy = false,
    this.error,
  });

  final VoidCallback? onTurnOn;
  final bool busy;
  final String? error;

  static const _bullets = [
    'Stored only on this machine, never in your repository.',
    'You can read, edit or forget any memory here.',
    "Each agent's own built-in memory keeps working as before.",
  ];

  @override
  Widget build(BuildContext context) {
    final colors = context.antgrid;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AbTokens.space24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AbIcon(
                AbIcons.lightbulb,
                size: AbTokens.fontDisplaySm,
                color: colors.textSecondary,
              ),
              const SizedBox(height: AbTokens.space16),
              Text(
                'Let your agents remember what they learn',
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontXl,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: AbTokens.space16),
              Text(
                'With Memory on, a fix Codex worked out yesterday is there for Claude Code today. Agents save short notes about this repository as they work, and look them up when they need them.',
                style: AbTokens.sansStyle(
                  color: colors.textSecondary,
                  height: 1.6,
                ),
              ),
              const SizedBox(height: AbTokens.space16),
              for (final bullet in _bullets)
                Padding(
                  padding: const EdgeInsets.only(bottom: AbTokens.space6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '–',
                        style: AbTokens.sansStyle(
                          fontSize: AbTokens.fontMd,
                          color: colors.textMuted,
                        ),
                      ),
                      const SizedBox(width: AbTokens.space8),
                      Expanded(
                        child: Text(
                          bullet,
                          style: AbTokens.sansStyle(fontSize: AbTokens.fontMd),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: AbTokens.space10),
              if (error case final error?) ...[
                AbInlineBanner(text: error, color: colors.error),
                const SizedBox(height: AbTokens.space8),
              ],
              AbButton(
                label: 'Turn on Memory',
                variant: AbButtonVariant.primary,
                onTap: busy ? null : onTurnOn,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
