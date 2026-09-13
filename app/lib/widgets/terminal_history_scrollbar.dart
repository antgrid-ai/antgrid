import 'dart:math' as math;
import 'package:flutter/widgets.dart';
import '../design/ab_colors.dart';
import '../design/ab_tokens.dart';

/// An archive-sized track independent of the engine's bounded page cache.
class TerminalHistoryScrollbar extends StatefulWidget {
  const TerminalHistoryScrollbar({
    super.key,
    required this.firstRow,
    required this.liveRow,
    required this.position,
    required this.viewportRows,
    required this.onSeek,
  });
  final int firstRow, liveRow, position, viewportRows;
  final ValueChanged<int> onSeek;
  @override
  State<TerminalHistoryScrollbar> createState() =>
      _TerminalHistoryScrollbarState();
}

class _TerminalHistoryScrollbarState extends State<TerminalHistoryScrollbar> {
  (int, int)? _dragRange;
  double _grab = 0;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, size) {
      final first = _dragRange?.$1 ?? widget.firstRow;
      final last = _dragRange?.$2 ?? widget.liveRow;
      final range = math.max(1, last - first);
      final height = math.min(
        size.maxHeight,
        math.max(
          AbTokens.space24,
          size.maxHeight * widget.viewportRows / (range + widget.viewportRows),
        ),
      );
      final travel = math.max(1.0, size.maxHeight - height);
      final top = ((widget.position - first) / range).clamp(0.0, 1.0) * travel;
      void seek(double y) => widget.onSeek(
        first + (((y - _grab) / travel).clamp(0.0, 1.0) * range).round(),
      );
      return Semantics(
        label: 'Terminal scrollback',
        value: widget.position >= last ? 'Live' : 'History',
        increasedValue: 'Newer output',
        decreasedValue: 'Older output',
        onIncrease: () => widget.onSeek(
          math.min(last, widget.position + widget.viewportRows),
        ),
        onDecrease: () => widget.onSeek(
          math.max(first, widget.position - widget.viewportRows),
        ),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragStart: (d) {
            setState(() => _dragRange = (first, last));
            _grab =
                d.localPosition.dy >= top && d.localPosition.dy <= top + height
                ? d.localPosition.dy - top
                : height / 2;
            seek(d.localPosition.dy);
          },
          onVerticalDragUpdate: (d) => seek(d.localPosition.dy),
          onVerticalDragEnd: (_) => setState(() => _dragRange = null),
          onVerticalDragCancel: () => setState(() => _dragRange = null),
          onTapUp: (d) {
            _grab = height / 2;
            seek(d.localPosition.dy);
          },
          child: Stack(
            children: [
              Positioned(
                top: top,
                right: AbTokens.space2,
                width: AbTokens.space6,
                height: height,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: context.antgrid.borderStrong,
                    borderRadius: BorderRadius.circular(AbTokens.space6),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
