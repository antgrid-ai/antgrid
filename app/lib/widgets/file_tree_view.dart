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
/// [onStage]/[onUnstage]/[onDiscard]/[onResolveConflict]) from the Git tab to
/// get a +N/-N diff-stat badge on changed files, a dot on one with nothing to
/// count, and stage/unstage/discard/resolve actions — hover-revealed icon
/// buttons on desktop, a swipe tray on touch, never both. The SAME tree the
/// Files tab renders, undecorated, when these are omitted.
///
/// [changesOnly] switches the tree to the changed files alone, nested under
/// the folders they live in and opened by default — no folder-by-folder
/// clicking to find what changed. That tree is assembled from the change
/// PATHS, not from [root] (see [_flattenChangesOnly]), so a deletion gets an
/// ordinary nested row like everything else and the list looks the same
/// whether or not the file tree has arrived yet. [collapsedPaths] is how the
/// user folds a folder back up once the list is long enough to need it; a
/// folded folder then carries the rollup of what it hides.
class FileTreeView extends StatelessWidget {
  final FileNode? root;
  final Set<String> expandedPaths;
  final String? selectedFilePath;
  final String? filterQuery;
  final List<GitFileStatusEntry> gitFileEntries;
  final bool changesOnly;

  /// Folders folded shut, in [changesOnly] mode only. Empty means the whole
  /// change set is open, which is this tree's default — the inverse sense of
  /// [expandedPaths], for the reason [GitPaneState.collapsedPaths] documents.
  final Set<String> collapsedPaths;
  final void Function(String path) onToggleExpanded;
  final void Function(String path) onFileSelected;
  final void Function(String path)? onStage;
  final void Function(String path)? onUnstage;
  final void Function(String path)? onDiscard;

  /// Mark a conflicted file resolved (`git add` — that IS git's resolution
  /// step). Separate from [onStage], which is deliberately withheld from a
  /// conflicted row: staging one is a claim about the file's content, not the
  /// routine "include this in the next commit" the + button means everywhere
  /// else, so it gets its own affordance and its own confirmation.
  final void Function(String path)? onResolveConflict;

  const FileTreeView({
    super.key,
    required this.root,
    required this.expandedPaths,
    this.selectedFilePath,
    this.filterQuery,
    this.gitFileEntries = const [],
    this.changesOnly = false,
    this.collapsedPaths = const {},
    required this.onToggleExpanded,
    required this.onFileSelected,
    this.onStage,
    this.onUnstage,
    this.onDiscard,
    this.onResolveConflict,
  });

