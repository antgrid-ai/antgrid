import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/ab_icons.dart';
import '../design/ab_status_tone.dart';
import '../design/ab_tokens.dart';
import '../design/ab_colors.dart';
import '../design/widgets/ab_diff_stat.dart';
import '../design/widgets/ab_disclosure_chevron.dart';
import '../design/widgets/ab_empty_state.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_list_row.dart';
import '../design/widgets/ab_loading.dart';
import '../design/widgets/ab_menu.dart';
import '../design/widgets/ab_status_dot.dart';
import '../design/widgets/ab_swipe_actions.dart';
import '../models/ab_message.dart' show GitFileStatusEntry;
import '../models/file_tree_models.dart';
import '../models/git_status_index.dart';
import '../util/detached.dart';
import '../utils/platform_utils.dart';
import 'copy_path.dart';

/// A widget that renders a file tree with expand/collapse, file selection,
/// and directory-first sorting. Name filtering is no longer this widget's
/// job — it moved to a bridge-backed `file:find` (subsequence match, not a
/// local substring pass over whatever this tree has loaded); the file
/// explorer swaps this whole widget out for a flat results list while a
/// filter query is active instead.
///
/// [gitStatus] is optional decoration: pass it (with
/// [onStage]/[onUnstage]/[onDiscard]/[onResolveConflict]) from the Git tab to
/// get a +N/-N diff-stat badge on changed files, a dot on one with nothing to
/// count, and stage/unstage/discard/resolve actions — hover-revealed icon
/// buttons on desktop, a swipe tray on touch, never both. The SAME tree the
/// Files tab renders, undecorated, when these are omitted.
///
/// [changesOnly] switches the tree to a flat list of the changed files alone,
/// each named by its file with its folder beside it. That list is built from
/// the change PATHS, not from [root] (see [_flattenChangesOnly]), so a
/// deletion gets an ordinary row like everything else and the list looks the
/// same whether or not the file tree has arrived yet.
///
/// [root] and [expandedPaths] are compared by identity between builds, and
/// the rows derived from them are reused while they are unchanged, so a
/// caller changes one by passing a new instance, never by editing it in
/// place. [gitStatus] is immutable, so its identity is exact.
class FileTreeView extends StatefulWidget {
  final FileNode? root;
  final Set<String> expandedPaths;
  final String? selectedFilePath;
  final GitStatusIndex? _gitStatus;
  GitStatusIndex get gitStatus => _gitStatus ?? GitStatusIndex.empty;

  /// A folder to mark and scroll to in place of [selectedFilePath] — what a
  /// terminal link to a directory reveals.
  final String? revealedDirectoryPath;
  final bool changesOnly;

  /// Builds a sliver for a [CustomScrollView] the caller owns instead of a
  /// list with its own scroll — how several lists share one scroll. The host
  /// then owns closing an open swipe tray when it scrolls, and the highlighted
  /// row is never scrolled to: sibling slivers can each hold a row for the same
  /// path (a partially staged file), and two reveals on one viewport fight.
  final bool sliver;
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
    GitStatusIndex? gitStatus,
    this.revealedDirectoryPath,
    this.changesOnly = false,
    this.sliver = false,
    required this.onToggleExpanded,
    required this.onFileSelected,
    this.onStage,
    this.onUnstage,
    this.onDiscard,
    this.onResolveConflict,
  }) : _gitStatus = gitStatus;

  @override
  State<FileTreeView> createState() => _FileTreeViewState();
}

class _FileTreeViewState extends State<FileTreeView> {
  final ScrollController _scrollController = ScrollController();

  // Reused across builds rather than per-row: only ever attached to whatever
  // is CURRENTLY at flat index 0 (to measure a row's height — every row in
  // one tree shares it, see [_FileTreeRow]'s doc) and to the currently
  // selected file's row (to jump straight to its element once built). A
  // GlobalKey moving to a new widget each build is the normal way to track
  // "whichever one is live right now" — Flutter reparents it, it doesn't
  // duplicate.
  final _measureKey = GlobalKey();
  final _selectedRowKey = GlobalKey();
  double? _rowExtent;
  List<_TreeRow> _lastFlatList = const [];

