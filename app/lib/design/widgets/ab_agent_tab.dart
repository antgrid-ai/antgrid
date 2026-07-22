import 'package:flutter/material.dart';

import '../ab_colors.dart';
import '../ab_icons.dart';
import '../ab_tokens.dart';
import 'ab_icon.dart';
import 'ab_status_pill.dart';

class AbAgentTab extends StatefulWidget {
  const AbAgentTab({
    super.key,
    required this.glyph,
    required this.name,
    required this.status,
    required this.active,
    required this.onTap,
    required this.onClose,
    this.duration,
  });

  final String glyph;
  final String name;
  final AbAgentStatus status;
  final bool active;
  final String? duration;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  State<AbAgentTab> createState() => _AbAgentTabState();
}

class _AbAgentTabState extends State<AbAgentTab>
    with SingleTickerProviderStateMixin {
  bool _hover = false;
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void initState() {
    super.initState();
    if (_pulses) _ctrl.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant AbAgentTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_pulses && !_ctrl.isAnimating) {
      _ctrl.repeat(reverse: true);
    } else if (!_pulses && _ctrl.isAnimating) {
      _ctrl.stop();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Color _dotColor(AbColors p) {
    switch (widget.status) {
      case AbAgentStatus.idle:
        return p.statusIdle;
      case AbAgentStatus.thinking:
        return p.statusThinking;
      case AbAgentStatus.running:
        return p.statusRunning;
      case AbAgentStatus.attention:
        return p.statusAttention;
      case AbAgentStatus.error:
        return p.error;
    }
  }

  bool get _pulses =>
      widget.status == AbAgentStatus.thinking ||
      widget.status == AbAgentStatus.running;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final fg = widget.active
        ? p.textPrimary
        : (_hover ? p.textSecondary : p.textMuted);

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: widget.active ? p.accent : Colors.transparent,
                width: 1.5,
              ),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 14,
                height: 14,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: p.bgRaised,
                  border: Border.all(color: p.borderDefault),
                  borderRadius: AbTokens.borderRadius3,
                ),
                child: Text(
                  widget.glyph,
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontXxs,
                    fontWeight: FontWeight.w600,
                    color: p.textMuted,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              AnimatedBuilder(
                animation: _ctrl,
                builder: (_, _) => Opacity(
                  opacity: _pulses ? 1.0 - _ctrl.value * 0.7 : 1.0,
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: _dotColor(p),
                      borderRadius: AbTokens.borderRadiusFull,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(widget.name, style: TextStyle(fontSize: AbTokens.fontMd, color: fg)),
              if (widget.duration != null) ...[
                const SizedBox(width: 6),
                Text(
                  widget.duration!,
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontXs,
                    color: widget.active ? p.textMuted : p.textDisabled,
                  ),
                ),
              ],
              const SizedBox(width: 6),
              if (_hover)
                GestureDetector(
                  onTap: widget.onClose,
                  child: AbIcon(AbIcons.close, size: 11, color: p.textMuted),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
