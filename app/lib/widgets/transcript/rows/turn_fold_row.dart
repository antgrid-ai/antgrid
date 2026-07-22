import 'package:flutter/widgets.dart';

import '../../../design/ab_colors.dart';
import '../../../design/ab_icons.dart';
import '../../../design/ab_tokens.dart';
import '../../../design/widgets/ab_icon.dart';
import '../../../design/widgets/ab_list_row.dart';
import '../format.dart';
import '../transcript_rows.dart';

class TurnFoldRow extends StatelessWidget {
  final TurnFoldRowData data;
  final bool expanded;
  final VoidCallback onToggle;
  const TurnFoldRow({
    super.key,
    required this.data,
    required this.expanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.antgrid;
    final buf = StringBuffer(
      data.duration == null
          ? 'Worked'
          : 'Worked for ${formatDuration(data.duration!)}',
    );
    if (data.cancelled) buf.write(' · cancelled');
    return AbListRow(
      density: AbRowDensity.sm,
      onTap: onToggle,
      leading: AbIcon(
        expanded ? AbIcons.chevronDown : AbIcons.chevronRight,
        size: AbTokens.fontSm,
        color: c.textMuted,
      ),
      title: Text(
        buf.toString(),
        style: AbTokens.sansStyle(
          fontSize: AbTokens.fontSm,
          color: c.textMuted,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (data.hasError)
            AbIcon(AbIcons.error, size: AbTokens.fontSm, color: c.error),
          const SizedBox(width: AbTokens.space4),
          Text(
            '${data.hiddenCount} hidden',
            style: AbTokens.monoStyle(
              fontSize: AbTokens.fontXs,
              color: c.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}
