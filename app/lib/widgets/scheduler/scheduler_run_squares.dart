import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../../models/scheduler.dart';
import 'scheduler_format.dart';
import 'scheduler_status_glyph.dart';

Color schedulerToneColor(BuildContext context, SchedulerRunTone tone) {
  final t = CarbonTheme.of(context);
  return tone == SchedulerRunTone.muted || tone == SchedulerRunTone.warning
      ? t.borderStrong(CarbonLayer.of(context))
      : schedulerCarbonToneColor(t, tone);
}

/// Outcome of each recent run, oldest first. A missed run is an outline in
/// the skipped grey, since nothing ran; the outline is one device pixel so it
/// carries no more ink than a fill and the squares read as one size.
class SchedulerRunSquares extends StatelessWidget {
  const SchedulerRunSquares({super.key, required this.runs});
  final List<ScheduleRun> runs;

  static const _side = 9.0;

  /// Width of the full ten-run history (schedulerRecentRuns' default), for a
  /// column that should never drop a square.
  static const fullWidth = 10 * _side + 9 * CarbonSpacing.spacing02;

  @override
  Widget build(BuildContext context) {
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
                  child: _Square(
                    side: _side,
                    color: schedulerToneColor(
                      context,
                      schedulerRunTone(run.status, trigger: run.trigger),
                    ),
                    hollow: run.trigger == 'missed',
                    devicePixelRatio:
                        MediaQuery.maybeDevicePixelRatioOf(context) ?? 1,
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

/// One history square, drawn on whole device pixels.
///
/// Table rows centre their content, so the strip often lands on a half pixel,
/// where an unsnapped square blurs its edges and reads smaller than its side.
class _Square extends LeafRenderObjectWidget {
  const _Square({
    required this.side,
    required this.color,
    required this.hollow,
    required this.devicePixelRatio,
  });

  final double side;
  final Color color;
  final bool hollow;
  final double devicePixelRatio;

  @override
  _RenderSquare createRenderObject(BuildContext context) =>
      _RenderSquare(side, color, hollow, devicePixelRatio);

  @override
  void updateRenderObject(BuildContext context, _RenderSquare renderObject) {
    renderObject
      ..side = side
      ..color = color
      ..hollow = hollow
      ..devicePixelRatio = devicePixelRatio;
  }
}

class _RenderSquare extends RenderBox {
  _RenderSquare(this._side, this._color, this._hollow, this._dpr);

  double _side;
  set side(double v) {
    if (v == _side) return;
    _side = v;
    markNeedsLayout();
  }

  Color _color;
  set color(Color v) {
    if (v == _color) return;
    _color = v;
    markNeedsPaint();
  }

  bool _hollow;
  set hollow(bool v) {
    if (v == _hollow) return;
    _hollow = v;
    markNeedsPaint();
  }

  double _dpr;
  set devicePixelRatio(double v) {
    if (v == _dpr) return;
    _dpr = v;
    markNeedsPaint();
  }

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      constraints.constrain(Size.square(_side));

  @override
  void paint(PaintingContext context, Offset offset) {
    // The half pixel comes from ancestors, so snap the screen position, not
    // the offset this box was handed.
    final global = localToGlobal(Offset.zero);
    double snap(double v) => (v * _dpr).roundToDouble() / _dpr;
    final origin =
        offset + Offset(snap(global.dx) - global.dx, snap(global.dy) - global.dy);
    final rect = origin & Size.square(snap(_side));
    final paint = Paint()..color = _color;
    if (!_hollow) {
      context.canvas.drawRect(rect, paint);
      return;
    }
    // Four bars on the pixel grid; a stroke would straddle a pixel edge and
    // blur to two.
    final w = 1 / _dpr;
    final inner = rect.height - 2 * w;
    context.canvas
      ..drawRect(Rect.fromLTWH(rect.left, rect.top, rect.width, w), paint)
      ..drawRect(Rect.fromLTWH(rect.left, rect.bottom - w, rect.width, w), paint)
      ..drawRect(Rect.fromLTWH(rect.left, rect.top + w, w, inner), paint)
      ..drawRect(Rect.fromLTWH(rect.right - w, rect.top + w, w, inner), paint);
  }
}
