import 'package:flutter/material.dart';

import '../ab_colors.dart';
import '../ab_icons.dart';
import '../ab_tokens.dart';
import 'ab_icon.dart';

class AbBranchPill extends StatelessWidget {
  const AbBranchPill({
    super.key,
    required this.branch,
    this.ahead = 0,
    this.behind = 0,
    this.onTap,
  });

  final String branch;
  final int ahead;
  final int behind;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.antgrid;
    final child = Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: AbTokens.space8),
      decoration: BoxDecoration(
        color: palette.bgSurface,
        border: Border.all(color: palette.borderSubtle),
        borderRadius: AbTokens.borderRadiusFull,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AbIcon(AbIcons.git, size: 10, color: palette.textMuted),
          const SizedBox(width: 5), // 5px non-ladder icon→label gap (mock spec)
          // A branch name is unbounded and the pill is usually the last child of
          // a row whose other children cannot shrink, so it truncates itself
          // rather than pushing that row into an overflow.
          Flexible(
            child: Text(
              branch,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: AbTokens.monoStyle(
                fontSize: AbTokens.fontXs,
                color: palette.textMuted,
              ),
            ),
          ),
          // Behind before ahead, the order every SCM status line uses.
          if (behind > 0) ...[
            const SizedBox(width: AbTokens.space4),
            Text(
              '↓$behind',
              style: AbTokens.monoStyle(
                fontSize: AbTokens.fontXs,
                color: palette.textMuted,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
          if (ahead > 0) ...[
            const SizedBox(width: AbTokens.space4),
            Text(
              '↑$ahead',
              style: AbTokens.monoStyle(
                fontSize: AbTokens.fontXs,
                color: palette.statusRunning,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ],
      ),
    );
    if (onTap == null) return child;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: child,
      ),
    );
  }
}
