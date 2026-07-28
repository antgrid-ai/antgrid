import 'package:flutter/material.dart';

import '../ab_colors.dart';
import '../ab_icons.dart';
import '../ab_tokens.dart';
import 'ab_icon.dart';
import 'ab_status_pill.dart';
import 'ab_tap_target.dart';

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

  // See _AbStatusPillState._syncPulse — same reduce-motion contract: started
  // in didChangeDependencies so a live MediaQuery flip stops/restarts, and
  // didUpdateWidget funnels through the same sync for status changes.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPulse();
  }

  @override
  void didUpdateWidget(covariant AbAgentTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncPulse();
  }

  void _syncPulse() {
    final animate = _pulses && !MediaQuery.disableAnimationsOf(context);
    if (animate && !_ctrl.isAnimating) {
      _ctrl.repeat(reverse: true);
    } else if (!animate && _ctrl.isAnimating) {
      _ctrl.stop();
      // Rewind so the dot rests at full opacity, not frozen mid-fade.
      _ctrl.value = 0;
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
                    // Inactive tabs de-emphasize via the name color; the
                    // duration stays muted so it remains readable.
                    color: p.textMuted,
                  ),
                ),
              ],
              const SizedBox(width: 6),
              // AbTapTarget owns the tap: inflates the 11px glyph's target on
              // touch platforms (capped by the tab's height constraint) and is
              // an opaque same-size hit area on desktop.
              if (_hover)
                AbTapTarget(
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