  @override
  Widget build(BuildContext context) {
    // [changesOnly] answers from [gitFileEntries] alone, nesting included, so
    // it has nothing to bail out of: the two arrive independently
    // (`git:status` is a push — `file_service.dart`'s `_handleGitStatus` —
    // while `root` waits on a lazy per-checkout tree hydration), and the Git
    // tab must render the same list either way.
    if (root == null && !changesOnly) {
      return const AbEmptyState(
        icon: AbIcons.folder,
        title: 'No files available',
      );
    }

    final entriesByPath = <String, List<GitFileStatusEntry>>{};
    // The ancestors of every CONFLICTED path — what lets a folder sort ahead
    // of its siblings for holding one somewhere below (see
    // [_flattenChangesOnly]).
    final dirsWithConflicts = <String>{};
    for (final e in gitFileEntries) {
      entriesByPath.putIfAbsent(e.path, () => []).add(e);
      if (e.status != '!') continue;
      var dir = e.path;
      var slash = dir.lastIndexOf('/');
      while (slash >= 0) {
        dir = dir.substring(0, slash);
        // Already recorded => every ancestor above it was too, on an earlier
        // conflict's walk.
        if (!dirsWithConflicts.add(dir)) break;
        slash = dir.lastIndexOf('/');
      }
    }

    final flatList = changesOnly
        ? _flattenChangesOnly(entriesByPath, dirsWithConflicts, collapsedPaths)
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
            // Typed, because one path can produce two rows: replacing a file
            // with a directory of the same name leaves a deletion and an
            // addition that share it, and a bare path key would be a duplicate.
            key: ValueKey((node.path, node.type)),
            node: node,
            depth: depth,
            isExpanded: changesOnly
                ? !collapsedPaths.contains(node.path)
                : expandedPaths.contains(node.path),
            isSelected: node.path == selectedFilePath,
            changeEntries: entriesByPath[node.path] ?? const [],
            // A folded folder answers for what it hides, so it carries the
            // rollup its children can no longer show; an open one stays bare
            // (its rows are right there, and a second stat over them is noise).
            rollupEntries: isDirectory && collapsedPaths.contains(node.path)
                ? _descendantEntries(node, entriesByPath)
                : const [],
            onTap: isDirectory
                ? () => onToggleExpanded(node.path)
                : () => onFileSelected(node.path),
            onStage: onStage,
            onUnstage: onUnstage,
            onDiscard: onDiscard,
            onResolveConflict: onResolveConflict,
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

/// The changed-files tree, assembled from the change PATHS alone — the file
/// tree [FileTreeView.root] carries is deliberately not consulted.
///
/// That tree cannot answer this question and never could. It is built from
/// disk, so a deleted file has no node in it; it stops at the bridge's depth
/// cap and at its ignore rules, so a deep path and a force-added ignored one
/// have none either; and it arrives on its own schedule (a lazy per-checkout
/// hydration) while `git:status` is pushed, so it is routinely absent
/// altogether. Each of those used to fall through to a flat, full-path row at
/// depth 0 — which made the ordinary first paint of the Git tab a flat list of
/// every change that then re-nested itself under the user a moment later. A
/// path already carries its own nesting, so deriving the tree from the changes
/// makes the list identical before and after the file tree lands, and gives a
/// deletion the same nested row as everything else.
///
/// Conflicts sort to the FRONT at every level: whatever holds an unresolved
/// merge — the conflicted file itself, or a directory with one anywhere below
/// ([dirsWithConflicts]) — is listed before its siblings, so a top-down read
/// reaches every conflict first without any of them losing the folder context
/// that says which `main.dart` it is.
///
/// [collapsedPaths] hides a folder's descendants without dropping the folder
/// itself, which then carries the rollup of what it hides.
List<(FileNode, int)> _flattenChangesOnly(
  Map<String, List<GitFileStatusEntry>> entriesByPath,
  Set<String> dirsWithConflicts,
  Set<String> collapsedPaths,
) {
  final result = <(FileNode, int)>[];

  bool holdsConflict(FileNode node) => node.type == FileNodeType.directory
      ? dirsWithConflicts.contains(node.path)
      : entriesByPath[node.path]?.any((e) => e.status == '!') ?? false;

  void walk(FileNode node, int depth) {
    // Stable partition, so everything that does NOT hold a conflict keeps the
    // order it was built in (directories first, then name) and only the
    // conflict-bearing rows move.
    final children = [
      ...node.children.where(holdsConflict),
      ...node.children.where((c) => !holdsConflict(c)),
    ];
    for (final child in children) {
      result.add((child, depth));
      if (child.type == FileNodeType.directory &&
          !collapsedPaths.contains(child.path)) {
        walk(child, depth + 1);
      }
    }
  }

  walk(_changesTree(entriesByPath.keys), 0);
  return result;
}

/// Assembles [paths] into a directory tree of their own, sorted the way
/// [FileNode.fromJson] sorts the real one (directories first, then
/// case-insensitively by name) so the two tabs agree on order.
///
/// Only the three fields a changed-file row reads are filled in — a real
/// [FileNode]'s size and extension have no reader here, and inventing values
/// for them would be inventing facts about a file that may not exist.
FileNode _changesTree(Iterable<String> paths) {
  final root = _ChangesDir('');
  for (final path in paths) {
    // Empty segments: a leading slash, and the trailing one git puts on an
    // untracked directory it did not walk into.
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) continue;
    var dir = root;
    for (final segment in segments.sublist(0, segments.length - 1)) {
      dir = dir.subdir(segment);
    }
    dir.filePaths.add(path);
  }
  return root.build('');
}

/// One directory while [_changesTree] is still filling it in.
class _ChangesDir {
  _ChangesDir(this.path);

  final String path;
  final Map<String, _ChangesDir> subdirs = {};

