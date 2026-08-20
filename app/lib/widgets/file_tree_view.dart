import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../design/ab_icons.dart';
import '../design/ab_status_tone.dart';
import '../design/ab_tokens.dart';
import '../design/ab_colors.dart';
import '../design/widgets/ab_diff_stat.dart';
import '../design/widgets/ab_empty_state.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_list_row.dart';
import '../design/widgets/ab_status_dot.dart';
import '../design/widgets/ab_swipe_actions.dart';
import '../models/ab_message.dart' show GitFileStatusEntry;
import '../models/file_tree_models.dart';
import '../utils/platform_utils.dart';

/// A widget that renders a file tree with expand/collapse, file selection,
/// directory-first sorting, and optional name filtering.
///
/// [gitFileEntries] is optional decoration: pass it (with
/// [onStage]/[onUnstage]/[onDiscard]) from the Git tab to get a +N/-N diff-stat
/// badge on changed files, a dot on any ancestor directory that contains a
/// change, and stage/unstage/discard actions — hover-revealed icon buttons on
/// desktop, a swipe tray on touch, never both. The SAME tree the Files tab
/// renders, undecorated, when these are omitted.
///
/// [changesOnly] prunes that same tree down to changed files and their
/// ancestor directories only (everything else hidden, not just undecorated),
/// always shown expanded — no folder-by-folder clicking to find what
/// changed. A deleted tracked file has nothing on disk to attach a row to,
/// so it has no row here even in [changesOnly] mode (matching VS Code's own
/// Explorer, which is equally tree-shaped) — the header's Discard All still
/// reaches it by path.
class FileTreeView extends StatelessWidget {
  final FileNode? root;
  final Set<String> expandedPaths;
  final String? selectedFilePath;
  final String? filterQuery;
  final List<GitFileStatusEntry> gitFileEntries;
  final bool changesOnly;
  final void Function(String path) onToggleExpanded;
  final void Function(String path) onFileSelected;
  final void Function(String path)? onStage;
  final void Function(String path)? onUnstage;
  final void Function(String path)? onDiscard;

  const FileTreeView({
    super.key,
    required this.root,
    required this.expandedPaths,
    this.selectedFilePath,
    this.filterQuery,
    this.gitFileEntries = const [],
    this.changesOnly = false,
    required this.onToggleExpanded,
    required this.onFileSelected,
    this.onStage,
    this.onUnstage,
    this.onDiscard,
  });

  @override
  Widget build(BuildContext context) {
    // [changesOnly] answers from [gitFileEntries] alone — the tree only SHAPES
    // that answer with folder rows and nesting, and [_flattenChangesOnly]
    // already falls back to a flat depth-0 row for any changed path the tree
    // has no node for. The two arrive independently: `git:status` is a push
    // (`file_service.dart`'s `_handleGitStatus`) while `root` waits on a lazy
    // per-checkout tree hydration, so bailing here cost the Git tab its whole
    // list whenever the status landed first — "No files available" beside a
    // header counting N changes. An unhydrated tree may cost nesting; it must
    // never cost contents.
    if (root == null && !changesOnly) {
      return const AbEmptyState(
        icon: AbIcons.folder,
        title: 'No files available',
      );
    }

    final entriesByPath = <String, List<GitFileStatusEntry>>{};
    final dirsWithChanges = <String>{};
    for (final e in gitFileEntries) {
      entriesByPath.putIfAbsent(e.path, () => []).add(e);
      var dir = e.path;
      var slash = dir.lastIndexOf('/');
      while (slash >= 0) {
        dir = dir.substring(0, slash);
        // Already recorded => every ancestor above it was too, on a
        // previous entry's walk.
        if (!dirsWithChanges.add(dir)) break;
        slash = dir.lastIndexOf('/');
      }
    }

    final flatList = changesOnly
        ? _flattenChangesOnly(root, entriesByPath, dirsWithChanges)
        : _flattenVisibleNodes(root!, expandedPaths, filterQuery);

    if (flatList.isEmpty) {
      return AbEmptyState(
        icon: changesOnly ? AbIcons.check : AbIcons.search,
        title: changesOnly ? 'No changed files' : 'No matching files',
      );
    }

    // A row whose tray is open slides out from under the finger the moment
    // the list moves; nothing else in the app can close it from here.
    return NotificationListener<ScrollNotification>(
      onNotification: (_) {
        AbSwipeActions.closeAny();
        return false;
      },
      child: ListView.builder(
        itemCount: flatList.length,
        itemBuilder: (context, index) {
          final (node, depth) = flatList[index];
          final isDirectory = node.type == FileNodeType.directory;
          return _FileTreeRow(
            key: ValueKey(node.path),
            node: node,
            depth: depth,
            isExpanded: changesOnly || expandedPaths.contains(node.path),
            isSelected: node.path == selectedFilePath,
            changeEntries: entriesByPath[node.path] ?? const [],
            // A changesOnly directory is always shown expanded (nothing to
            // toggle — every child left after pruning is already relevant).
            onTap: isDirectory
                ? (changesOnly ? null : () => onToggleExpanded(node.path))
                : () => onFileSelected(node.path),
            onStage: onStage,
            onUnstage: onUnstage,
            onDiscard: onDiscard,
          );
        },
      ),
    );
  }
}

