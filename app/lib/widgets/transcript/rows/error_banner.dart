import 'package:flutter/widgets.dart';

import '../../../design/ab_colors.dart';
import '../../../design/ab_icons.dart';
import '../../../design/ab_tokens.dart';
import '../../../design/widgets/ab_chip.dart';
import '../../../design/widgets/ab_icon_button.dart';
import '../transcript_rows.dart';

/// Inline banner for a turn-level [ErrorRowData], with a dismiss affordance.
class ErrorBanner extends StatelessWidget {
  final ErrorRowData data;
  final VoidCallback onDismiss;
  const ErrorBanner({super.key, required this.data, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final c = context.antgrid;
    final error = data.error;
    return Container(
      padding: const EdgeInsets.all(AbTokens.space8),
      decoration: BoxDecoration(
        border: Border.all(color: c.error),
        color: c.error.withValues(alpha: 0.06),
        borderRadius: AbTokens.borderRadius,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AbChip.system(label: error.category, color: c.error),
              if (error.provider != null) ...[
                const SizedBox(width: AbTokens.space6),
                AbChip.system(label: error.provider!, color: c.textMuted),
              ],
              const Spacer(),
              AbIconButton(
                icon: AbIcons.close,
                tone: AbIconButtonTone.muted,
                onTap: onDismiss,
              ),
            ],
          ),
          const SizedBox(height: AbTokens.space4),
          Text(
            error.message,
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontSm,
              color: c.textPrimary,
            ),
          ),
          if (error.retryable) ...[
            const SizedBox(height: AbTokens.space4),
            Text(
              'retryable${error.retryAfterMs != null ? ' · retry in ${(error.retryAfterMs! / 1000).round()}s' : ''}',
              style: AbTokens.monoStyle(
                fontSize: AbTokens.fontXs,
                color: c.textMuted,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
