import 'package:flutter/widgets.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_tokens.dart';

/// The small muted heading above a group of fields or facts on Memory surfaces.
class MemorySectionLabel extends StatelessWidget {
  const MemorySectionLabel(
    this.text, {
    super.key,
    this.top = 0,
    this.bottom = AbTokens.space6,
  });

  final String text;
  final double top;
  final double bottom;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(top: top, bottom: bottom),
    child: Text(
      text,
      style: AbTokens.sansStyle(
        fontSize: AbTokens.fontSm,
        fontWeight: FontWeight.w600,
        color: context.antgrid.textMuted,
      ),
    ),
  );
}
