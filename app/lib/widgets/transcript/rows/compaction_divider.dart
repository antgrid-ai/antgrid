import 'package:flutter/widgets.dart';

import '../../../design/ab_colors.dart';
import '../../../design/ab_tokens.dart';
import '../../../design/widgets/ab_separator.dart';
import '../transcript_rows.dart';

/// Divider marking a context-compaction event.
class CompactionDivider extends StatelessWidget {
  final CompactionRowData data;
  const CompactionDivider({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final c = context.antgrid;
    return Row(
      children: [
        const Expanded(child: AbSeparator.horizontal()),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AbTokens.space8),
          child: Text(
            'context compacted',
            style: AbTokens.monoStyle(
              fontSize: AbTokens.fontXs,
              color: c.textMuted,
            ),
          ),
        ),
        const Expanded(child: AbSeparator.horizontal()),
      ],
    );
  }
}
