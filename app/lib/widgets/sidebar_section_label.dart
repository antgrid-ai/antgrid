import 'package:flutter/material.dart';

import '../design/ab_colors.dart';
import '../design/ab_tokens.dart';

/// The section label of the phone's home and machine picker (the "PROJECTS"
/// treatment), optionally counted and tinted.
class SidebarSectionLabel extends StatelessWidget {
  const SidebarSectionLabel({
    super.key,
    required this.label,
    this.count,
    this.color,
    this.trailing,
  });

  final String label;
  final int? count;
  final Color? color;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final style = AbTokens.sansStyle(
      fontSize: AbTokens.fontXs,
      color: color ?? context.antgrid.textMuted,
      letterSpacing: 1.4,
      fontWeight: FontWeight.w600,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AbTokens.drawerGutter,
        AbTokens.space10,
        AbTokens.drawerGutter,
        AbTokens.space6,
      ),
      child: Row(
        children: [
          Text(label, style: style),
          if (count != null) ...[
            const SizedBox(width: AbTokens.space6),
            Text('· $count', style: style.copyWith(letterSpacing: 0)),
          ],
          const Spacer(),
          ?trailing,
        ],
      ),
    );
  }
}
