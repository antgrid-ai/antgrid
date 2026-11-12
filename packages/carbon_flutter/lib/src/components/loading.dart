import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../foundations/localizations.dart';
import '../foundations/theme.dart';
import '../foundations/tokens.dart';

/// Carbon's indeterminate spinner: a track ring with a sweeping arc.
///
/// This is the bare indicator that [CarbonLoading], buttons, inline loading and
/// field affordances share. It is decorative unless [semanticLabel] is given,
/// so the host component decides what is announced and when.
///
/// The animation uses the widget's own ticker, so a surrounding `TickerMode`
/// (an offstage tab, a hidden pane) mutes it. It does not tick when [active] is
/// false or when the platform asks for reduced motion; it then draws a fixed
/// arc that still reads as "working". Only the arc is repainted per frame.
class CarbonSpinner extends StatefulWidget {
  const CarbonSpinner({
    super.key,
    this.size = 16,
    this.color,
    this.trackColor,
    this.active = true,
    this.semanticLabel,
  });

  /// Diameter in logical pixels. Carbon uses 16 for inline use and 88 for a
  /// region or view.
  final double size;

  /// The arc color. Defaults to the `interactive` role.
  final Color? color;

  /// The ring behind the arc. Defaults to the current layer's accent for a
  /// small spinner and to none for a large one, as Carbon draws them.
  final Color? trackColor;

  /// Whether the spinner animates. An inactive spinner is static.
  final bool active;

  /// Names the spinner for assistive technology. Null keeps it decorative.
  final String? semanticLabel;

  @override
  State<CarbonSpinner> createState() => _CarbonSpinnerState();
}

class _CarbonSpinnerState extends State<CarbonSpinner>
    with SingleTickerProviderStateMixin {
  static const Duration _period = Duration(milliseconds: 1400);

  // Carbon draws the background ring only on the small indicator.
  static const double _smallTrackMax = 32;

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
  void didUpdateWidget(CarbonSpinner oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTicking();
  }

  void _syncTicking() {
    final run = widget.active && !CarbonMotion.reduced(context);
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
    final spinner = RepaintBoundary(
      child: CustomPaint(
        size: Size.square(widget.size),
        painter: _SpinnerPainter(
          progress: _controller,
          color: widget.color ?? theme.colors.interactive,
          trackColor:
              widget.trackColor ??
              (widget.size <= _smallTrackMax
                  ? theme.layerAccent(CarbonLayer.of(context))
                  : const Color(0x00000000)),
          strokeWidth: math.max(2, widget.size * 0.1),
        ),
      ),
    );
    final label = widget.semanticLabel;
    if (label == null) return ExcludeSemantics(child: spinner);
    return Semantics(label: label, child: spinner);
  }
}

class _SpinnerPainter extends CustomPainter {
  _SpinnerPainter({
    required this.progress,
    required this.color,
    required this.trackColor,
    required this.strokeWidth,
  }) : super(repaint: progress);

  final Animation<double> progress;
  final Color color;
  final Color trackColor;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(strokeWidth / 2);
    if (rect.width <= 0 || rect.height <= 0) return;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.butt;
    canvas.drawArc(rect, 0, math.pi * 2, false, paint..color = trackColor);

    final t = progress.value;
    // The arc breathes between a short and a long sweep while it rotates, so
    // direction of travel stays legible; at rest (t == 0) it is a fixed
    // three-quarter arc.
    final breathe = t == 0 ? 0.75 : 0.5 + 0.25 * math.cos(t * math.pi * 2 * 2);
    final start = -math.pi / 2 + t * math.pi * 2;
    canvas.drawArc(rect, start, math.pi * 2 * breathe, false, paint..color = color);
  }

  @override
  bool shouldRepaint(_SpinnerPainter old) =>
      old.progress != progress ||
      old.color != color ||
      old.trackColor != trackColor ||
      old.strokeWidth != strokeWidth;
}

/// The two indicator sizes Carbon defines for [CarbonLoading].
enum CarbonLoadingSize {
  /// 16px, for a compact region such as a card or a control.
  small(16),

  /// 88px, for a whole view or a large region.
  large(88);

