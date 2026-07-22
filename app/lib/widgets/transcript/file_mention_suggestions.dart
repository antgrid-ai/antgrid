import 'package:flutter/widgets.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_tokens.dart';
import '../../models/file_tree_models.dart';
import 'suggestion_panel.dart';

/// A candidate for @-mention completion: a project-relative POSIX path plus
/// whether it is a directory (dirs display and insert with a trailing '/').
typedef FileMention = ({String path, bool isDir});

/// Depth-first flatten of the synced tree into mention candidates. Skips the
/// root node itself (path == '' — it stands for the project directory, not a
/// mentionable path). O(n); callers cache per root identity.
List<FileMention> flattenFileTree(FileNode? root) {
  if (root == null) return const [];
  final out = <FileMention>[];
  void visit(FileNode node) {
    if (node.path.isNotEmpty) {
      out.add((path: node.path, isDir: node.type == FileNodeType.directory));
    }
    for (final child in node.children) {
      visit(child);
    }
  }

  visit(root);
  return out;
}

/// Case-insensitive filter + rank for the @-mention panel. Match = [query] is
/// a substring of the path. Rank tiers: 0 filename starts with query,
/// 1 filename contains it, 2 only the full path does. Sort:
/// (isDir, rank, depth, pathLower) — all files strictly before all dirs, then
/// rank, then shallow-first, then alpha. An empty query matches everything at
/// rank 0, degenerating to a files-first shallow-first browse list.
List<FileMention> filterFileMentions(
  List<FileMention> all,
  String query, {
  int limit = 50,
}) {
  final q = query.toLowerCase();
  final ranked = <({FileMention m, int rank, int depth, String pathLower})>[];
  for (final m in all) {
    final pathLower = m.path.toLowerCase();
    if (!pathLower.contains(q)) continue;
    final nameLower = pathLower.split('/').last;
    final rank = nameLower.startsWith(q)
        ? 0
        : nameLower.contains(q)
        ? 1
        : 2;
    ranked.add((
      m: m,
      rank: rank,
      depth: '/'.allMatches(m.path).length,
      pathLower: pathLower,
    ));
  }
  ranked.sort((a, b) {
    if (a.m.isDir != b.m.isDir) return a.m.isDir ? 1 : -1;
    if (a.rank != b.rank) return a.rank - b.rank;
    if (a.depth != b.depth) return a.depth - b.depth;
    return a.pathLower.compareTo(b.pathLower);
  });
  if (ranked.length <= limit) return [for (final r in ranked) r.m];
  // Over the cap: files sort ahead of every directory, so a plain take(limit)
  // can crowd folders out entirely — `@src` in a subtree of >limit files would
  // truncate `src` itself, the folder the user is most likely reaching for.
  // Reserve a slice of the cap for directories so a matched folder stays
  // reachable; files still lead the display order.
  final dirReserve = limit < 10 ? limit : 10;
  final files = [
    for (final r in ranked)
      if (!r.m.isDir) r.m,
  ];
  final dirs = [
    for (final r in ranked)
      if (r.m.isDir) r.m,
  ];
  final dirSlots = dirs.length < dirReserve ? dirs.length : dirReserve;
  final chosenFiles = files.take(limit - dirSlots).toList();
  final chosenDirs = dirs.take(limit - chosenFiles.length).toList();
  return [...chosenFiles, ...chosenDirs];
}

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
  });

  final List<FileMention> entries;
  final int selectedIndex;
  final void Function(FileMention entry) onPick;

  @override
  Widget build(BuildContext context) {
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
