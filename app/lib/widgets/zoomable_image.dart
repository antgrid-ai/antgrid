import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../design/ab_tokens.dart';

/// Pinch, pan, double-tap and wheel zoom over [child], which is laid out at
/// the viewport's size and scaled inside it.
///
/// Not an [InteractiveViewer]: its scale recognizer waits for the pan slop
/// before claiming a pointer, while the phone's PageView claims a horizontal
/// drag at the smaller touch slop — so the first finger of a pinch usually
/// moved the page instead. [_ZoomGestureRecognizer] claims instead the moment
/// a second finger lands, and while zoomed as soon as one moves at all; at fit
/// size a single finger is left to whatever is behind the image.
class ZoomableImage extends StatefulWidget {
  const ZoomableImage({super.key, required this.child});

  final Widget child;

  /// Where a double-tap lands: enough to read a screenshot's text.
  static const double doubleTapScale = 2.5;
  static const double maxScale = 8;

  @override
  State<ZoomableImage> createState() => ZoomableImageState();
}

class ZoomableImageState extends State<ZoomableImage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation;
  Matrix4Tween? _tween;
  Matrix4 _matrix = Matrix4.identity();
  Size _viewport = Size.zero;

  Matrix4? _gestureStartMatrix;
  Offset _gestureStartFocal = Offset.zero;
  Offset? _doubleTapAt;

  double get scale => _matrix.getMaxScaleOnAxis();
  bool get isZoomed => scale > 1.01;

  @override
  void initState() {
    super.initState();
    _animation = AnimationController(
      vsync: this,
      duration: AbTokens.motionDefault,
    )..addListener(_stepAnimation);
  }

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  void _stepAnimation() {
    final tween = _tween;
    if (tween == null) return;
    setState(
      () =>
          _matrix = tween.transform(Curves.easeOut.transform(_animation.value)),
    );
  }

  void _animateTo(Matrix4 target) {
    _tween = Matrix4Tween(begin: _matrix.clone(), end: target);
    _animation.forward(from: 0);
  }

  /// [scale] about the content point currently shown at [anchor], with the
  /// content kept covering the viewport so it never drifts off one edge.
  Matrix4 _zoomed({
    required Matrix4 from,
    required Offset anchor,
    required Offset target,
    required double scale,
  }) {
    final s = scale.clamp(1.0, ZoomableImage.maxScale);
    final fromScale = from.getMaxScaleOnAxis();
    final fromOffset = Offset(from.storage[12], from.storage[13]);
    final content = (anchor - fromOffset) / fromScale;
    var offset = target - content * s;
    offset = Offset(
      offset.dx.clamp(_viewport.width * (1 - s), 0.0),
      offset.dy.clamp(_viewport.height * (1 - s), 0.0),
    );
    return Matrix4.identity()
      ..translateByDouble(offset.dx, offset.dy, 0, 1)
      ..scaleByDouble(s, s, 1, 1);
  }

  /// Zooms in about [at], or fits back when already zoomed.
  void toggleZoom([Offset? at]) {
    if (isZoomed) {
      _animateTo(Matrix4.identity());
      return;
    }
    final focal = at ?? _viewport.center(Offset.zero);
    _animateTo(
      _zoomed(
        from: _matrix,
        anchor: focal,
        target: focal,
        scale: ZoomableImage.doubleTapScale,
      ),
    );
  }

  void _onScaleStart(ScaleStartDetails d) {
    _animation.stop();
    _gestureStartMatrix = _matrix.clone();
    _gestureStartFocal = d.localFocalPoint;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    final start = _gestureStartMatrix;
    if (start == null) return;
    setState(
      () => _matrix = _zoomed(
        from: start,
        anchor: _gestureStartFocal,
        target: d.localFocalPoint,
        scale: start.getMaxScaleOnAxis() * d.scale,
      ),
    );
  }

  void _onScaleEnd(ScaleEndDetails _) => _gestureStartMatrix = null;

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    // Claimed through the resolver so a scrollable around the image does not
    // also scroll on the same wheel tick.
    GestureBinding.instance.pointerSignalResolver.register(event, (e) {
      final dy = (e as PointerScrollEvent).scrollDelta.dy;
      if (dy == 0) return;
      _animation.stop();
      setState(
        () => _matrix = _zoomed(
          from: _matrix,
          anchor: e.localPosition,
          target: e.localPosition,
          scale: scale * math.exp(-dy / 300),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewport = constraints.biggest;
        return Listener(
          onPointerSignal: _onPointerSignal,
          child: RawGestureDetector(
            behavior: HitTestBehavior.opaque,
            gestures: {
              _ZoomGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<_ZoomGestureRecognizer>(
                    () => _ZoomGestureRecognizer(isZoomed: () => isZoomed),
                    (r) => r
                      ..onStart = _onScaleStart
                      ..onUpdate = _onScaleUpdate
                      ..onEnd = _onScaleEnd,
                  ),
              DoubleTapGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<
                    DoubleTapGestureRecognizer
                  >(
                    DoubleTapGestureRecognizer.new,
                    (r) => r
                      ..onDoubleTapDown = (d) {
                        _doubleTapAt = d.localPosition;
                      }
                      ..onDoubleTap = () => toggleZoom(_doubleTapAt),
                  ),
            },
            child: ClipRect(
              child: Transform(
                transform: _matrix,
                child: SizedBox.fromSize(size: _viewport, child: widget.child),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A [ScaleGestureRecognizer] that wins the arena early instead of at the pan
/// slop: on a second pointer (a pinch has started, whichever way the first
/// finger drifted), or while zoomed on the first sign of movement (so the drag
/// pans the image, yet a tap stays a tap for the double-tap recognizer). At
/// fit size one finger competes normally and loses to a page swipe.
class _ZoomGestureRecognizer extends ScaleGestureRecognizer {
  _ZoomGestureRecognizer({required this.isZoomed});

  final bool Function() isZoomed;
  final Map<int, Offset> _downAt = {};

  /// Under any touch slop a page or list would accept at, and above a
  /// resting finger's jitter.
  static const double _zoomedClaimDistance = 2;

  void _claimAll() {
    for (final pointer in _downAt.keys.toList()) {
      resolvePointer(pointer, GestureDisposition.accepted);
    }
  }

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    _downAt[event.pointer] = event.position;
    if (_downAt.length >= 2) _claimAll();
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent && isZoomed()) {
      final start = _downAt[event.pointer];
      if (start != null &&
          (event.position - start).distance > _zoomedClaimDistance) {
        _claimAll();
      }
    }
    super.handleEvent(event);
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      _downAt.remove(event.pointer);
    }
  }

  @override
  void rejectGesture(int pointer) {
    _downAt.remove(pointer);
    super.rejectGesture(pointer);
  }

  @override
  void dispose() {
    _downAt.clear();
    super.dispose();
  }

  @override
  String get debugDescription => 'zoom';
}
