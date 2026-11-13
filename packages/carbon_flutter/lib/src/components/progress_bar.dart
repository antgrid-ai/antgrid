import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

import '../foundations/icons.dart';
import '../foundations/localizations.dart';
import '../foundations/theme.dart';
import '../foundations/tokens.dart';

/// Where the work behind a [CarbonProgressBar] stands.
enum CarbonProgressBarStatus {
  /// Work is in progress; the bar shows [CarbonProgressBar.value].
  active,

  /// The work completed: a full success-colored bar and a check icon.
  finished,

  /// The work failed: a full error-colored bar, an error icon and error
  /// helper text.
  error,
}

/// The two heights Carbon defines for a progress bar.
enum CarbonProgressBarSize {
  /// 8px track, Carbon's default.
  big(8),

  /// 4px track.
  small(4);

  const CarbonProgressBarSize(this.trackHeight);

  final double trackHeight;
}

/// A horizontal bar showing how far a task has got.
///
/// [value] is a fraction from 0 to 1; null means the amount is unknown and the
/// bar shows an indeterminate band. A [CarbonProgressBarStatus.finished] or
/// [CarbonProgressBarStatus.error] status fills the bar regardless of [value],
/// as Carbon does.
///
/// The indeterminate band sweeps across the track every 1400ms. It stops under
/// reduced motion, when a surrounding `TickerMode` is off, or when
/// [animateIndeterminate] is false; it then rests as a static band centered on
/// the track (deviation CPB-static).
///
/// Assistive technology hears the label with the percentage, or with the
/// localized "Loading", "Success" or "Error" when there is none to give.
/// Progress is never re-announced per frame.
class CarbonProgressBar extends StatefulWidget {
  const CarbonProgressBar({
    super.key,
    this.value,
    this.size = CarbonProgressBarSize.big,
    this.status = CarbonProgressBarStatus.active,
    this.animateIndeterminate = true,
    this.label,
    this.helperText,
    this.hideLabel = false,
  });

  /// Progress from 0 to 1, clamped. Null is indeterminate.
  final double? value;

  final CarbonProgressBarSize size;

  final CarbonProgressBarStatus status;

  /// Whether an indeterminate bar animates. False paints the resting band
  /// instead, for places where a perpetual animation is unwelcome.
  final bool animateIndeterminate;

  /// Text above the track, e.g. "Uploading". Also the accessible name.
  final String? label;

  /// Secondary text under the track, e.g. "5 of 12 files".
  final String? helperText;

  /// Keeps [label] for assistive technology but does not paint it (or the
  /// status icon beside it).
  final bool hideLabel;

  bool get _indeterminate =>
      status == CarbonProgressBarStatus.active && value == null;

  @override
  State<CarbonProgressBar> createState() => _CarbonProgressBarState();
}