  /// Leaf rows, keyed by the change path VERBATIM rather than rebuilt from its
  /// segments: a row looks its entries up by that string and every action hands
  /// it straight back to git, and git's own `dir/` for an untracked directory
  /// it did not walk into would not survive the round trip.
  final Set<String> filePaths = {};

  String _childPath(String name) => path.isEmpty ? name : '$path/$name';

  _ChangesDir subdir(String name) =>
      subdirs.putIfAbsent(name, () => _ChangesDir(_childPath(name)));

  FileNode build(String name) {
    final children = <FileNode>[
      for (final entry in subdirs.entries) entry.value.build(entry.key),
      for (final filePath in filePaths)
        FileNode(
          name: filePath.split('/').where((s) => s.isNotEmpty).last,
          path: filePath,
          type: FileNodeType.file,
        ),
    ]..sort((a, b) {
      if (a.type != b.type) {
        return a.type == FileNodeType.directory ? -1 : 1;
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return FileNode(
      name: name,
      path: path,
      type: FileNodeType.directory,
      children: children,
    );
  }
}

/// One entry per changed file anywhere under [dir] — what a folded folder
/// summarizes. ONE per path, not one per git entry: a partially staged file
/// arrives twice carrying the SAME combined-vs-HEAD counts on both, so keeping
/// both would double it (the same dedup `_GitHeaderCounts` does for the header).
List<GitFileStatusEntry> _descendantEntries(
  FileNode dir,
  Map<String, List<GitFileStatusEntry>> entriesByPath,
) {
  final out = <GitFileStatusEntry>[];
  void walk(FileNode node) {
    for (final child in node.children) {
      if (child.type == FileNodeType.directory) {
        walk(child);
      } else {
        final entries = entriesByPath[child.path];
        if (entries != null && entries.isNotEmpty) out.add(entries.first);
      }
    }
  }

  walk(dir);
  return out;
}

/// One row of the tree.
///
/// The tree's trailing rule is COLLAPSE AND FLOOR, NO CELL: the git actions
/// are dropped from layout until the row is revealed, and the row's height is
/// anchored by [AbRowContentFloor] so mounting them shifts nothing. It takes
/// no shared trailing cell, unlike the drawer's rows — its outermost element
/// is a variable-width diff-stat badge inside a resizable pane, so there is no
/// fixed panel edge for a column to align against.
class _FileTreeRow extends StatefulWidget {
  final FileNode node;
  final int depth;
  final bool isExpanded;
  final bool isSelected;
  final List<GitFileStatusEntry> changeEntries;

  /// For a FOLDED directory: one entry per changed file it hides, so the row
  /// can stand in for the rows it is holding shut. Empty on every other row.
  final List<GitFileStatusEntry> rollupEntries;
  final VoidCallback? onTap;
  final void Function(String path)? onStage;
  final void Function(String path)? onUnstage;
  final void Function(String path)? onDiscard;
  final void Function(String path)? onResolveConflict;

  const _FileTreeRow({
    super.key,
    required this.node,
    required this.depth,
    required this.isExpanded,
    required this.isSelected,
    this.changeEntries = const [],
    this.rollupEntries = const [],
    this.onTap,
    this.onStage,
    this.onUnstage,
    this.onDiscard,
    this.onResolveConflict,
  });

  @override
  State<_FileTreeRow> createState() => _FileTreeRowState();
}

// Reveal, same convention as session_row.dart / drawer_entry_row.dart: mobile
// has no pointer to reveal anything with, so its affordance bit starts true.
class _FileTreeRowState extends State<_FileTreeRow> {
  late bool _hovered = isMobilePlatform;

  /// Keyboard focus reveals too, or the actions would be unreachable without a
  /// pointer once they are dropped from layout at rest.
  bool _focused = false;

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
    // The only action a conflicted row offers, and the only path out of the
    // state: without it the panel can show a conflict but never clear one, and
    // Commit stays refused with nothing in the app able to lift the refusal.
    final onResolvePath =
        (!isDirectory && isConflict && widget.onResolveConflict != null)
        ? () => widget.onResolveConflict!(widget.node.path)
        : null;
    // Touch rows carry no action buttons at all — the swipe tray below is the
    // whole affordance there. Three always-visible 44px targets (there is no
    // hover to hide them behind) crowded out the diff stat the row exists to
    // show, on the narrowest pane in the app. A pointer has no swipe and pays
    // nothing for chrome it only sees on hover, so desktop keeps the buttons.
    final showRowButtons = !isMobilePlatform;
    final hasActions =
        showRowButtons &&
        (onStagePath != null ||
            onUnstagePath != null ||
            onDiscardPath != null ||
            onResolvePath != null);
    // What the ROW HEIGHT has to reserve, which is a question about the tree
    // and not about this file: `hasActions` above is per-row, so floor-ing on
    // it would let a row's height report whether that one path happens to be
    // stageable. Touch mounts no buttons at all, and neither does a tree wired
    // without git callbacks (the Files tab) — neither should pay a button's
    // height on every row.
    final reservesButtons =
        showRowButtons &&
        (widget.onStage != null ||
            widget.onUnstage != null ||
            widget.onDiscard != null ||
            widget.onResolveConflict != null);
    // An OPEN directory carries no decoration of its own — in changesOnly mode
    // every directory left after pruning already implies a descendant changed,
    // so a dot on top of that is redundant noise. A folded one is the
    // exception: its rows are what the decoration would have been.
    final hasDecoration =
        (!isDirectory && widget.changeEntries.isNotEmpty) ||
        widget.rollupEntries.isNotEmpty;
    final showActions = hasActions && (_hovered || _focused);

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
        contentFloor: reservesButtons
            ? AbRowContentFloor.iconButton
            : AbRowContentFloor.none,
        onFocusChange: (v) {
          if (_focused != v && mounted) setState(() => _focused = v);
        },
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
        // Actions outermost, badge inboard: at rest the change count is the
        // only tenant and sits flush at the gutter on every row, so the column
        // it forms is what the eye scans. Only a revealed row's badge steps
        // inboard, and only while the row is revealed.
        trailing: (showActions || hasDecoration)
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (hasDecoration)
                    widget.rollupEntries.isNotEmpty
                        ? _FolderRollupBadge(entries: widget.rollupEntries)
                        : _DiffStatBadge(entries: widget.changeEntries),
                  if (showActions && hasDecoration)
                    const SizedBox(width: AbTokens.space4),
                  if (showActions)
                    Row(
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
                        if (onResolvePath != null)
                          AbIconButton(
                            icon: AbIcons.check,
                            onTap: onResolvePath,
                            tooltip: 'Mark Resolved',
                          ),
                      ],
                    ),
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
          // reversible one, never Revert. A conflicted row has only Resolve to
          // put there, and it is NOT reversible from this app: `git reset` on a
          // resolved path leaves a plain " M", it does not restore the unmerged
          // index stages (measured). That's why it confirms before firing.
          if (onResolvePath != null)
            AbSwipeAction(
              icon: AbIcons.check,
              label: 'Resolve',
              color: context.antgrid.success,
              onInvoke: onResolvePath,
            ),
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

/// The trailing badge for a FOLDED directory, standing in for every changed
/// file it is hiding.
///
/// A conflict below outranks the line counts, and takes the same danger dot a
/// conflicted FILE row carries: folding a folder is the one way a conflict
/// could leave the screen, and the fold has to say so in the row's own
/// vocabulary rather than hide it in a total.
class _FolderRollupBadge extends StatelessWidget {
  const _FolderRollupBadge({required this.entries});

  final List<GitFileStatusEntry> entries;

  @override
  Widget build(BuildContext context) {
    if (entries.any((e) => e.status == '!')) {
      return const AbStatusDot(tone: AbStatusTone.danger);
    }
    var additions = 0;
    var deletions = 0;
    for (final e in entries) {
      additions += e.additions;
      deletions += e.deletions;
    }
    if (additions == 0 && deletions == 0) {
      // Renames and mode-only changes all the way down: there is nothing to
      // count, but the folder is still holding rows shut, so it says how many.
      return Text(
        '${entries.length}',
        style: AbTokens.monoStyle(
          fontSize: AbTokens.fontXs,
          color: context.antgrid.textMuted,
        ),
      );
    }
    return AbDiffStat(additions: additions, deletions: deletions);
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
