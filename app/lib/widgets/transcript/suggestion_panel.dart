import 'package:flutter/widgets.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_tokens.dart';

/// Generic suggestion panel rendered directly above the composer input: the
/// shared chrome + sliding-window logic behind the slash-command and @-mention
/// panels. Pure display + tap — filtering, highlight index, and keyboard
/// handling live in the composer (it owns focus + controller). [rowBuilder]
/// supplies only the row CONTENT; the highlight/tap container is owned here.
class SuggestionPanel<T> extends StatelessWidget {
  const SuggestionPanel({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.onPick,
    required this.rowBuilder,
  });

  final List<T> items;
  final int selectedIndex;
  final void Function(T item) onPick;
  final Widget Function(BuildContext context, T item, bool selected) rowBuilder;

  static const int maxVisible = 6;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final colors = context.antgrid;
    final start = windowStart(items.length, selectedIndex);
    final end = (start + maxVisible).clamp(0, items.length);
    return Container(
      margin: const EdgeInsets.fromLTRB(
        AbTokens.space8,
        0,
        AbTokens.space8,
        AbTokens.space4,
      ),
      decoration: BoxDecoration(
        color: colors.bgRaised,
        border: Border.all(color: colors.borderSubtle),
        borderRadius: AbTokens.borderRadius5,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [for (var i = start; i < end; i++) _row(context, i)],
      ),
    );
  }

  // Slides the maxVisible-row window to keep selectedIndex in view, moving
  // one row per keypress in either direction rather than jumping — this is
  // what makes arrow-key nav read as scrolling instead of a hard 6-item cap.
  static int windowStart(int total, int selectedIndex) {
    if (total <= maxVisible) return 0;
    final start = selectedIndex < maxVisible
        ? 0
        : selectedIndex - maxVisible + 1;
    return start.clamp(0, total - maxVisible);
  }

  Widget _row(BuildContext context, int index) {
    final colors = context.antgrid;
    final selected = index == selectedIndex;
    final item = items[index];
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onPick(item),
      child: Container(
        // Match AbMenu's active-row treatment (bgHover + a text-brightness
        // step): a background shade alone reads as nearly invisible against
        // this panel's already-dark bgRaised.
        color: selected ? colors.bgHover : null,
        padding: const EdgeInsets.symmetric(
          horizontal: AbTokens.space8,
          vertical: AbTokens.space4,
        ),
        child: rowBuilder(context, item, selected),
      ),
    );
  }
}
