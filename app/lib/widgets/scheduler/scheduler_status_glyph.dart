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

enum _Shape { attention, error, filled, hollow }

/// The state glyph beside a schedule or run: a Carbon status icon where the
/// state needs a person, a plain dot everywhere else.
///
/// Every glyph shares one 16px box so the text beside it never shifts as a row
/// changes state. Running is a static dot: a looping animation would keep
/// widget tests from ever settling. Without a [semanticLabel] the glyph is
/// decorative and belongs beside text that names the state.
class SchedulerStatusGlyph extends StatelessWidget {
  /// A run outcome, coloured by its [tone].
  const SchedulerStatusGlyph.run(
    SchedulerRunTone tone, {
    super.key,
    this.semanticLabel,
  }) : _tone = tone,
       _resting = false;

  /// A schedule row: [active] is its in-flight run, [resting] a paused or
  /// finished schedule, which outranks any run.
  SchedulerStatusGlyph.schedule({
    super.key,
    required ScheduleRun? active,
    required bool resting,
    this.semanticLabel,
  }) : _tone = switch (active?.status) {
         'needs-input' => SchedulerRunTone.attention,
         'running' || 'preparing' => SchedulerRunTone.active,
         _ => SchedulerRunTone.muted,
       },
       _resting = resting;

  /// Side of the box every glyph occupies.
  static const double extent = 16;
  static const double _dot = 8;

  final SchedulerRunTone _tone;
  final bool _resting;
  final String? semanticLabel;

  _Shape get _shape {
    if (_resting) return _Shape.hollow;
    return switch (_tone) {
      SchedulerRunTone.attention => _Shape.attention,
      SchedulerRunTone.error => _Shape.error,
      SchedulerRunTone.warning => _Shape.hollow,
      _ => _Shape.filled,
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final shape = _shape;
    final Widget glyph;
    switch (shape) {
      case _Shape.attention:
        glyph = CarbonStatusIcon(
          CarbonStatusKind.warning,
          size: extent,
          semanticLabel: semanticLabel,
        );
      case _Shape.error:
        glyph = CarbonStatusIcon(
          CarbonStatusKind.error,
          size: extent,
          semanticLabel: semanticLabel,
        );
      case _Shape.filled || _Shape.hollow:
        final color = _resting
            ? theme.colors.iconDisabled
            : schedulerCarbonToneColor(theme, _tone);
        final dot = Center(
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: shape == _Shape.filled ? color : null,
              border: shape == _Shape.hollow
                  ? Border.all(color: color, width: 1.5)
                  : null,
            ),
            child: const SizedBox.square(dimension: _dot),
          ),
        );
        final label = semanticLabel;
        glyph = label == null
            ? ExcludeSemantics(child: dot)
            : Semantics(
                label: label,
                image: true,
                excludeSemantics: true,
                child: dot,
              );
    }
    return SizedBox.square(dimension: extent, child: Center(child: glyph));
  }
}
