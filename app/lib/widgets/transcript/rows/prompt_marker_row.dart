import 'package:flutter/widgets.dart';

import '../../../design/ab_colors.dart';
import '../../../design/ab_tokens.dart';
import '../transcript_rows.dart';

/// Chronological stub standing in for a pending permission/question, which
/// renders fully in the pinned panel rather than inline in the transcript.
class PromptMarkerRow extends StatelessWidget {
  final PromptMarkerRowData data;
  final VoidCallback? onTap;
  const PromptMarkerRow({super.key, required this.data, this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.antgrid;
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AbTokens.space12,
          vertical: AbTokens.space6,
        ),
        child: Text(
          '⧖ waiting for ${data.isPermission ? 'approval' : 'an answer'}',
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontSm,
            color: c.warning,
          ),
        ),
      ),
    );
  }
}
