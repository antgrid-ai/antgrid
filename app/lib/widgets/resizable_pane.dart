import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../design/ab_colors.dart';

/// A two-pane layout with a draggable divider between [left] and [right].
/// On drag, the split ratio updates smoothly. Double-tap the handle to
/// reset to 50/50.
class ResizablePane extends StatefulWidget {
  final Widget left;
  final Widget right;
  final double initialRatio;
  final double minRatio;
  final double maxRatio;
  final ValueChanged<double>? onRatioChanged;

  /// Pixel floors under [minRatio]/[maxRatio], for a [left]/[right] whose
  /// content has a real minimum functional width (a toolbar of fixed-size
  /// controls, say) rather than one that degrades gracefully at any ratio.
  /// A plain ratio can't express that: the same 0.2 that's generous on a wide
  /// monitor can under-shoot a toolbar's own minimum on a narrower one, which
  /// is silent here — nothing in this widget renders wrong, the squeeze just
  /// hands the pane less width than its content needs and IT overflows.
  /// Converted against [_available] each frame, so the floor stays a fixed
  /// pixel width as the window resizes rather than a fixed fraction of it.
  final double? minLeftWidth;
  final double? minRightWidth;

  const ResizablePane({
    super.key,
    required this.left,
    required this.right,
    this.initialRatio = 0.5,
    this.minRatio = 0.2,
    this.maxRatio = 0.8,
    this.minLeftWidth,
    this.minRightWidth,
    this.onRatioChanged,
  });

  @override
  State<ResizablePane> createState() => _ResizablePaneState();
}

const double _handleWidth = 4.0;

/// Denominator for the ratio→flex conversion. Flex is an int, so this sets the
/// split's resolution: 1/10000 of the pane, well under a physical pixel.
const int _flexResolution = 10000;

class _ResizablePaneState extends State<ResizablePane> {
  late double _ratio;
  bool _isDragging = false;

  @override
  void initState() {
    super.initState();
    _ratio = widget.initialRatio;
  }

  @override
  void didUpdateWidget(ResizablePane old) {
    super.didUpdateWidget(old);
    if (old.initialRatio != widget.initialRatio && !_isDragging) {
      _ratio = widget.initialRatio;
    }
  }

  /// Space either side of the handle as of the last layout — the denominator a
  /// drag delta is converted against. Measured off this State's own RenderBox
  /// (the Row below) rather than closed over from a builder's constraints,
  /// which is what lets [build] size the panes by flex instead of by pixels.
  double get _available {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return 0;
    return box.size.width - _handleWidth;
  }

  /// [widget.minRatio]/[widget.maxRatio], tightened against [widget.minLeftWidth]
  /// / [widget.minRightWidth] using the last-known [_available] width. Reads
  /// as "no pixel floor configured" (falling back to the plain ratio) both
  /// when the caller passed none and on the very first build, before any
  /// layout has reported a size — the ratio bound alone still applies there,
  /// and the pixel floor catches up one frame later, same as [_available]'s
  /// own doc explains for the drag path.
  (double min, double max) get _effectiveRatioBounds {
    final available = _available;
    var min = widget.minRatio;
    var max = widget.maxRatio;
    if (available > 0) {
      final minLeft = widget.minLeftWidth;
      if (minLeft != null) min = math.max(min, minLeft / available);
      final minRight = widget.minRightWidth;
      if (minRight != null) max = math.min(max, 1 - (minRight / available));
    }
    // A window too narrow to honor both floors at once — split evenly rather
    // than hand the clamp below an inverted (min > max) range, which throws.
    return min <= max ? (min, max) : (0.5, 0.5);
  }

  @override
  Widget build(BuildContext context) {
    // Flex weights, NOT a LayoutBuilder. Both panes carry GlobalKeys (see
    // `workspace_shell.dart`'s `_agentPanelKey`/`_contextPanelKey`), so showing
    // the context panel again reparents a LIVE subtree into this Row. A
    // LayoutBuilder inflates its child during layout, and an OverlayPortal
    // reactivated there re-attaches its overlay child to the root Overlay —
    // marking the theater dirty mid-layout, which throws "_RenderLayoutBuilder
    // was mutated in performLayout" and swaps this whole subtree for an
    // ErrorWidget: a blank, unusable workspace. The agent bar's
    // WorkspaceMenuButton is exactly such a portal, and it is open precisely
    // while the panel is hidden, so restoring the panel from the rail hit it
    // every time. Flex keeps the reparent in the build phase, where activating
    // an overlay child is legal.
    final (minRatio, maxRatio) = _effectiveRatioBounds;
    final leftFlex = (_ratio.clamp(minRatio, maxRatio) * _flexResolution)
        .round()
        .clamp(1, _flexResolution - 1);
    return Row(
      children: [
        Expanded(flex: leftFlex, child: widget.left),
        _DragHandle(
          width: _handleWidth,
          isDragging: _isDragging,
          onDragStart: () => setState(() => _isDragging = true),
          onDragEnd: () {
            setState(() => _isDragging = false);
            widget.onRatioChanged?.call(_ratio);
          },
          onDragUpdate: (dx) {
            final available = _available;
            if (available <= 0) return;
            final (minRatio, maxRatio) = _effectiveRatioBounds;
            setState(() {
              _ratio = ((_ratio * available + dx) / available).clamp(
                minRatio,
                maxRatio,
              );
            });
          },
          onDoubleTap: () {
            setState(() => _ratio = 0.5);
            widget.onRatioChanged?.call(0.5);
          },
        ),
        Expanded(flex: _flexResolution - leftFlex, child: widget.right),
      ],
    );
  }
}

class _DragHandle extends StatefulWidget {
  final double width;
  final bool isDragging;
  final VoidCallback onDragStart;
  final VoidCallback onDragEnd;
  final ValueChanged<double> onDragUpdate;
  final VoidCallback onDoubleTap;

  const _DragHandle({
    required this.width,
    required this.isDragging,
    required this.onDragStart,
    required this.onDragEnd,
    required this.onDragUpdate,
    required this.onDoubleTap,
  });

  @override
  State<_DragHandle> createState() => _DragHandleState();
}

class _DragHandleState extends State<_DragHandle> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final isActive = widget.isDragging || _isHovered;

    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) => widget.onDragStart(),
        onHorizontalDragEnd: (_) => widget.onDragEnd(),
        onHorizontalDragUpdate: (d) => widget.onDragUpdate(d.delta.dx),
        onDoubleTap: widget.onDoubleTap,
        child: SizedBox(
          width: widget.width,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: isActive ? 2 : 1,
              color: isActive
                  ? context.antgrid.borderStrong
                  : context.antgrid.borderDefault,
            ),
          ),
        ),
      ),
    );
  }
}