/// Flatten the tree into a list of (node, depth) pairs for rendering.
/// When filterQuery is active, show ALL matching files regardless of
/// directory expand state.
List<(FileNode, int)> _flattenVisibleNodes(
  FileNode root,
  Set<String> expandedPaths,
  String? filterQuery,
) {
  final result = <(FileNode, int)>[];
  final query = filterQuery?.toLowerCase().trim();

  if (query != null && query.isNotEmpty) {
    _flattenFiltered(root, 0, query, result);
  } else {
    // Root node itself is the project directory; show its children at depth 0
    for (final child in root.children) {
      _flattenNormal(child, 0, expandedPaths, result);
    }
  }

  return result;
}

void _flattenNormal(
  FileNode node,
  int depth,
  Set<String> expandedPaths,
  List<(FileNode, int)> result,
) {
  result.add((node, depth));

  if (node.type == FileNodeType.directory &&
      expandedPaths.contains(node.path)) {
    for (final child in node.children) {
      _flattenNormal(child, depth + 1, expandedPaths, result);
    }
  }
}

void _flattenFiltered(
  FileNode node,
  int depth,
  String query,
  List<(FileNode, int)> result,
) {
  if (node.type == FileNodeType.file) {
    if (node.name.toLowerCase().contains(query)) {
      result.add((node, 0));
    }
    return;
  }

  // Directory: recurse into children
  for (final child in node.children) {
    _flattenFiltered(child, depth + 1, query, result);
  }
}

/// Prunes the tree to changed files and their ancestor directories only,
/// always recursing (ignores [FileTreeView.expandedPaths] entirely) — a
/// directory left after pruning has nothing on it BUT a path toward a
/// change, so there's nothing to gain from collapsing it.
///
/// Then appends a flat row for every changed path the tree has NO node for, so
/// a change can never be invisible just because the tree can't represent it.
/// Four ways that happens, and a deletion — the common one — is unfixable in
/// the tree by definition: the file is gone from disk, so nothing built from
/// disk can carry it. (The others: a path deeper than the bridge's tree depth
/// cap, a tracked file the tree's ignore rules exclude, and a [root] still
/// null because `git:status` landed before the tree hydrated, which puts EVERY
/// change through this pass.) Without these rows such a file cannot be seen,
/// staged, unstaged or diffed, while the header still counts it in
/// "Commit (N)" — a count the list can't account for.
List<(FileNode, int)> _flattenChangesOnly(
  FileNode? root,
  Map<String, List<GitFileStatusEntry>> entriesByPath,
  Set<String> dirsWithChanges,
) {
  final result = <(FileNode, int)>[];
  final placed = <String>{};

  void walk(FileNode node, int depth) {
    for (final child in node.children) {
      final isDirectory = child.type == FileNodeType.directory;
      final relevant = isDirectory
          ? dirsWithChanges.contains(child.path)
          : entriesByPath.containsKey(child.path);
      if (!relevant) continue;
      result.add((child, depth));
      if (!isDirectory) placed.add(child.path);
      if (isDirectory) walk(child, depth + 1);
    }
  }

  // A null root is a tree that has not hydrated yet, not an empty repo — every
  // change simply falls through to the orphan pass below, unnested.
  if (root != null) walk(root, 0);

  // Depth 0 with the FULL path as the label, not the basename: there is no
  // directory row above these to give a bare name its context, and two files
  // deleted out of different folders would otherwise be indistinguishable.
  final orphans = entriesByPath.keys.where((p) => !placed.contains(p)).toList()
    ..sort();
  for (final path in orphans) {
    result.add((FileNode(name: path, path: path, type: FileNodeType.file), 0));
  }
  return result;
}

