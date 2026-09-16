import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Wraps a horizontally scrolling row with an edge fade on whichever side is
/// currently cut off, tracked from the [ScrollController]'s own metrics
/// rather than guessed from layout: a tab or chip clipped mid-glyph by the
/// viewport boundary reads as a broken header, where a faded edge reads as
/// "there's more, scroll for it".
class AbFadeScroll extends StatefulWidget {
  const AbFadeScroll({super.key, required this.children, this.reverse = false});

  final List<Widget> children;

  /// Mirrors [SingleChildScrollView.reverse] — set when the row should start
  /// scrolled to its trailing edge rather than its leading one.
  final bool reverse;

  @override
  State<AbFadeScroll> createState() => _AbFadeScrollState();
}

class _AbFadeScrollState extends State<AbFadeScroll> {
  final _controller = ScrollController();
  bool _fadeStart = false;
  bool _fadeEnd = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_updateFades);
    // Metrics don't exist until the first layout, and content that already
    // overflows on first frame (e.g. a `reverse: true` row, or a filter bar
    // that opens with chips already active) needs the fade before any scroll
    // event ever fires.
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateFades());
  }

  @override
  void didUpdateWidget(covariant AbFadeScroll oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The controller's own listener only fires on a scroll, so a rebuild that
    // adds/removes a child needs its own nudge — same post-frame reasoning as
    // initState's: this build's layout hasn't happened yet.
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateFades());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _updateFades() {
    if (!_controller.hasClients) return;
    final metrics = _controller.position;
    final fadeStart = widget.reverse
        ? metrics.extentAfter > 0
        : metrics.extentBefore > 0;
    final fadeEnd = widget.reverse
        ? metrics.extentBefore > 0
        : metrics.extentAfter > 0;
    if (fadeStart == _fadeStart && fadeEnd == _fadeEnd) return;
    setState(() {
      _fadeStart = fadeStart;
      _fadeEnd = fadeEnd;
    });
  }

  /// Whichever axis carries more of a two-dimensional delta. A mechanical
  /// wheel notch reports (near-)zero on the axis it doesn't scroll, so this
  /// is equivalent to picking the nonzero one there; a trackpad swipe rarely
  /// lands perfectly straight, so the dominant-axis pick is what keeps a
  /// vertical swipe from reading as noisy horizontal jitter.
  double _dominantAxis(Offset delta) =>
      delta.dx.abs() >= delta.dy.abs() ? delta.dx : delta.dy;

  /// Lets a plain mouse wheel drive this row the way a horizontal trackpad
  /// swipe already does. Every caller is a fixed-height toolbar/chip row with
  /// no nested vertical scrollable competing for the same wheel event, so
  /// unlike `diff_viewer.dart`'s `_onPointerSignal` (which only claims a
  /// dx-dominant event to leave its neighbouring vertical list alone) this
  /// takes a vertical delta too — otherwise a row cut off by its container's
  /// width has no reachable way to scroll it on desktop at all.
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (!_controller.hasClients) return;
    final delta = _dominantAxis(event.scrollDelta);
    if (delta == 0) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      final position = _controller.position;
      _controller.jumpTo(
        (position.pixels + delta).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
    });
  }

  /// A precision-touchpad two-finger scroll arrives as this, not as a wheel
  /// [PointerScrollEvent] — Windows/macOS trackpads report a pan/zoom stream,
  /// and `Scrollable` only ever binds its OWN axis's drag recognizer to it, so
  /// a vertical swipe over a horizontal-only row like this one has nothing
  /// that claims it without this handler.
  ///
  /// Sign is inverted from the wheel path on purpose: [PointerScrollEvent]
  /// deltas are wheel-notch convention (add to move the SAME way), where
  /// [PointerPanZoomUpdateEvent.panDelta] is drag convention — content follows
  /// the finger, i.e. subtract — the same negation `ScrollDragController`
  /// applies for an ordinary drag (`scroll_activity.dart`).
  void _onPointerPanZoomUpdate(PointerPanZoomUpdateEvent event) {
    if (!_controller.hasClients) return;
    final delta = _dominantAxis(event.panDelta);
    if (delta == 0) return;
    final position = _controller.position;
    _controller.jumpTo(
      (position.pixels - delta).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scrollable = Listener(
      onPointerSignal: _onPointerSignal,
      onPointerPanZoomUpdate: _onPointerPanZoomUpdate,
      // The ambient ScrollBehavior's `dragDevices` omits the mouse by
      // default (touch/stylus/trackpad only — Flutter reserves a plain
      // mouse-drag for text selection app-wide), so a click-and-drag swipe
      // across this row does nothing without this. Scoped to just this
      // Scrollable via a local override rather than widening every
      // scrollable in the app to mouse-drag, which would also change how
      // text selection feels everywhere else.
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(
          dragDevices: {
            ...ScrollConfiguration.of(context).dragDevices,
            PointerDeviceKind.mouse,
          },
        ),
        child: SingleChildScrollView(
          controller: _controller,
          scrollDirection: Axis.horizontal,
          reverse: widget.reverse,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: widget.children,
          ),
        ),
      ),
    );
    if (!_fadeStart && !_fadeEnd) return scrollable;
    // dstIn keeps the row's own pixels and colors — the fade is purely an
    // alpha mask, so it needs no knowledge of the panel's background color.
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (bounds) => LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [
          _fadeStart ? const Color(0x00000000) : const Color(0xFF000000),
          const Color(0xFF000000),
          const Color(0xFF000000),
          _fadeEnd ? const Color(0x00000000) : const Color(0xFF000000),
        ],
        stops: const [0.0, 0.3, 0.7, 1.0],
      ).createShader(bounds),
      child: scrollable,
    );
  }
}
