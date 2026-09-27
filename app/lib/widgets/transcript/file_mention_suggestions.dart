import 'package:flutter/widgets.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_tokens.dart';
import 'suggestion_panel.dart';

/// A candidate for @-mention completion: a project-relative POSIX path plus
/// whether it is a directory (dirs display and insert with a trailing '/').
///
/// Matching and ranking both happen bridge-side now (`file:find`, backing
/// [FileService.find] — basename-subsequence match beats path-only, then
/// shallow-first, then alpha; see the bridge's `matchFindEntries`). There is
/// no client-side re-filter: the bridge already matched [query] fuzzily
/// (subsequence, not substring), so re-testing `path.contains(query)` here
/// would silently drop entries it matched that this simpler test would not.
typedef FileMention = ({String path, bool isDir});

/// @-mention panel rendered directly above the composer input while a mention
/// token is being typed. Pure display + tap, same contract as
/// [SlashSuggestions]: filtering, highlight index, and keyboard handling live
/// in the composer (it owns focus + controller).
class FileMentionSuggestions extends StatelessWidget {
  const FileMentionSuggestions({
    super.key,
    required this.entries,
    required this.selectedIndex,
    required this.onPick,
    this.visible = true,
    this.loading = false,
    this.error,
  });

  final List<FileMention> entries;
  final int selectedIndex;
  final void Function(FileMention entry) onPick;

  /// Whether an @-mention token is active at all. Distinct from [entries]
  /// being empty: an inactive/dismissed token renders nothing (matching
  /// [SuggestionPanel]'s own empty collapse), while an ACTIVE token with no
  /// entries yet must still say something — a still-loading or genuinely
  /// no-match search rendering nothing would look identical to the panel
  /// simply not being open.
  final bool visible;

  /// True while the `file:find` backing [entries] is in flight for the
  /// CURRENT query — distinguishes "still searching" from "searched, no
  /// matches" while [entries] is empty either way.
  final bool loading;

  /// Set when the search itself failed (a killed or timed-out engine, a
  /// dropped reply). [entries] is empty in that case too, which is why the
  /// third state has to be carried rather than inferred.
  final String? error;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();
    if (entries.isEmpty) {
      final failure = error;
      if (failure != null && !loading) {
        return _StatusRow(text: 'Search failed: $failure');
      }
      return _StatusRow(text: loading ? 'Searching…' : 'No matching files');
    }
    return SuggestionPanel<FileMention>(
      items: entries,
      selectedIndex: selectedIndex,
      onPick: onPick,
      rowBuilder: (context, e, selected) {
        final colors = context.antgrid;
        // The trailing '/' is the directory marker — no icons in v1.
        return Text(
          e.isDir ? '${e.path}/' : e.path,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AbTokens.monoStyle(
            fontSize: AbTokens.fontSm,
            color: selected ? colors.textPrimary : colors.textSecondary,
          ),
        );
      },
    );
  }
}

/// A single-line, non-interactive row matching [SuggestionPanel]'s chrome —
/// used only for the loading/no-match states, which have no item to select
/// or tap.
class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = context.antgrid;
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
      padding: const EdgeInsets.symmetric(
        horizontal: AbTokens.space8,
        vertical: AbTokens.space4,
      ),
      child: Text(
        text,
        style: AbTokens.sansStyle(
          fontSize: AbTokens.fontSm,
          color: colors.textMuted,
        ),
      ),
    );
  }
}
