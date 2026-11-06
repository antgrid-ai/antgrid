import 'package:flutter/widgets.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_tokens.dart';

enum MemoryTagSize { row, detail, detailCompact }

class MemoryTag extends StatelessWidget {
  const MemoryTag({
    super.key,
    required this.label,
    this.filled = false,
    this.size = MemoryTagSize.row,
  });

  final String label;
  final bool filled;
  final MemoryTagSize size;

  @override
  Widget build(BuildContext context) {
    final colors = context.antgrid;
    final (height, fontSize, padding) = switch (size) {
      MemoryTagSize.row => (18.0, AbTokens.fontXs, AbTokens.space6),
      MemoryTagSize.detail => (20.0, AbTokens.fontXs, AbTokens.space8),
      MemoryTagSize.detailCompact => (22.0, AbTokens.fontSm, AbTokens.space8),
    };
    return Container(
      height: height,
      padding: EdgeInsets.symmetric(
        horizontal: filled ? AbTokens.space8 : padding,
      ),
      decoration: BoxDecoration(
        color: filled ? colors.textSecondary : null,
        border: filled ? null : Border.all(color: colors.borderStrong),
        borderRadius: AbTokens.borderRadius3,
      ),
      // widthFactor keeps the tag as wide as its label while centring it
      // vertically; Container.alignment would stretch it across a Wrap.
      child: Align(
        widthFactor: 1,
        child: Text(
          label,
          maxLines: 1,
          softWrap: false,
          style: AbTokens.sansStyle(
            fontSize: fontSize,
            color: filled ? colors.bgDeepest : colors.textSecondary,
          ),
        ),
      ),
    );
  }
}
