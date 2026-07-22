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

  const ResizablePane({
    super.key,
    required this.left,
    required this.right,
    this.initialRatio = 0.5,
    this.minRatio = 0.2,
    this.maxRatio = 0.8,
    this.onRatioChanged,
  });

  @override
  State<ResizablePane> createState() => _ResizablePaneState();
}

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

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final totalWidth = constraints.maxWidth;
        const handleWidth = 4.0;
        final available = totalWidth - handleWidth;
        final leftWidth = available * _ratio;
        final rightWidth = available * (1 - _ratio);

        return Row(
          children: [
            SizedBox(width: leftWidth, child: widget.left),
            _DragHandle(
              width: handleWidth,
              isDragging: _isDragging,
              onDragStart: () => setState(() => _isDragging = true),
              onDragEnd: () {
                setState(() => _isDragging = false);
                widget.onRatioChanged?.call(_ratio);
              },
              onDragUpdate: (dx) {
                setState(() {
                  _ratio = ((_ratio * available + dx) / available).clamp(
                    widget.minRatio,
                    widget.maxRatio,
                  );
                });
              },
              onDoubleTap: () {
                setState(() => _ratio = 0.5);
                widget.onRatioChanged?.call(0.5);
              },
            ),
            SizedBox(width: rightWidth, child: widget.right),
          ],
        );
      },
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