class _FileTreeRow extends StatefulWidget {
  final FileNode node;
  final int depth;
  final bool isExpanded;
  final bool isSelected;
  final List<GitFileStatusEntry> changeEntries;
  final VoidCallback? onTap;
  final void Function(String path)? onStage;
  final void Function(String path)? onUnstage;
  final void Function(String path)? onDiscard;

  const _FileTreeRow({
    super.key,
    required this.node,
    required this.depth,
    required this.isExpanded,
    required this.isSelected,
    this.changeEntries = const [],
    this.onTap,
    this.onStage,
    this.onUnstage,
    this.onDiscard,
  });

  @override
  State<_FileTreeRow> createState() => _FileTreeRowState();
}

// Hover-revealed actions, same convention as session_row.dart /
// drawer_entry_row.dart: mobile has no hover, so actions start visible;
// desktop reveals them only on hover.
class _FileTreeRowState extends State<_FileTreeRow> {
  late bool _hovered = isMobilePlatform;

  void _onEnter(PointerEnterEvent _) {
    if (isMobilePlatform) return;
    if (!_hovered && mounted) setState(() => _hovered = true);
  }

  void _onExit(PointerExitEvent _) {
    if (isMobilePlatform) return;
    if (_hovered && mounted) setState(() => _hovered = false);
  }

  /// A row with its own tray open absorbs its tap to close it, so this only
  /// ever runs on some OTHER row — where the open tray is a stale affordance
  /// the same way a scroll makes it one, and leaving it latched would strand
  /// it on a row nobody is touching.
  void _handleTap() {
    AbSwipeActions.closeAny();
    widget.onTap!();
  }