  const CarbonLoadingSize(this.diameter);

  final double diameter;
}

/// Indeterminate loading for a region or view, with an optional status message.
///
/// The widget announces a busy state once through a live region (the message,
/// or the localized "Loading") rather than per frame. It never blocks anything
/// by itself: with [overlay] false it is plain content, and with [overlay] true
/// it fills the box its parent gives it and scrims only that box, so the host
/// decides which region is unavailable. See [CarbonLoadingOverlay] for the
/// common "cover this child while loading" composition.
class CarbonLoading extends StatelessWidget {
  const CarbonLoading({
    super.key,
    this.size = CarbonLoadingSize.large,
    this.message,
    this.semanticLabel,
    this.overlay = false,
    this.active = true,
  });

  final CarbonLoadingSize size;

  /// Visible status text under the spinner.
  final String? message;

  /// Overrides the announced text; defaults to [message], then the localized
  /// "Loading".
  final String? semanticLabel;

  /// Scrims and centers over the parent's full box, and absorbs pointer input
  /// inside that box. Requires bounded constraints.
  final bool overlay;

  /// False draws a static spinner, e.g. while a host pauses the work.
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final text = message;
    final announce =
        semanticLabel ?? text ?? CarbonLocalizations.of(context).loading;
    Widget content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CarbonSpinner(size: size.diameter, active: active),
        if (text != null) ...[
          const SizedBox(height: CarbonSpacing.spacing04),
          ExcludeSemantics(
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: theme.typography.body.copyWith(
                color: theme.colors.textSecondary,
              ),
            ),
          ),
        ],
      ],
    );
    content = Semantics(
      container: true,
      liveRegion: true,
      label: announce,
      child: content,
    );
    if (!overlay) return content;
    return AbsorbPointer(
      child: ColoredBox(
        color: theme.colors.overlay,
        child: SizedBox.expand(child: Center(child: content)),
      ),
    );
  }
}

/// Covers [child] with a [CarbonLoading] scrim while [loading] is true.
///
/// Only this widget's own box is covered: siblings and ancestors stay usable.
/// While loading, [child] is removed from pointer input, focus traversal and
/// the semantics tree, so neither the keyboard nor a screen reader can reach
/// controls the scrim hides. A control that held focus when loading began gets
/// it back when loading ends.
class CarbonLoadingOverlay extends StatefulWidget {
  const CarbonLoadingOverlay({
    super.key,
    required this.loading,
    required this.child,
    this.size = CarbonLoadingSize.large,
    this.message,
    this.semanticLabel,
  });

  final bool loading;
  final Widget child;
  final CarbonLoadingSize size;
  final String? message;
  final String? semanticLabel;

  @override
  State<CarbonLoadingOverlay> createState() => _CarbonLoadingOverlayState();
}

class _CarbonLoadingOverlayState extends State<CarbonLoadingOverlay> {
  // Observes whether focus is inside the child; it never takes focus itself.
  final FocusNode _inside = FocusNode(
    debugLabel: 'CarbonLoadingOverlay',
    skipTraversal: true,
    canRequestFocus: false,
  );
  FocusNode? _restore;

  @override
  void dispose() {
    _inside.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(CarbonLoadingOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.loading == oldWidget.loading) return;
    if (widget.loading) {
      // ExcludeFocus drops focus during this build, so remember it first.
      final focused = FocusManager.instance.primaryFocus;
      _restore = focused != null && _inside.hasFocus ? focused : null;
    } else {
      final node = _restore;
      _restore = null;
      if (node == null) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || widget.loading) return;
        if (node.context != null && node.canRequestFocus) node.requestFocus();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final loading = widget.loading;
    return Stack(
      children: [
        ExcludeSemantics(
          excluding: loading,
          child: ExcludeFocus(
            excluding: loading,
            child: Focus(
              focusNode: _inside,
              includeSemantics: false,
              child: widget.child,
            ),
          ),
        ),
        if (loading)
          Positioned.fill(
            child: CarbonLoading(
              overlay: true,
              size: widget.size,
              message: widget.message,
              semanticLabel: widget.semanticLabel,
            ),
          ),
      ],
    );
  }
}
