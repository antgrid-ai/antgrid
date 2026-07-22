import 'package:flutter/material.dart';

import '../ab_colors.dart';
import '../ab_tokens.dart';

enum AbAgentStatus { idle, thinking, running, attention, error }

/// A pill-shaped status badge showing agent state.
///
/// For [AbAgentStatus.thinking] and [AbAgentStatus.running] the dot
/// breathes (opacity 1.0 → 0.4 → 1.0, 1500ms cycle) to convey activity.
/// All other states render the dot at full opacity.
class AbStatusPill extends StatefulWidget {
  const AbStatusPill({super.key, required this.status, required this.label});

  final AbAgentStatus status;
  final String label;

  @override
  State<AbStatusPill> createState() => _AbStatusPillState();
}

class _AbStatusPillState extends State<AbStatusPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );

  @override
  void initState() {
    super.initState();
    if (_pulses) _ctrl.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant AbStatusPill oldWidget) {
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

  bool get _pulses =>
      widget.status == AbAgentStatus.thinking ||
      widget.status == AbAgentStatus.running;

  Color _color(AbColors p) {
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

  @override
  Widget build(BuildContext context) {
    final palette = context.antgrid;
    final color = _color(palette);
    final isIdle = widget.status == AbAgentStatus.idle;
    final bg = isIdle ? palette.bgRaised : color.withValues(alpha: 0.10);
    final borderColor = isIdle
        ? palette.borderDefault
        : color.withValues(alpha: 0.25);

    return Container(
      height: 22,
      padding: const EdgeInsets.only(left: 7, right: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: AbTokens.borderRadiusFull,
        border: Border.all(color: borderColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          AnimatedBuilder(
            animation: _ctrl,
            builder: (context, child) {
              final opacity = _pulses ? (1.0 - _ctrl.value * 0.6) : 1.0;
              return Opacity(
                opacity: opacity,
                child: Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: AbTokens.borderRadiusFull,
                  ),
                ),
              );
            },
          ),
          const SizedBox(width: 6),
          Text(
            widget.label,
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontXs,
              fontWeight: FontWeight.w500,
              color: color,
              height: 1.0,
            ),
          ),
        ],
      ),
    );
  }
}
