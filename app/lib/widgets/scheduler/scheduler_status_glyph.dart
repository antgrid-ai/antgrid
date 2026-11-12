import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../../models/scheduler.dart';
import 'scheduler_format.dart';

/// The Carbon support colour a run tone is drawn in.
Color schedulerCarbonToneColor(CarbonThemeData t, SchedulerRunTone tone) =>
    switch (tone) {
      SchedulerRunTone.active => t.colors.supportInfo,
      SchedulerRunTone.attention ||
      SchedulerRunTone.warning => t.colors.supportWarning,
      SchedulerRunTone.success => t.colors.supportSuccess,
      SchedulerRunTone.error => t.colors.supportError,
      SchedulerRunTone.muted => t.colors.iconSecondary,
    };

/// Text colour for a run waiting on a person. Support yellow reads well on
/// the dark themes but fails text contrast on White and Gray 10 (about
/// 1.6:1), so a light theme falls back to primary text and leaves the warning
/// glyph beside it to carry the colour.
Color schedulerAttentionTextColor(CarbonThemeData t) =>
    t.brightness == Brightness.dark
    ? t.colors.supportWarning
    : t.colors.textPrimary;

/// Carbon icon-indicator status for a run outcome.
CarbonIconIndicatorKind schedulerRunIndicator(String status, {String? trigger}) {
  // A missed record never ran, the same as a skipped one.
  if (trigger == 'missed') return CarbonIconIndicatorKind.notStarted;
  return switch (status) {
    'preparing' || 'running' => CarbonIconIndicatorKind.inProgress,
    'needs-input' => CarbonIconIndicatorKind.cautionMinor,
    'completed' => CarbonIconIndicatorKind.succeeded,
    'failed' => CarbonIconIndicatorKind.failed,
    'interrupted' => CarbonIconIndicatorKind.incomplete,
    'skipped' => CarbonIconIndicatorKind.notStarted,
    _ => CarbonIconIndicatorKind.unknown,
  };
}

/// The state glyph beside a schedule or run: Carbon's icon indicator without
/// its visible label, so every state is the same size and shape family.
///
/// The status word shows as a tooltip. Without a [semanticLabel] the glyph is
/// decorative and belongs beside text that names the state.
class SchedulerStatusGlyph extends StatelessWidget {
  /// A run outcome.
  SchedulerStatusGlyph.run(
    String status, {
    super.key,
    String? trigger,
    this.semanticLabel,
  }) : _kind = schedulerRunIndicator(status, trigger: trigger),
       _word = schedulerRunStatusWord(status, trigger: trigger);

  /// A schedule row: [active] is its in-flight run, [resting] a paused or
  /// finished schedule, which outranks any run.
  SchedulerStatusGlyph.schedule({
    super.key,
    required ScheduleRun? active,
    required bool resting,
    this.semanticLabel,
  }) : _kind = resting
           ? CarbonIconIndicatorKind.notStarted
           : switch (active?.status) {
               'needs-input' => CarbonIconIndicatorKind.cautionMinor,
               'running' || 'preparing' => CarbonIconIndicatorKind.inProgress,
               _ => CarbonIconIndicatorKind.pending,
             },
       _word = resting
           ? 'Not active'
           : switch (active?.status) {
               'needs-input' => 'Needs input',
               'running' || 'preparing' => 'Running',
               _ => 'Scheduled',
             };

  /// The largest side a glyph takes: 20 under touch density, 16 compact.
  static const double extent = 20;

  final CarbonIconIndicatorKind _kind;
  final String _word;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final label = semanticLabel;
    final glyph = CarbonIconIndicator(
      kind: _kind,
      label: label ?? _word,
      compact: true,
    );
    return label == null ? ExcludeSemantics(child: glyph) : glyph;
  }
}