  @override
  Widget build(BuildContext context) {
    final isDirectory = widget.node.type == FileNodeType.directory;
    final isConflict = widget.changeEntries.any((e) => e.status == '!');
    final isStaged = widget.changeEntries.any((e) => e.staged);
    final isUnstaged = widget.changeEntries.any((e) => !e.staged);

    // A conflict has nothing safe to stage/unstage/discard — resolving it
    // isn't a "restore to HEAD".
    final onStagePath =
        (!isDirectory && isUnstaged && !isConflict && widget.onStage != null)
        ? () => widget.onStage!(widget.node.path)
        : null;
    final onUnstagePath = (!isDirectory && isStaged && widget.onUnstage != null)
        ? () => widget.onUnstage!(widget.node.path)
        : null;
    // Offered on a STAGED-only row too: Discard means "back to HEAD", and a
    // file whose only change sits in the index is exactly the case where
    // making the user unstage first buys nothing.
    final onDiscardPath =
        (!isDirectory &&
            (isUnstaged || isStaged) &&
            !isConflict &&
            widget.onDiscard != null)
        ? () => widget.onDiscard!(widget.node.path)
        : null;
    // Touch rows carry no action buttons at all — the swipe tray below is the
    // whole affordance there. Three always-visible 44px targets (there is no
    // hover to hide them behind) crowded out the diff stat the row exists to
    // show, on the narrowest pane in the app. A pointer has no swipe and pays
    // nothing for chrome it only sees on hover, so desktop keeps the buttons.
    final showRowButtons = !isMobilePlatform;
    final hasActions =
        showRowButtons &&
        (onStagePath != null || onUnstagePath != null || onDiscardPath != null);
    // Directories carry no decoration of their own — in changesOnly mode
    // every directory left after pruning already implies a descendant
    // changed, so a dot on top of that is redundant noise.
    final hasDecoration = !isDirectory && widget.changeEntries.isNotEmpty;

    Widget row = MouseRegion(
      cursor: widget.onTap != null
          ? SystemMouseCursors.click
          : MouseCursor.defer,
      onEnter: _onEnter,
      onExit: _onExit,
      child: AbListRow(
        onTap: widget.onTap == null ? null : _handleTap,
        hoverable: true,
        selected: widget.isSelected,
        selectionStyle: AbRowSelection.surface,
        density: AbRowDensity.sm,
        leading: Padding(
          padding: EdgeInsets.only(left: widget.depth * AbTokens.space16),
          child: isDirectory
              ? Text(
                  widget.isExpanded ? '▼ ' : '▶ ',
                  style: TextStyle(
                    fontSize: AbTokens.fontXxs,
                    color: context.antgrid.textMuted,
                  ),
                )
              : const Text('  ', style: TextStyle(fontSize: AbTokens.fontXxs)),
        ),
        title: Text(
          widget.node.name,
          style: AbTokens.monoStyle(
            fontSize: AbTokens.fontSm,
            fontWeight: isDirectory ? FontWeight.w500 : FontWeight.normal,
            color: widget.isSelected
                ? context.antgrid.accent
                : isDirectory
                ? context.antgrid.textSecondary
                : context.antgrid.textPrimary,
          ),
          overflow: TextOverflow.ellipsis,
        ),
        trailing: (hasActions || hasDecoration)
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (hasActions)
                    Visibility(
                      // Reserved size (not just visibility) so the row never
                      // jitters width on hover — same technique
                      // session_row.dart uses for its hover-only kebab menu.
                      visible: _hovered,
                      maintainState: true,
                      maintainAnimation: true,
                      maintainSize: true,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (onStagePath != null)
                            AbIconButton(
                              icon: AbIcons.gitStage,
                              onTap: onStagePath,
                              tooltip: 'Stage Changes',
                            ),
                          if (onUnstagePath != null)
                            AbIconButton(
                              icon: AbIcons.gitUnstage,
                              onTap: onUnstagePath,
                              tooltip: 'Unstage Changes',
                            ),
                          if (onDiscardPath != null)
                            AbIconButton(
                              icon: AbIcons.revert,
                              onTap: onDiscardPath,
                              tooltip: 'Discard Changes',
                            ),
                        ],
                      ),
                    ),
                  if (hasActions && hasDecoration)
                    const SizedBox(width: AbTokens.space4),
                  if (hasDecoration)
                    _DiffStatBadge(entries: widget.changeEntries),
                ],
              )
            : null,
      ),
    );

    // On touch this tray is the ONLY per-file affordance, which is why discard
    // rides in it beside stage/unstage rather than keeping a button of its own.
    //
    // LEFTWARD only, and deliberately not both ways. Rightward dismisses a
    // surface everywhere in this app (the mobile drawer, the agent page's back
    // fling, the touch tablet's sidebar), so rightward stays the surface's and
    // the row keeps left. One direction for three actions is exactly what a
    // tray solves; see [AbSwipeActions] for the guards that keep a slip from
    // firing one.
    final stageAction = onStagePath ?? onUnstagePath;
    if (isMobilePlatform && !isDirectory) {
      row = AbSwipeActions(
        actions: [
          // First is the trailing-edge cell and the full-swipe action — the
          // reversible one, never Revert.
          if (stageAction != null)
            AbSwipeAction(
              icon: onStagePath != null ? AbIcons.gitStage : AbIcons.gitUnstage,
              label: onStagePath != null ? 'Stage' : 'Unstage',
              color: context.antgrid.success,
              onInvoke: stageAction,
            ),
          if (onDiscardPath != null)
            AbSwipeAction(
              icon: AbIcons.revert,
              label: 'Revert',
              color: context.antgrid.error,
              onInvoke: onDiscardPath,
              destructive: true,
            ),
        ],
        child: row,
      );
    }

    return row;
  }
}

/// The trailing +N/-M diff-stat badge for a changed file. [entries] holds
/// 1-2 [GitFileStatusEntry] for the row's path (staged and/or unstaged) —
/// both carry the SAME additions/deletions (the bridge computes one combined
/// diff vs HEAD), so either serves.
class _DiffStatBadge extends StatelessWidget {
  const _DiffStatBadge({required this.entries});

  final List<GitFileStatusEntry> entries;

  @override
  Widget build(BuildContext context) {
    final entry = entries.first;
    if (entry.status == '!') {
      return const AbStatusDot(tone: AbStatusTone.danger);
    }
    if (entry.additions == 0 && entry.deletions == 0) {
      // A pure rename or a mode-only change: nothing to count in lines.
      return const AbStatusDot(tone: AbStatusTone.warning);
    }
    return AbDiffStat(additions: entry.additions, deletions: entry.deletions);
  }
}
