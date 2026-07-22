import 'package:flutter/material.dart';

import '../design/ab_tokens.dart';
import '../design/ab_colors.dart';

/// VS Code-style flat tab with bottom border indicator.
class TabItem extends StatefulWidget {
  final Widget leading;
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const TabItem({
    super.key,
    required this.leading,
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  State<TabItem> createState() => _TabItemState();

  /// The standard background color for a tab bar container.
  static Color tabBarColor(BuildContext context) => context.antgrid.bgDeep;
}

class _TabItemState extends State<TabItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final fg = widget.isActive ? context.antgrid.accent : context.antgrid.textMuted;
    final bg = _hovered && !widget.isActive
        ? context.antgrid.bgSurface
        : context.antgrid.bgDeep;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AbTokens.space14,
            vertical: AbTokens.space8,
          ),
          decoration: BoxDecoration(
            color: bg,
            border: Border(
              bottom: BorderSide(
                color: widget.isActive ? context.antgrid.accent : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconTheme(
                data: IconThemeData(size: 16, color: fg),
                child: widget.leading,
              ),
              const SizedBox(width: AbTokens.space6),
              Text(
                widget.label,
                style: AbTokens.sansStyle(
                  fontWeight: widget.isActive
                      ? FontWeight.w600
                      : FontWeight.normal,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
