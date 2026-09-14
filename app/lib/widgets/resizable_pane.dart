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
  /// Applied during layout, so the floor stays a fixed
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

  double get _available {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return 0;
    return math.max(0, box.size.width - _handleWidth);
  }

  _PaneLayout get _layout => _PaneLayout(
    ratio: _ratio,
    minRatio: widget.minRatio,
    maxRatio: widget.maxRatio,
    minLeftWidth: widget.minLeftWidth,
    minRightWidth: widget.minRightWidth,
  );

  @override
  Widget build(BuildContext context) {
    // Children must mount during build: a LayoutBuilder would reparent the
    // panels' live OverlayPortals during layout and dirty the root Overlay.
    // The delegate only sizes existing children, using this frame's width.
    return CustomMultiChildLayout(
      delegate: _layout,
      children: [
        LayoutId(id: _PaneSlot.left, child: widget.left),
        LayoutId(
          id: _PaneSlot.handle,
          child: _DragHandle(
            width: _handleWidth,
            isDragging: _isDragging,
            onDragStart: () => setState(() => _isDragging = true),
            onDragEnd: () {
              setState(() => _isDragging = false);
              widget.onRatioChanged?.call(_layout.clampRatio(_available));
            },
            onDragUpdate: (dx) {
              final available = _available;
              if (available <= 0) return;
              final layout = _layout;
              final current = layout.clampRatio(available);
              setState(() {
                _ratio = layout.clampRatio(available, current + dx / available);
              });
            },
            onDoubleTap: () {
              setState(() => _ratio = 0.5);
              widget.onRatioChanged?.call(_layout.clampRatio(_available));
            },
          ),
        ),
        LayoutId(id: _PaneSlot.right, child: widget.right),
      ],
    );
  }
}

enum _PaneSlot { left, handle, right }

class _PaneLayout extends MultiChildLayoutDelegate {
  _PaneLayout({
    required this.ratio,
    required this.minRatio,
    required this.maxRatio,
    required this.minLeftWidth,
    required this.minRightWidth,
  });

  final double ratio;
  final double minRatio;
  final double maxRatio;
  final double? minLeftWidth;
  final double? minRightWidth;

  double clampRatio(double available, [double? value]) {
    var min = minRatio;
    var max = maxRatio;
    if (available > 0) {
      final left = minLeftWidth;
      final right = minRightWidth;
      if (left != null) min = math.max(min, left / available);
      if (right != null) max = math.min(max, 1 - right / available);
    }
    // Both floors cannot always fit in a small window.
    return min <= max ? (value ?? ratio).clamp(min, max) : 0.5;
  }

  @override
  void performLayout(Size size) {
    final handleWidth = math.min(_handleWidth, size.width);
    final available = size.width - handleWidth;
    final leftWidth = available * clampRatio(available);
    layoutChild(
      _PaneSlot.left,
      BoxConstraints.tight(Size(leftWidth, size.height)),
    );
    positionChild(_PaneSlot.left, Offset.zero);
    layoutChild(
      _PaneSlot.handle,
      BoxConstraints.tight(Size(handleWidth, size.height)),
    );
    positionChild(_PaneSlot.handle, Offset(leftWidth, 0));
    layoutChild(
      _PaneSlot.right,
      BoxConstraints.tight(Size(available - leftWidth, size.height)),
    );
    positionChild(_PaneSlot.right, Offset(leftWidth + handleWidth, 0));
  }

  @override
  bool shouldRelayout(_PaneLayout oldDelegate) =>
      ratio != oldDelegate.ratio ||
      minRatio != oldDelegate.minRatio ||
      maxRatio != oldDelegate.maxRatio ||
      minLeftWidth != oldDelegate.minLeftWidth ||
      minRightWidth != oldDelegate.minRightWidth;
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