  // What [_lastFlatList] was built from. Changes-only rows come from the change
  // list and never from [FileTreeView.root], so a tree update must not rebuild
  // them. Null [_rowsChangesOnly] means nothing has been built yet.
  bool? _rowsChangesOnly;
  Object? _rowsTree;
  Set<String>? _rowsOpenSet;

  /// A target still owed a scroll. It waits for its row rather than being
  /// tried once: the ancestors `FileService` expands to reveal it load their
  /// children asynchronously, so on the frame the target changes its row is
  /// usually not in the list yet.
  String? _pendingReveal;

  String? get _highlightPath =>
      widget.revealedDirectoryPath ?? widget.selectedFilePath;

  @override
  void initState() {
    super.initState();
    // A link that switches to the Files tab can build this tree with its
    // target already set, so there is no change for didUpdateWidget to see.
    if (!widget.sliver) _pendingReveal = _highlightPath;
  }

  @override
  void didUpdateWidget(FileTreeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A newly opened file or revealed folder (terminal link, search result,
    // git "view file", …) should be scrolled into view, not just
    // expanded-and-hoped-visible. A re-select of the SAME target (e.g.
    // reopening from a dialog) isn't worth re-animating the scroll for.
    final target = _highlightPath;
    final previous =
        oldWidget.revealedDirectoryPath ?? oldWidget.selectedFilePath;
    if (target != previous && !widget.sliver) _pendingReveal = target;
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void reassemble() {
    super.reassemble();
    // Hot reload replaces the code the cached rows were derived with, not their
    // inputs.
    _rowsChangesOnly = null;
  }

  List<_TreeRow> _rows() {
    final changesOnly = widget.changesOnly;
    final Object? tree = changesOnly ? widget.gitStatus : widget.root;
    final openSet = changesOnly ? null : widget.expandedPaths;
    if (_rowsChangesOnly == changesOnly &&
        identical(_rowsTree, tree) &&
        identical(_rowsOpenSet, openSet)) {
      return _lastFlatList;
    }
    _rowsChangesOnly = changesOnly;
    _rowsTree = tree;
    _rowsOpenSet = openSet;
    return _lastFlatList = changesOnly
        ? _flattenChangesOnly(widget.gitStatus.byPath)
        : _flattenVisibleNodes(widget.root!, widget.expandedPaths);
  }

  void _revealSelected() {
    if (!mounted || !_scrollController.hasClients) return;
    final builtCtx = _selectedRowKey.currentContext;
    if (builtCtx != null) {
      Scrollable.ensureVisible(
        builtCtx,
        alignment: 0.5,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
      return;
    }
    // Not already built, so it's outside the viewport (+ cache extent) —
    // every row shares one height (see [_FileTreeRow]'s doc), so a row
    // measured anywhere gives an exact, not approximate, offset for any
    // index. Jump there directly, then let the now-built row correct for the
    // viewport's own height on a second pass.
    final extent = _rowExtent ?? _measureKey.currentContext?.size?.height;
    if (extent == null) return;
    _rowExtent = extent;
    final index = _lastFlatList.indexWhere(
      (entry) =>
          !entry.truncationNotice &&
          !entry.loadingNotice &&
          entry.node.path == _highlightPath,
    );
    if (index < 0) return;
    final position = _scrollController.position;
    final target = (index * extent - position.viewportDimension / 2).clamp(
      0.0,
      position.maxScrollExtent,
    );
    _scrollController.jumpTo(target);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _selectedRowKey.currentContext;
      if (ctx != null && mounted) {
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.5,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // [changesOnly] answers from [gitStatus] alone, nesting included, so
    // it has nothing to bail out of: the two arrive independently
    // (`git:status` is a push — `file_service.dart`'s `_handleGitStatus` —
    // while `root` waits on a lazy per-checkout tree hydration), and the Git
    // tab must render the same list either way.
    if (widget.root == null && !widget.changesOnly) {
      const empty = AbEmptyState(
        icon: AbIcons.folder,
        title: 'No files available',
      );
      return widget.sliver ? const SliverToBoxAdapter(child: empty) : empty;
    }

    final entriesByPath = widget.gitStatus.byPath;
    final flatList = _rows();
    final pending = _pendingReveal;
    if (pending != null &&
        flatList.any(
          (entry) =>
              !entry.truncationNotice &&
              !entry.loadingNotice &&
              entry.node.path == pending,
        )) {
      _pendingReveal = null;
      WidgetsBinding.instance.addPostFrameCallback((_) => _revealSelected());
    }

    if (flatList.isEmpty) {
      final empty = AbEmptyState(
        icon: widget.changesOnly ? AbIcons.check : AbIcons.folder,
        title: widget.changesOnly ? 'No changed files' : 'This folder is empty',
      );
      return widget.sliver ? SliverToBoxAdapter(child: empty) : empty;
    }

    if (widget.sliver) {
      return SliverList.builder(
        itemCount: flatList.length,
        itemBuilder: (context, index) =>
            _buildRow(flatList, entriesByPath, index),
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
        controller: _scrollController,
        itemCount: flatList.length,
        itemBuilder: (context, index) =>
            _buildRow(flatList, entriesByPath, index),
      ),
    );
  }

  Widget _buildRow(
    List<_TreeRow> flatList,
    Map<String, List<GitFileStatusEntry>> entriesByPath,
    int index,
  ) {
    final (:node, :depth, :truncationNotice, :loadingNotice, :folder) =
        flatList[index];
    if (truncationNotice) {
      return _TruncationRow(
        key: ValueKey(('truncated', node.path)),
        depth: depth,
      );
    }
    if (loadingNotice) {
      return _LoadingRow(key: ValueKey(('loading', node.path)), depth: depth);
    }
    final isDirectory = node.type == FileNodeType.directory;
    Widget row = _FileTreeRow(
      // Typed, because one path can produce two rows: replacing a file
      // with a directory of the same name leaves a deletion and an
      // addition that share it, and a bare path key would be a duplicate.
      key: ValueKey((node.path, node.type)),
      node: node,
      depth: depth,
      isExpanded: widget.expandedPaths.contains(node.path),
      isSelected: node.path == _highlightPath,
      changeEntries: entriesByPath[node.path] ?? const [],
      folder: folder,
      touchSized: widget.changesOnly,
      onTap: isDirectory
          ? () => widget.onToggleExpanded(node.path)
          : () => widget.onFileSelected(node.path),
      onStage: widget.onStage,
      onUnstage: widget.onUnstage,
      onDiscard: widget.onDiscard,
      onResolveConflict: widget.onResolveConflict,
    );
    if (index == 0) row = KeyedSubtree(key: _measureKey, child: row);
    // Matched on kind as well as path: a file replaced by a folder of
    // the same name yields two rows here, and a GlobalKey takes one.
    if (node.path == _highlightPath &&
        isDirectory == (widget.revealedDirectoryPath != null)) {
      row = KeyedSubtree(key: _selectedRowKey, child: row);
    }
    return row;
  }
}

/// One rendered row. A [truncationNotice] row stands in for the entries the
/// bridge did not send: it carries the directory that was CUT, at the depth
/// that directory's children occupy. A [loadingNotice] row stands in for a
/// directory whose `file:tree:children:request` is in flight — its own
/// [FileNode.childrenLoading] — at the depth its children will occupy once
/// the reply lands.
typedef _TreeRow = ({
  FileNode node,
  int depth,
  bool truncationNotice,
  bool loadingNotice,
  String? folder,
});

/// Flatten the tree into a list of rows for rendering.
List<_TreeRow> _flattenVisibleNodes(FileNode root, Set<String> expandedPaths) {
  final result = <_TreeRow>[];

  // Root node itself is the project directory; show its children at depth 0
  for (final child in root.children) {
    _flattenNormal(child, 0, expandedPaths, result);
  }
  // The root has no row of its own to hang this off, and it is the directory
  // the node budget cuts first on a wide repo.
  if (root.truncated) {
    result.add((
      node: root,
      depth: 0,
      truncationNotice: true,
      loadingNotice: false,
      folder: null,
    ));
  }

  return result;
}

void _flattenNormal(
  FileNode node,
  int depth,
  Set<String> expandedPaths,
  List<_TreeRow> result,
) {
  result.add((
    node: node,
    depth: depth,
    truncationNotice: false,
    loadingNotice: false,
    folder: null,
  ));

  if (node.type == FileNodeType.directory &&
      expandedPaths.contains(node.path)) {
    for (final child in node.children) {
      _flattenNormal(child, depth + 1, expandedPaths, result);
    }
    // A round trip is in flight and nothing has landed yet — existing
    // (possibly stale) children stay on screen above this row while it
    // waits; see FileService.toggleExpanded.
    if (node.childrenLoading && node.children.isEmpty) {
      result.add((
        node: node,
        depth: depth + 1,
        truncationNotice: false,
        loadingNotice: true,
        folder: null,
      ));
    }
    // After the children, where the missing ones would have been.
    if (node.truncated) {
      result.add((
        node: node,
        depth: depth + 1,
        truncationNotice: true,
        loadingNotice: false,
        folder: null,
      ));
    }
  }
}

/// The changed files as a flat list, one row per path, built from the change
/// PATHS alone — the file tree [FileTreeView.root] carries is deliberately not
/// consulted. It is built from disk, so a deleted file has no node in it; it
/// stops at the bridge's depth cap and ignore rules; and it arrives on its own
/// schedule while `git:status` is pushed, so it is routinely absent.
///
/// Conflicts sort to the FRONT, so a top-down read reaches every one first.
/// The rest go case-insensitively by path, which keeps a folder's files
/// together now that no folder row groups them.
///
/// Each row's path is the change path VERBATIM: a row looks its entries up by
/// that string and every action hands it straight back to git, and git's own
/// `dir/` for an untracked directory it did not walk into would not survive
/// being rebuilt from segments.
List<_TreeRow> _flattenChangesOnly(
  Map<String, List<GitFileStatusEntry>> entriesByPath,
) {
  final conflicted = {
    for (final MapEntry(:key, :value) in entriesByPath.entries)
      if (value.any((e) => e.status == '!')) key,
  };
  final paths = entriesByPath.keys.toList()
    ..sort((a, b) {
      final byConflict =
          (conflicted.contains(a) ? 0 : 1) - (conflicted.contains(b) ? 0 : 1);
      if (byConflict != 0) return byConflict;
      final byName = a.toLowerCase().compareTo(b.toLowerCase());
      // Case-only twins: lowercase first, as the Files tab orders them, and
      // never arrival order — the sort is not stable.
      return byName != 0 ? byName : b.compareTo(a);
    });
  return [
    for (final path in paths)
      // Empty segments dropped: a leading slash, and the trailing one git puts
      // on an untracked directory it did not walk into.
      if (path.split('/').where((s) => s.isNotEmpty).toList() case [
        ...final dirs,
        final name,
      ])
        (
          node: FileNode(name: name, path: path, type: FileNodeType.file),
          depth: 0,
          truncationNotice: false,
          loadingNotice: false,
          // Split here, once, rather than on every row build.
          folder: dirs.isEmpty ? null : dirs.join('/'),
        ),
  ];
}

/// Stands in for entries the bridge never sent. Its directory's listing stopped
/// at the walk's node budget or its depth cap, so what is above this row is a
/// prefix of that directory, not the whole of it — without a row saying so the
/// explorer renders a partial repo that looks complete.
///
/// No count: the bridge reports only THAT it cut, and deriving a number from
/// the entries it skipped would count the ignored ones it never intended to
/// send.
class _TruncationRow extends StatelessWidget {
  final int depth;

  const _TruncationRow({super.key, required this.depth});

  @override
  Widget build(BuildContext context) {
    return AbListRow(
      density: AbRowDensity.sm,
      leading: Padding(
        padding: EdgeInsets.only(left: depth * AbTokens.space16),
        child: Text(
          '\u22ef ',
          style: TextStyle(
            fontSize: AbTokens.fontXxs,
            color: context.antgrid.textMuted,
          ),
        ),
      ),
      // Sans, not the mono every other row uses: this is a notice about the
      // listing, not an entry in it.
      title: Text(
        'more items not shown',
        style: AbTokens.sansStyle(
          fontSize: AbTokens.fontXs,
          color: context.antgrid.textMuted,
        ),
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// Stands in for a directory whose `file:tree:children:request` has not
/// answered yet. Existing (possibly stale) children, if any, render above
/// this row rather than being cleared for the round trip — see
/// `FileService.toggleExpanded`.
class _LoadingRow extends StatelessWidget {
  final int depth;

  const _LoadingRow({super.key, required this.depth});

  @override
  Widget build(BuildContext context) {
    return AbListRow(
      density: AbRowDensity.sm,
      leading: Padding(
        padding: EdgeInsets.only(left: depth * AbTokens.space16),
        // Every other row's leading is TEXT at [AbTokens.fontXxs] and takes
        // its band from that face's metrics; a bare dot is a fixed 12px box,
        // which renders this row shorter than the ones around it. The blank
        // glyph reinstates the band from the same metrics rather than a
        // literal that only holds for one font — the equal-row-height rule
        // [_FileTreeViewState._revealSelected] multiplies by a row index.
        child: Stack(
          alignment: Alignment.center,
          children: [
            const Text(' ', style: TextStyle(fontSize: AbTokens.fontXxs)),
            AbLoadingDot(color: context.antgrid.textMuted),
          ],
        ),
      ),
      // Sans, not the mono every other row uses: this is a notice about the
      // listing, not an entry in it — same reasoning as [_TruncationRow].
      //
      // Strutted because the leading is a fixed-size DOT, not text: without
      // it the row's content band collapses to this title's own metrics and
      // the row renders a pixel shorter than every other one — which
      // [_FileTreeViewState._revealSelected] multiplies by the row index.
      title: Text(
        'Loading…',
        style: AbTokens.sansStyle(
          fontSize: AbTokens.fontXs,
          color: context.antgrid.textMuted,
        ),
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// One row of the tree.
///
/// The tree's trailing rule is COLLAPSE AND FLOOR, NO CELL: the git actions
/// are dropped from layout until the row is revealed, and the row's height is
/// anchored by [AbRowContentFloor] so mounting them shifts nothing. It takes
/// no shared trailing cell, unlike the drawer's rows — its outermost element
/// is a variable-width diff-stat badge inside a resizable pane, so there is no
/// fixed panel edge for a column to align against. Every row in one
/// [FileTreeView] therefore renders at the SAME height regardless of depth,
/// name length, or decoration — [_FileTreeViewState._revealSelected] leans on
/// that to jump straight to an off-screen row's exact offset from a single
/// measured row, with no per-row measurement pass.
class _FileTreeRow extends StatefulWidget {
  final FileNode node;
  final int depth;
  final bool isExpanded;
  final bool isSelected;
  final List<GitFileStatusEntry> changeEntries;

  /// In the flat changes list, the folder the file lives in, shown muted after
  /// its name: with no folder rows, it is the only thing telling two
  /// `main.dart`s apart.
  final String? folder;
  final VoidCallback? onTap;
  final void Function(String path)? onStage;
  final void Function(String path)? onUnstage;
  final void Function(String path)? onDiscard;
  final void Function(String path)? onResolveConflict;

  /// Floors the row at a touch target's height on a touch platform.
  final bool touchSized;

  const _FileTreeRow({
    super.key,
    required this.node,
    required this.depth,
    required this.isExpanded,
    required this.isSelected,
    this.changeEntries = const [],
    this.folder,
    this.touchSized = false,
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

  void _openMenuAt(Offset position) =>
      detached('FileTreeRow', 'row menu failed', () => _showMenu(position));

  /// The row's context menu: right-click on desktop, long-press on touch.
  /// The path is project-relative — what an agent prompt or a terminal in the
  /// checkout wants, and the one form a remote project can answer too.
  Future<void> _showMenu(Offset globalPosition) async {
    AbSwipeActions.closeAny();
    final action = await showAbMenu<String>(
      context: context,
      anchorRect: Rect.fromCenter(center: globalPosition, width: 1, height: 1),
      header: widget.node.name,
      entries: const [
        AbMenuItem(label: 'Copy path', icon: AbIcons.copy, value: 'path'),
      ],
    );
    if (!mounted || action == null) return;
    await copyPathWithToast(context, widget.node.path);
  }

  /// One span rather than two widgets, so the ellipsis eats the folder before
  /// it reaches the file name.
  Widget _title(BuildContext context, bool isDirectory) {
    final p = context.antgrid;
    final folder = widget.folder;
    return Text.rich(
      TextSpan(
        text: widget.node.name,
        children: [
          if (folder != null)
            TextSpan(
              text: '  $folder',
              style: AbTokens.monoStyle(
                fontSize: AbTokens.fontXs,
                fontWeight: FontWeight.normal,
                color: p.textMuted,
              ),
            ),
        ],
      ),
      style: AbTokens.monoStyle(
        fontSize: AbTokens.fontSm,
        fontWeight: isDirectory ? FontWeight.w500 : FontWeight.normal,
        color: widget.isSelected
            ? p.accent
            // Present only because includeIgnored asked for it — a
            // still-selected ignored row keeps reading as selected above
            // this, so the dim only applies once selection is ruled out.
            : widget.node.ignored
            ? p.textMuted
            : isDirectory
            ? p.textSecondary
            : p.textPrimary,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
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
    final hasDecoration = !isDirectory && widget.changeEntries.isNotEmpty;
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
          // An icon, not a `▶` glyph: Android's font fallback draws U+25B6 as
          // the colour emoji, so a collapsed folder's arrow turned yellow.
          child: isDirectory
              ? AbDisclosureChevron(expanded: widget.isExpanded)
              : const SizedBox(width: AbTokens.drawerLeadingSlot),
        ),
        title: _title(context, isDirectory),
        // Actions outermost, badge inboard: at rest the change count is the
        // only tenant and sits flush at the gutter on every row, so the column
        // it forms is what the eye scans. Only a revealed row's badge steps
        // inboard, and only while the row is revealed.
        trailing: (showActions || hasDecoration)
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (hasDecoration)
                    _DiffStatBadge(entries: widget.changeEntries),
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
    // A change row is a finger's swipe target on touch, and the dense desktop
    // height left little to land a swipe on without hitting its neighbour.
    if (isMobilePlatform && widget.touchSized) {
      row = ConstrainedBox(
        constraints: const BoxConstraints(minHeight: AbTokens.rowHeightLg),
        child: row,
      );
    }

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

    // A void gesture callback discards the future it starts — see
    // util/detached.dart.
    return GestureDetector(
      onSecondaryTapUp: (d) => _openMenuAt(d.globalPosition),
      onLongPressStart: isMobilePlatform
          ? (d) => _openMenuAt(d.globalPosition)
          : null,
      child: row,
    );
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
