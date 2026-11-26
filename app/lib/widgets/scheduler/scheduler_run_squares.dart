import 'package:flutter/widgets.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_tooltip.dart';
import '../../models/scheduler.dart';
import 'scheduler_format.dart';

Color schedulerToneColor(BuildContext context, SchedulerRunTone tone) {
  final p = context.antgrid;
  return switch (tone) {
    SchedulerRunTone.active => p.accent,
    SchedulerRunTone.attention || SchedulerRunTone.warning => p.warning,
    SchedulerRunTone.success => p.success,
    SchedulerRunTone.error => p.error,
    SchedulerRunTone.muted => p.statusIdle,
  };
}

/// Outcome of each recent run, oldest first. A missed run is hollow because
/// nothing ran, which keeps it distinct from a skipped one at a glance.
class SchedulerRunSquares extends StatelessWidget {
  const SchedulerRunSquares({super.key, required this.runs});
  final List<ScheduleRun> runs;

  static const _side = 9.0;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return LayoutBuilder(
      builder: (context, constraints) {
        // The table cell can be narrower than the full history; the newest
        // runs are the ones worth keeping.
        const pitch = _side + AbTokens.space4;
        final fit = constraints.hasBoundedWidth
            ? ((constraints.maxWidth + AbTokens.space4) / pitch).floor()
            : runs.length;
        final shown = fit >= runs.length
            ? runs
            : runs.sublist(runs.length - fit.clamp(0, runs.length));
        return Semantics(
          label: 'Last ${shown.length} runs',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: AbTokens.space4,
            children: [
              for (final run in shown)
                AbTooltip(
                  message: schedulerRunStatusWord(
                    run.status,
                    trigger: run.trigger,
                  ),
                  child: Builder(
                    builder: (context) {
                      final tone = schedulerRunTone(
                        run.status,
                        trigger: run.trigger,
                      );
                      final hollow = tone == SchedulerRunTone.warning;
                      return Container(
                        width: _side,
                        height: _side,
                        decoration: BoxDecoration(
                          color: hollow
                              ? null
                              : schedulerToneColor(context, tone),
                          border: hollow
                              ? Border.all(color: p.textMuted)
                              : null,
                          borderRadius: BorderRadius.circular(AbTokens.radius),
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Phone-row variant: tall slim bars so the history reads at arm's length.
class SchedulerMiniBars extends StatelessWidget {
  const SchedulerMiniBars({super.key, required this.runs});
  final List<ScheduleRun> runs;

  static const _width = 6.0;
  static const _height = 14.0;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return Semantics(
      label: 'Recent runs',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: AbTokens.space2,
        children: [
          for (final run in runs)
            Container(
              width: _width,
              height: _height,
              decoration: BoxDecoration(
                color: switch (schedulerRunTone(
                  run.status,
                  trigger: run.trigger,
                )) {
                  SchedulerRunTone.muted ||
                  SchedulerRunTone.warning => p.borderStrong,
                  final tone => schedulerToneColor(context, tone),
                },
                borderRadius: BorderRadius.circular(AbTokens.radius),
              ),
            ),
        ],
      ),
    );
  }
}
