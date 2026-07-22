import 'package:flutter/widgets.dart';

import '../../../design/ab_colors.dart';
import '../../../design/ab_icons.dart';
import '../../../design/ab_tokens.dart';
import '../../../design/widgets/ab_icon.dart';
import '../../../design/widgets/ab_list_row.dart';
import '../status_glyph.dart';
import '../transcript_rows.dart';

/// A delegated subagent's row: agent/title label plus its status glyph.
class SubtaskRow extends StatelessWidget {
  final SubtaskRowData data;
  const SubtaskRow({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final c = context.antgrid;
    final item = data.item;
    return AbListRow(
      density: AbRowDensity.sm,
      leading: AbIcon(
        AbIcons.services,
        size: AbTokens.fontMd,
        color: c.textMuted,
      ),
      title: Text(
        item.agent ?? item.title ?? 'subagent',
        style: AbTokens.monoStyle(
          fontSize: AbTokens.fontSm,
          color: c.textSecondary,
        ),
      ),
      trailing: statusGlyph(item.status, c),
    );
  }
}
