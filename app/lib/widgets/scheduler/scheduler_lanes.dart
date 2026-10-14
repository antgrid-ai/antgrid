import 'package:flutter/widgets.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_tooltip.dart';
import '../../models/scheduler.dart';
import 'scheduler_format.dart';

/// The bridge pages `upcoming` at this size, so a full page means "at least".
const _upcomingPage = 48;

/// Totals for the next 24 hours across every enabled schedule, not just the
/// lanes that fit in the strip.
({int runs, bool capped, SchedulerLane? next}) schedulerHorizonSummary(
  Iterable<AgentSchedule> schedules,
  DateTime now,
) {
  final all = schedulerLanes(schedules, now, max: 1 << 30).lanes;
  return (
    runs: all.fold(0, (sum, lane) => sum + lane.dots.length),
    capped: all.any((lane) => lane.schedule.upcoming.length >= _upcomingPage),
    next: all.firstOrNull,
  );
}

/// "Next 24 hours" strip: one lane per schedule, a dot per occurrence.
class SchedulerLaneStrip extends StatelessWidget {
  const SchedulerLaneStrip({
    super.key,
    required this.schedules,
    required this.now,
    required this.viewerZone,
  });

  final List<AgentSchedule> schedules;
  final DateTime now;
  final String viewerZone;

  static const _labelWidth = 168.0;
  static const _laneHeight = 22.0;
  static const _axisHeight = 16.0;
  static const _dense = 12;
  static const _horizon = Duration(hours: 24);

  double _fraction(DateTime t) =>
      t.difference(now).inMilliseconds / _horizon.inMilliseconds;

  List<({double at, String label})> _ticks() {
    final ticks = <({double at, String label})>[];
    const step = Duration(minutes: 15);
    var t = DateTime.fromMillisecondsSinceEpoch(
      (now.millisecondsSinceEpoch ~/ step.inMilliseconds + 1) *
          step.inMilliseconds,
      isUtc: true,
    );
    final end = now.add(_horizon);
    while (t.isBefore(end)) {
      final clock = schedulerClock(t, viewerZone);
      if (const {'06:00', '12:00', '18:00'}.contains(clock)) {
        ticks.add((at: _fraction(t), label: clock));
      }
      t = t.add(step);
    }
    return ticks;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final built = schedulerLanes(schedules, now);
    if (built.lanes.isEmpty) return const SizedBox.shrink();
    final summary = schedulerHorizonSummary(schedules, now);
    final next = summary.next;
    final midnight = schedulerNextMidnight(now, viewerZone);
    final midnightAt = _fraction(midnight);
    final ticks = _ticks();
    final mono = AbTokens.monoStyle(
      fontSize: AbTokens.fontXxs,
      color: p.textSecondary,
    );

    Widget axis(double width) => SizedBox(
      height: _axisHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(left: 0, child: Text('now', style: mono)),
          for (final tick in ticks)
            Positioned(
              left: tick.at * width,
              child: FractionalTranslation(
                translation: const Offset(-0.5, 0),
                child: Text(tick.label, style: mono),
              ),
            ),
          Positioned(
            left: midnightAt * width,
            child: FractionalTranslation(
              translation: const Offset(-0.5, 0),
              child: Text(
                schedulerWeekday(midnight, viewerZone),
                style: mono.copyWith(color: p.textPrimary),
              ),
            ),
          ),
        ],
      ),
    );

    Widget grid(double width) => Stack(
      children: [
        for (final tick in ticks)
          Positioned(
            left: tick.at * width,
            top: 0,
            bottom: 0,
            child: Container(width: 1, color: p.borderDefault),
          ),
        Positioned(
          left: midnightAt * width,
          top: 0,
          bottom: 0,
          child: Container(width: 1, color: p.borderStrong),
        ),
      ],
    );

    Widget lane(SchedulerLane lane, double width) {
      final dense = lane.dots.length > _dense;
      final size = dense ? AbTokens.dotSizeSm : AbTokens.dotSizeMd;
      final color = dense ? p.textSecondary.withValues(alpha: 0.55) : p.accent;
      return Row(
        children: [
          SizedBox(
            width: _labelWidth,
            child: Text(
              lane.schedule.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontSm,
                color: p.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: AbTokens.space12),
          SizedBox(
            width: width,
            height: _laneHeight,
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: p.bgRaised)),
              ),
              child: Stack(
                children: [
                  Positioned.fill(child: grid(width)),
                  for (final dot in lane.dots)
                    Positioned(
                      left: _fraction(dot) * width - size / 2,
                      top: (_laneHeight - size) / 2,
                      child: AbTooltip(
                        message:
                            '${schedulerWeekday(dot, viewerZone)} ${schedulerClock(dot, viewerZone)}',
                        child: Container(
                          width: size,
                          height: size,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: color,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    final strong = AbTokens.sansStyle(
      fontSize: AbTokens.fontSm,
      color: p.textPrimary,
    );
    final soft = AbTokens.sansStyle(
      fontSize: AbTokens.fontSm,
      color: p.textSecondary,
    );
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AbTokens.space16,
        vertical: AbTokens.space12,
      ),
      decoration: BoxDecoration(
        color: p.bgSurface,
        border: Border.all(color: p.borderDefault),
        borderRadius: AbTokens.borderRadius8,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: AbTokens.space8,
        children: [
          Row(
            spacing: AbTokens.space12,
            children: [
              Text(
                'Next 24 hours',
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontMd,
                  fontWeight: FontWeight.w600,
                  color: p.textPrimary,
                ),
              ),
              Expanded(
                child: Text.rich(
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  TextSpan(
                    style: soft,
                    children: [
                      TextSpan(
                        text: '${summary.runs}${summary.capped ? '+' : ''}',
                        style: AbTokens.monoStyle(
                          fontSize: AbTokens.fontSm,
                          color: p.textPrimary,
                        ),
                      ),
                      const TextSpan(text: ' runs'),
                      if (next != null) ...[
                        const TextSpan(text: ' · next '),
                        TextSpan(text: next.schedule.name, style: strong),
                        const TextSpan(text: ' '),
                        TextSpan(
                          text: schedulerRelative(next.dots.first, now),
                          style: AbTokens.monoStyle(
                            fontSize: AbTokens.fontSm,
                            color: p.textPrimary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              Text('Times in $viewerZone', style: soft),
            ],
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              final width =
                  (constraints.maxWidth - _labelWidth - AbTokens.space12).clamp(
                    0.0,
                    double.infinity,
                  );
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(
                      left: _labelWidth + AbTokens.space12,
                    ),
                    child: SizedBox(width: width, child: axis(width)),
                  ),
                  for (final l in built.lanes) lane(l, width),
                  if (built.more > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: AbTokens.space4),
                      child: Text('+${built.more} more', style: soft),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