class _CarbonProgressBarState extends State<CarbonProgressBar>
    with SingleTickerProviderStateMixin {
  static const Duration _period = Duration(milliseconds: 1400);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _period,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncTicking();
  }

  @override
  void didUpdateWidget(CarbonProgressBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTicking();
  }

  // Whether the band is sweeping. Tracked apart from the controller because a
  // muted ticker leaves the controller "animating" while painting nothing.
  bool _sweeping = false;

  void _syncTicking() {
    final run =
        widget._indeterminate &&
        widget.animateIndeterminate &&
        !CarbonMotion.reduced(context) &&
        TickerMode.valuesOf(context).enabled;
    _sweeping = run;
    if (run) {
      if (!_controller.isAnimating) _controller.repeat();
    } else if (_controller.isAnimating || _controller.value != 0) {
      _controller
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final colors = theme.colors;
    final loc = CarbonLocalizations.of(context);
    final status = widget.status;
    final label = widget.label;
    final helper = widget.helperText;

    final barColor = switch (status) {
      CarbonProgressBarStatus.active => colors.interactive,
      CarbonProgressBarStatus.finished => colors.supportSuccess,
      CarbonProgressBarStatus.error => colors.supportError,
    };
    final fraction = switch (status) {
      CarbonProgressBarStatus.active => (widget.value ?? 0).clamp(0.0, 1.0),
      _ => 1.0,
    };
    final animated = _sweeping;

    final track = RepaintBoundary(
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(end: fraction),
        duration: CarbonMotion.resolve(context, CarbonMotion.fast02),
        curve: CarbonMotion.standard,
        builder: (context, shown, _) => CustomPaint(
          size: Size(double.infinity, widget.size.trackHeight),
          painter: _TrackPainter(
            progress: _controller,
            track: theme.borderSubtle(CarbonLayer.of(context)),
            bar: barColor,
            fraction: shown,
            indeterminate: widget._indeterminate,
            animated: animated,
            rtl: Directionality.of(context) == TextDirection.rtl,
          ),
        ),
      ),
    );

    final statusIcon = switch (status) {
      CarbonProgressBarStatus.active => null,
      CarbonProgressBarStatus.finished => CarbonIcons.checkmarkFilled,
      CarbonProgressBarStatus.error => CarbonIcons.errorFilled,
    };
    final showLabelRow =
        !widget.hideLabel && (label != null || statusIcon != null);

    final spoken = switch (status) {
      CarbonProgressBarStatus.finished => loc.success,
      CarbonProgressBarStatus.error => loc.error,
      CarbonProgressBarStatus.active =>
        widget.value == null ? loc.loading : '${(fraction * 100).round()}%',
    };

    // Flutter only accepts the progressBar role on a numeric percentage with
    // bounds; the other states carry their word as a plain value.
    final determinate =
        status == CarbonProgressBarStatus.active && widget.value != null;

    return Semantics(
      container: true,
      role: determinate ? SemanticsRole.progressBar : SemanticsRole.none,
      minValue: determinate ? '0' : null,
      maxValue: determinate ? '100' : null,
      label: label,
      value: spoken,
      hint: helper,
      child: ExcludeSemantics(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showLabelRow)
              Padding(
                padding: const EdgeInsetsDirectional.only(
                  bottom: CarbonSpacing.spacing03,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 48),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          label ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.typography.control.copyWith(
                            color: colors.textPrimary,
                          ),
                        ),
                      ),
                      if (statusIcon != null)
                        Padding(
                          padding: const EdgeInsetsDirectional.only(
                            start: CarbonSpacing.spacing05,
                          ),
                          child: CarbonIcon(
                            statusIcon,
                            size: 16,
                            color: barColor,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 48),
              child: track,
            ),
            if (helper != null)
              Padding(
                padding: const EdgeInsetsDirectional.only(
                  top: CarbonSpacing.spacing03,
                ),
                child: Text(
                  helper,
                  style: theme.typography.helper.copyWith(
                    color: status == CarbonProgressBarStatus.error
                        ? colors.textError
                        : colors.textSecondary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TrackPainter extends CustomPainter {
  _TrackPainter({
    required this.progress,
    required this.track,
    required this.bar,
    required this.fraction,
    required this.indeterminate,
    required this.animated,
    required this.rtl,
  }) : super(repaint: progress);

  final Animation<double> progress;
  final Color track;
  final Color bar;
  final double fraction;
  final bool indeterminate;
  final bool animated;
  final bool rtl;

  // The band is a quarter of the track and sweeps from just off the start
  // edge to just off the end edge in the first 80% of the cycle, then waits
  // off-screen (Carbon's `background-position-x` keyframes).
  static const double _band = 0.25;
  static const double _sweepEnd = 0.8;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    canvas.drawRect(Offset.zero & size, Paint()..color = track);

    double start;
    double end;
    if (indeterminate) {
      final double s;
      if (animated) {
        final p = (progress.value / _sweepEnd).clamp(0.0, 1.0);
        s = -_band + p * (1 + 0.05 + _band);
      } else {
        s = (1 - _band) / 2;
      }
      start = s * w;
      end = (s + _band) * w;
    } else {
      start = 0;
      end = fraction * w;
    }
    if (rtl) {
      final flipped = w - end;
      end = w - start;
      start = flipped;
    }
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.drawRect(Rect.fromLTRB(start, 0, end, size.height), Paint()..color = bar);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_TrackPainter old) =>
      old.progress != progress ||
      old.track != track ||
      old.bar != bar ||
      old.fraction != fraction ||
      old.indeterminate != indeterminate ||
      old.animated != animated ||
      old.rtl != rtl;
}
