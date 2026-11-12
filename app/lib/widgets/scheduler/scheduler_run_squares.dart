import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../../models/scheduler.dart';
import 'scheduler_format.dart';
import 'scheduler_status_glyph.dart';

Color schedulerToneColor(BuildContext context, SchedulerRunTone tone) {
  final t = CarbonTheme.of(context);
  return tone == SchedulerRunTone.muted
      ? t.borderStrong(CarbonLayer.of(context))
      : schedulerCarbonToneColor(t, tone);
}

/// Outcome of each recent run, oldest first. A missed run is hollow because
/// nothing ran, which keeps it distinct from a skipped one at a glance.
class SchedulerRunSquares extends StatelessWidget {
  const SchedulerRunSquares({super.key, required this.runs});
  final List<ScheduleRun> runs;

  static const _side = 9.0;

  /// Width of the full ten-run history (schedulerRecentRuns' default), for a
  /// column that should never drop a square.
  static const fullWidth = 10 * _side + 9 * CarbonSpacing.spacing02;

  @override
  Widget build(BuildContext context) {
    final t = CarbonTheme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // The table cell can be narrower than the full history; the newest
        // runs are the ones worth keeping.
        const pitch = _side + CarbonSpacing.spacing02;
        final fit = constraints.hasBoundedWidth
            ? ((constraints.maxWidth + CarbonSpacing.spacing02) / pitch)
                  .floor()
            : runs.length;
        final shown = fit >= runs.length
            ? runs
            : runs.sublist(runs.length - fit.clamp(0, runs.length));
        return Semantics(
          label: 'Last ${shown.length} runs',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: CarbonSpacing.spacing02,
            children: [
              for (final run in shown)
                CarbonTooltip(
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
                              ? Border.all(color: t.colors.iconSecondary)
                              : null,
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
    final t = CarbonTheme.of(context);
    final strong = t.borderStrong(CarbonLayer.of(context));
    return Semantics(
      label: 'Recent runs',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: CarbonSpacing.spacing01,
        children: [
          for (final run in runs)
            Container(
              width: _width,
              height: _height,
              color: switch (schedulerRunTone(run.status, trigger: run.trigger)) {
                SchedulerRunTone.muted || SchedulerRunTone.warning => strong,
                final tone => schedulerCarbonToneColor(t, tone),
              },
            ),
        ],
      ),
    );
  }
}
