import 'package:flutter/widgets.dart';

import '../../../design/ab_colors.dart';
import '../../../design/ab_tokens.dart';
import '../../../models/agent_event.dart';
import '../format.dart';

/// Quiet token metadata placed at the trailing edge of a message's meta row.
class UsageFooterRow extends StatelessWidget {
  const UsageFooterRow({super.key, required this.usage});

  final AgentTokenUsage usage;

  static bool hasContent(AgentTokenUsage usage) =>
      usage.inputTokens != null ||
      usage.outputTokens != null ||
      usage.totalTokens != null ||
      (usage.cacheReadTokens ?? 0) > 0;

  @override
  Widget build(BuildContext context) {
    final colors = context.antgrid;
    final parts = <String>[
      if (usage.inputTokens != null) '${formatTokens(usage.inputTokens!)} in',
      if (usage.outputTokens != null)
        '${formatTokens(usage.outputTokens!)} out',
      if (usage.totalTokens != null) '${formatTokens(usage.totalTokens!)} tok',
      if ((usage.cacheReadTokens ?? 0) > 0)
        '${formatTokens(usage.cacheReadTokens!)} cached',
    ];
    if (parts.isEmpty) return const SizedBox.shrink();

    return Text(
      parts.join(' · '),
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.fade,
      textAlign: TextAlign.end,
      style: AbTokens.monoStyle(
        fontSize: AbTokens.fontXs,
        color: colors.textMuted,
      ),
    );
  }
}
