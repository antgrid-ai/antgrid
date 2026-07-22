import 'package:flutter/widgets.dart';

import '../../../design/ab_colors.dart';
import '../../../design/ab_tokens.dart';
import '../../../design/widgets/ab_list_row.dart';
import '../transcript_rows.dart';

/// Fallback row for a transcript item of an unrecognized kind.
class UnknownRow extends StatelessWidget {
  final UnknownRowData data;
  const UnknownRow({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final c = context.antgrid;
    final item = data.item;
    return AbListRow(
      density: AbRowDensity.sm,
      title: Text(
        '${item.kind}: ${item.text ?? ''}',
        style: AbTokens.sansStyle(
          fontSize: AbTokens.fontSm,
          color: c.textPrimary,
        ),
      ),
    );
  }
}
