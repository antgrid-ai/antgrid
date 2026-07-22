import 'package:flutter/widgets.dart';

import '../../../design/ab_colors.dart';
import '../../../design/ab_tokens.dart';
import '../../../design/widgets/pulsing_opacity.dart';
import '../../../models/agent_event.dart';
import '../selection/block_source.dart';
import '../selection/transcript_selection_scope.dart';
import '../transcript_rows.dart';

/// Live plan checklist: header shows completed/total, each entry gets a
/// status glyph (done/running/pending) and struck-through text once done.
class PlanChecklist extends StatelessWidget {
  final PlanRowData data;
  final int rowIndex;
  const PlanChecklist({super.key, required this.data, required this.rowIndex});

  @override
  Widget build(BuildContext context) {
    final c = context.antgrid;
    final entries = data.item.entries ?? const [];
    final done = entries.where((e) => e.status == 'completed').length;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AbTokens.space8,
        vertical: AbTokens.space4,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Plan · $done/${entries.length}',
            style: AbTokens.monoStyle(
              fontSize: AbTokens.fontXs,
              color: c.textMuted,
            ),
          ),
          const SizedBox(height: AbTokens.space4),
          SelectableBlock(
            order: rowIndex * 1000,
            sourceBuilder: () => planSource(entries),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [for (final e in entries) _entry(e, c)],
            ),
          ),
        ],
      ),
    );
  }

  Widget _entry(PlanEntry e, AbColors c) {
    final glyph = switch (e.status) {
      'completed' => Text(
        '●',
        style: AbTokens.monoStyle(fontSize: AbTokens.fontSm, color: c.success),
      ),
      'running' => PulsingOpacity(
        child: Text(
          '◐',
          style: AbTokens.monoStyle(fontSize: AbTokens.fontSm, color: c.accent),
        ),
      ),
      _ => Text(
        '○',
        style: AbTokens.monoStyle(
          fontSize: AbTokens.fontSm,
          color: c.textMuted,
        ),
      ),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: AbTokens.space2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          glyph,
          const SizedBox(width: AbTokens.space6),
          Expanded(
            child: Text(
              e.text,
              style:
                  AbTokens.sansStyle(
                    fontSize: AbTokens.fontSm,
                    color: e.status == 'completed'
                        ? c.textMuted
                        : c.textPrimary,
                    // decoration is a TextStyle field, not a sansStyle param.
                  ).copyWith(
                    decoration: e.status == 'completed'
                        ? TextDecoration.lineThrough
                        : null,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}
