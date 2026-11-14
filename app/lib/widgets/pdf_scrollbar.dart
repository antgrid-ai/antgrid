import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:pdfrx/pdfrx.dart';


/// Scrollbar for a [PdfViewer], vertical or horizontal.
///
/// The document follows the thumb while it is dragged. Needs pdfrx >= 2.6.6,
/// where a fast scroll no longer leaves canceled page previews blank.
///
/// The horizontal bar only exists while the page is zoomed wider than the view.
class PdfScrollbar extends StatefulWidget {
  final PdfViewerController controller;
  final Axis axis;

  const PdfScrollbar({
    super.key,
    required this.controller,
    this.axis = Axis.vertical,
  });

  @override
  State<PdfScrollbar> createState() => _PdfScrollbarState();
}

class _PdfScrollbarState extends State<PdfScrollbar> {
  static const _trackWidth = CarbonSpacing.spacing06;
  static const _thumbWidth = CarbonSpacing.spacing03;
  static const _minThumbLength = CarbonSpacing.spacing09;

  /// Thumb position in [0, 1] while a drag is in flight; null otherwise, when
  /// the thumb follows the document.
  double? _dragFraction;

  /// Pointer offset inside the thumb at drag start, so the thumb does not snap
  /// its leading edge to the pointer.
  double _grabOffset = 0;

  PdfViewerController get _c => widget.controller;
  bool get _vertical => widget.axis == Axis.vertical;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        if (!_c.isReady) return const SizedBox.shrink();
        final docExtent = _vertical
            ? _c.documentSize.height
            : _c.documentSize.width;
        final viewExtent = _vertical
            ? _c.visibleRect.height
            : _c.visibleRect.width;
        final scrollRange = docExtent - viewExtent;
        // Rounding noise at fit zoom must not conjure a horizontal bar.
        if (scrollRange <= 1) return const SizedBox.shrink();
        return Positioned(
          top: _vertical ? 0 : null,
          bottom: 0,
          left: _vertical ? null : 0,
          // Leave the corner to the vertical bar when both are showing.
          right: _vertical ? 0 : _trackWidth,
          width: _vertical ? _trackWidth : null,
          height: _vertical ? null : _trackWidth,
          child: LayoutBuilder(
            builder: (context, box) => _buildTrack(
              context,
              _vertical ? box.maxHeight : box.maxWidth,
              docExtent,
              scrollRange,
            ),
          ),
        );
      },
    );
  }

  Widget _buildTrack(
    BuildContext context,
    double trackLength,
    double docExtent,
    double scrollRange,
  ) {
    final c = CarbonTheme.of(context).colors;
    final viewExtent = docExtent - scrollRange;
    final thumbLength = (trackLength * viewExtent / docExtent).clamp(
      _minThumbLength,
      trackLength,
    );
    final travel = trackLength - thumbLength;
    final visibleStart = _vertical ? _c.visibleRect.top : _c.visibleRect.left;
    final liveFraction = (visibleStart / scrollRange).clamp(0.0, 1.0);
    final fraction = _dragFraction ?? liveFraction;
    final thumbStart = fraction * travel;
    final dragging = _dragFraction != null;

    double fractionAt(double pointer) =>
        travel <= 0 ? 0 : ((pointer - _grabOffset) / travel).clamp(0.0, 1.0);
    double along(Offset p) => _vertical ? p.dy : p.dx;

    void moveTo(double f) {
      setState(() => _dragFraction = f);
      _apply(f, scrollRange);
    }

    void begin(Offset local) {
      final p = along(local);
      final onThumb = p >= thumbStart && p <= thumbStart + thumbLength;
      // A grab off the thumb recentres it on the pointer, as a track click.
      _grabOffset = onThumb ? p - thumbStart : thumbLength / 2;
      moveTo(fractionAt(p));
    }

    void update(Offset local) => moveTo(fractionAt(along(local)));

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: _vertical ? (d) => begin(d.localPosition) : null,
      onVerticalDragUpdate: _vertical ? (d) => update(d.localPosition) : null,
      onVerticalDragEnd: _vertical ? (_) => _cancel() : null,
      onVerticalDragCancel: _vertical ? _cancel : null,
      onHorizontalDragStart: _vertical ? null : (d) => begin(d.localPosition),
      onHorizontalDragUpdate: _vertical ? null : (d) => update(d.localPosition),
      onHorizontalDragEnd: _vertical ? null : (_) => _cancel(),
      onHorizontalDragCancel: _vertical ? null : _cancel,
      onTapUp: (d) {
        _grabOffset = thumbLength / 2;
        moveTo(fractionAt(along(d.localPosition)));
        _cancel();
      },
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            top: _vertical ? thumbStart : null,
            bottom: _vertical ? null : CarbonSpacing.spacing01,
            left: _vertical ? null : thumbStart,
            right: _vertical ? CarbonSpacing.spacing01 : null,
            width: _vertical ? _thumbWidth : thumbLength,
            height: _vertical ? thumbLength : _thumbWidth,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: dragging ? c.iconPrimary : c.iconSecondary,
                // Readable over the dark backdrop and over a white page alike.
                border: Border.all(color: c.background),
              ),
            ),
          ),
          if (dragging && _vertical)
            Positioned(
              top: thumbStart + thumbLength / 2 - CarbonSpacing.spacing04,
              right: _trackWidth + CarbonSpacing.spacing03,
              child: _PageBubble(
                label: '${_pageAt(fraction, scrollRange)} / ${_c.pages.length}',
              ),
            ),
        ],
      ),
    );
  }

  /// The page under the middle of the viewport once the document sits at
  /// [fraction] of its scroll range.
  int _pageAt(double fraction, double scrollRange) {
    final layouts = _c.layout.pageLayouts;
    final probe = fraction * scrollRange + _c.visibleRect.height / 2;
    for (var i = 0; i < layouts.length; i++) {
      if (probe < layouts[i].bottom) return i + 1;
    }
    return layouts.length;
  }

  void _cancel() => setState(() => _dragFraction = null);

  void _apply(double fraction, double scrollRange) {
    final m = _c.value.clone();
    // Same unit as the range: pdfrx applies the zoom outside this translation,
    // so scaling here as well overshoots by the zoom factor.
    if (_vertical) {
      m.y = -(fraction * scrollRange);
    } else {
      m.x = -(fraction * scrollRange);
    }
    _c.value = m;
  }
}

class _PageBubble extends StatelessWidget {
  final String label;

  const _PageBubble({required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final c = theme.colors;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: CarbonSpacing.spacing03,
        vertical: CarbonSpacing.spacing02,
      ),
      decoration: BoxDecoration(
        color: c.layer01,
        border: Border.all(color: c.borderSubtle01),
      ),
      child: Text(
        label,
        style: theme.typography.code.copyWith(color: c.textPrimary),
      ),
    );
  }
}
