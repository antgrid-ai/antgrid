import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_menu.dart';
import '../../models/agent_event.dart';
import 'format.dart';

/// Small circular gauge showing context-window usage. Renders once capacity is
/// known; occupancy fills in with the first usage frame.
class ContextMeter extends StatelessWidget {
  const ContextMeter({super.key, required this.usage});

  final AgentUsage usage;

  // Matches the rendered height of an AbChip.toggle(size: sm) pill, so the
  // meter sits flush with the MODEL/EFFORT/MODE pills it shares a row with.
  static const double _size = 16;

  @override
  Widget build(BuildContext context) {
    final window = usage.contextWindow;
    // A non-positive window cannot produce a meaningful finite fraction.
    if (window == null || window <= 0) return const SizedBox.shrink();
    // `total` accumulates across every API round-trip in the session (codex
    // sums each tool-call round-trip's full resent context), so it isn't the
    // current context-window occupancy. `last` is the most recent turn's
    // context size and is what codex's own status bar keys off of; fall back
    // to `total` for drivers (opencode) that only ever report that field.
    final active = usage.last ?? usage.total;
    final used = active.totalTokens;
    // Capacity can arrive before occupancy. Keep the meter visible but avoid
    // presenting unknown usage as a false zero percent.
    final fraction = used == null ? 0.0 : (used / window).clamp(0.0, 1.0);
    final colors = context.antgrid;
    final percentLabel = used == null ? '–%' : '${(fraction * 100).round()}%';

    return Semantics(
      label: percentLabel,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: () => _openPopover(context, fraction, used, window, active),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: _size,
              height: _size,
              child: CustomPaint(
                painter: MeterPainter(fraction: fraction, colors: colors),
              ),
            ),
            const SizedBox(width: AbTokens.space4),
            Text(
              percentLabel,
              style: AbTokens.monoStyle(
                fontSize: AbTokens.fontXs,
                color: used == null ? colors.textMuted : colors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openPopover(
    BuildContext context,
    double fraction,
    int? used,
    int window,
    AgentTokenUsage active,
  ) {
    final anchorRect = abMenuAnchorRect(context);
    if (anchorRect == null) return;

    final input = active.inputTokens;
    final output = active.outputTokens;
    final cacheRead = active.cacheReadTokens;
    final percent = used == null ? '–%' : '${(fraction * 100).round()}%';

    showAbMenu(
      context: context,
      anchorRect: anchorRect,
      header: 'Context · $percent',
      entries: [
        AbMenuItem(
          label:
              '${used == null ? '—' : formatTokens(used)} / ${formatTokens(window)} tokens',
          value: 'tokens',
        ),
        if (used != null)
          AbMenuItem(
            label: '${formatTokens(math.max(0, window - used))} free',
            value: 'free',
          ),
        if (input != null)
          AbMenuItem(label: 'input ${formatTokens(input)}', value: 'input'),
        if (output != null)
          AbMenuItem(label: 'output ${formatTokens(output)}', value: 'output'),
        if (cacheRead != null)
          AbMenuItem(
            label: 'cache read ${formatTokens(cacheRead)}',
            value: 'cache',
          ),
      ],
    );
  }
}

/// Paints the meter's background ring and progress arc. Public so tests can
/// assert the fraction->color threshold directly instead of via pixels.
class MeterPainter extends CustomPainter {
  MeterPainter({required this.fraction, required this.colors});

  final double fraction;
  final AbColors colors;

  Color get color {
    if (fraction > 0.9) return colors.error;
    if (fraction > 0.5) return colors.warning;
    return colors.accent;
  }

  // Brief-mandated literal, not a spacing/color token.
  static const double _strokeWidth = 2;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = (math.min(size.width, size.height) - _strokeWidth) / 2;

    final background = Paint()
      ..color = colors.borderDefault
      ..style = PaintingStyle.stroke
      ..strokeWidth = _strokeWidth;
    canvas.drawCircle(center, radius, background);

    final progress = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = _strokeWidth;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * fraction,
      false,
      progress,
    );
  }

  @override
  bool shouldRepaint(covariant MeterPainter oldDelegate) =>
      oldDelegate.fraction != fraction || oldDelegate.color != color;
}
