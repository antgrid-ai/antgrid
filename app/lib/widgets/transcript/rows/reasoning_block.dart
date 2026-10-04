import 'package:flutter/widgets.dart';

import '../../../design/ab_colors.dart';
import '../../../design/ab_icons.dart';
import '../../../design/ab_tokens.dart';
import '../../../design/widgets/ab_icon.dart';
import '../../../design/widgets/pulsing_opacity.dart';
import '../selection/block_source.dart';
import '../selection/transcript_selection_scope.dart';
import '../transcript_rows.dart';

class ReasoningBlock extends StatelessWidget {
  final ReasoningRowData data;
  final int rowIndex;
  final bool expanded;
  final VoidCallback onToggle;
  const ReasoningBlock({
    super.key,
    required this.data,
    required this.rowIndex,
    required this.expanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.antgrid;
    final text = data.item.text ?? '';

    if (data.isStreaming) {
      final preview = _lastTwoLines(text);
      return Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AbTokens.space8,
          vertical: AbTokens.space4,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PulsingOpacity(
              child: Text(
                'Thinking…',
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontSm,
                  color: c.textMuted,
                ),
              ),
            ),
            if (preview.isNotEmpty)
              Text(
                preview,
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontSm,
                  color: c.textMuted,
                ),
              ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AbTokens.space8,
        vertical: AbTokens.space2,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onToggle,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AbIcon(
                  expanded ? AbIcons.chevronDown : AbIcons.chevronRight,
                  size: AbTokens.fontSm,
                  color: c.textMuted,
                ),
                const SizedBox(width: AbTokens.space4),
                Text(
                  'Thought',
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontSm,
                    color: c.textMuted,
                  ),
                ),
              ],
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.only(
                left: AbTokens.space16,
                top: AbTokens.space4,
              ),
              child: SelectableBlock(
                order: rowIndex * 1000,
                sourceBuilder: () => plainTextSource(text),
                child: Text(
                  text,
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontSm,
                    color: c.textMuted,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// A streaming thought is rebuilt on every emission and only its tail is shown,
// so scan back from the end instead of splitting the whole text. Returns what
// split('\n') would keep of the last two lines.
String _lastTwoLines(String text) {
  final last = text.lastIndexOf('\n');
  if (last <= 0) return text;
  final prev = text.lastIndexOf('\n', last - 1);
  return prev < 0 ? text : text.substring(prev + 1);
}
