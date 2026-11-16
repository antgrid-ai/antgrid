import 'dart:math' as math;

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../models/file_tree_models.dart';
import '../util/detached.dart';
import 'carbon_empty_state.dart';
import 'copy_path.dart';

/// A widget that renders a file tree with expand/collapse, file selection,
/// and directory-first sorting. Name filtering is no longer this widget's
/// job — it moved to a bridge-backed `file:find` (subsequence match, not a
/// local substring pass over whatever this tree has loaded); the file
/// explorer swaps this whole widget out for a flat results list while a
/// filter query is active instead.
///
/// Only for use inside an `AbCarbonScope`.
///
/// [root] and [expandedPaths] are compared by identity between builds, and
/// the rows derived from them are reused while they are unchanged, so a
/// caller changes one by passing a new instance, never by editing it in
/// place.
class FileTreeView extends StatefulWidget {
  final FileNode? root;
  final Set<String> expandedPaths;
  final String? selectedFilePath;

  /// A folder to mark and scroll to in place of [selectedFilePath] — what a
  /// terminal link to a directory reveals.
  final String? revealedDirectoryPath;
  final void Function(String path) onToggleExpanded;
  final void Function(String path) onFileSelected;

  const FileTreeView({
    super.key,
    required this.root,
    required this.expandedPaths,
    this.selectedFilePath,
    this.revealedDirectoryPath,
    required this.onToggleExpanded,
    required this.onFileSelected,
  });

  @override
  State<FileTreeView> createState() => _FileTreeViewState();
}

class _FileTreeViewState extends State<FileTreeView> {
  final ScrollController _scrollController = ScrollController();
  List<_TreeRow> _lastFlatList = const [];
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
    _pendingReveal = _highlightPath;
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
    if (target != previous) _pendingReveal = target;
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
    _rowsTree = null;
  }

  List<_TreeRow> _rows() {
    final tree = widget.root;
    final openSet = widget.expandedPaths;
    if (identical(_rowsTree, tree) && identical(_rowsOpenSet, openSet)) {
      return _lastFlatList;
    }
    _rowsTree = tree;
    _rowsOpenSet = openSet;
    return _lastFlatList = _flattenVisibleNodes(tree!, openSet);
  }

  /// Every row is exactly [CarbonTreeView.rowExtentOf] tall, notices and
  /// loading rows included, so a row's offset is its index times that and
  /// nothing has to be measured.
  void _revealSelected() {
    if (!mounted || !_scrollController.hasClients) return;
    final index = _lastFlatList.indexWhere(
      (entry) =>
          !entry.truncationNotice &&
          !entry.loadingNotice &&
          entry.node.path == _highlightPath,
    );
    if (index < 0) return;
    final extent = CarbonTreeView.rowExtentOf(context);
    final position = _scrollController.position;
    // Bounded by the rows' own extent, not position.maxScrollExtent: on the
    // frame a lazily loaded folder's rows arrive, the lazy sliver has not yet
    // re-measured, so the position still reports the shorter list and the
    // target would stop a row short of a file at the end.
    final listEnd = _lastFlatList.length * extent - position.viewportDimension;
    final target = (index * extent + extent / 2 - position.viewportDimension / 2)
        .clamp(position.minScrollExtent, math.max(position.minScrollExtent, listEnd))
        .toDouble();
    // A far target is jumped to: animating across thousands of rows is wasted
    // motion, and only the rows near the end of it would be seen anyway.
    if ((target - position.pixels).abs() > position.viewportDimension) {
      _scrollController.jumpTo(target);
    } else {
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.root == null) {
      return const CarbonEmptyState(
        icon: CarbonIcons.folder,
        heading: 'No files available',
      );
    }

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
      return const CarbonEmptyState(
        icon: CarbonIcons.folder,
        heading: 'This folder is empty',
      );
    }

    return CarbonTreeView(
      controller: _scrollController,
      semanticLabel: 'File tree',
      itemCount: flatList.length,
      itemBuilder: (context, index) => _describe(context, flatList[index]),
      onToggle: (id) {
        if (_pathOf(id) case final path?) widget.onToggleExpanded(path);
      },
      onActivate: (id) {
        if (_pathOf(id) case final path?) widget.onFileSelected(path);
      },
    );
  }

  /// The path behind a real row's id; notice rows carry a string tag in its
  /// place and are never interactive.
  static String? _pathOf(Object id) =>
      id is (String, FileNodeType) ? id.$1 : null;

  CarbonTreeNodeData _describe(BuildContext context, _TreeRow row) {
    final (:node, :depth, :truncationNotice, :loadingNotice) = row;
    if (truncationNotice) {
      return CarbonTreeNodeData(
        id: ('truncated', node.path),
        label: 'more items not shown',
        depth: depth,
        interactive: false,
        leading: const CarbonIcon(CarbonIcons.overflowMenuHorizontal),
      );
    }
    if (loadingNotice) {
      return CarbonTreeNodeData(
        id: ('loading', node.path),
        label: 'Loading…',
        depth: depth,
        interactive: false,
        leading: const CarbonSpinner(size: 12),
      );
    }
    final isDirectory = node.type == FileNodeType.directory;
    final highlighted = node.path == _highlightPath;
    return CarbonTreeNodeData(
      // Typed, because one path can produce two rows: replacing a file
      // with a directory of the same name leaves a deletion and an
      // addition that share it, and a bare path id would be a duplicate.
      id: (node.path, node.type),
      label: node.name,
      depth: depth,
      isBranch: isDirectory,
      expanded: widget.expandedPaths.contains(node.path),
      selected: highlighted,
      active: highlighted && !isDirectory,
      content: _RowLabel(node: node, highlighted: highlighted),
    );
  }
}

/// A row's name, in the mono face every path in the app uses, with the
/// copy-path menu on right-click and touch long-press.
class _RowLabel extends StatelessWidget {
  const _RowLabel({required this.node, required this.highlighted});

  final FileNode node;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final inherited = DefaultTextStyle.of(context).style;
    return CarbonContextMenu(
      entries: [
        CarbonMenuItem(
          label: 'Copy path',
          icon: const CarbonIcon(CarbonIcons.copy),
          // The path is project-relative — what an agent prompt or a terminal
          // in the checkout wants, and the one form a remote project can
          // answer too.
          onPressed: () => detached('FileTreeRow', 'copy path failed', () async {
            if (!context.mounted) return;
            await copyPathWithToast(context, node.path);
          }),
        ),
      ],
      child: LayoutBuilder(
        builder: (context, constraints) {
          final style = inherited.merge(
            theme.typography.code.copyWith(
              // An ignored row dims, unless it is the open one: selection
              // outranks the dim.
              color: node.ignored && !highlighted
                  ? theme.colors.textPlaceholder
                  : inherited.color,
              fontWeight: inherited.fontWeight,
            ),
          );
          // Deep siblings sharing a prefix (drawable-mdpi, drawable-night…)
          // ellipsize to identical rows, so a cut name carries its whole
          // self on hover. Not on touch, where a long press already opens
          // the copy-path menu.
          final clipped =
              !theme.isTouch &&
              _overflows(context, node.name, style, constraints.maxWidth);
          return CarbonTooltip(
            message: node.name,
            enabled: clipped,
            // The row is already announced by its name.
            excludeFromSemantics: true,
            child: Text(
              node.name,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          );
        },
      ),
    );
  }
}

bool _overflows(
  BuildContext context,
  String text,
  TextStyle style,
  double maxWidth,
) {
  if (!maxWidth.isFinite) return false;
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: Directionality.maybeOf(context) ?? TextDirection.ltr,
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout(maxWidth: maxWidth);
  final overflows = painter.didExceedMaxLines;
  painter.dispose();
  return overflows;
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
      ));
    }
    // After the children, where the missing ones would have been. Its
    // listing stopped at the walk's node budget or its depth cap, so what is
    // above is a prefix of that directory; without a row saying so the
    // explorer renders a partial repo that looks complete.
    if (node.truncated) {
      result.add((
        node: node,
        depth: depth + 1,
        truncationNotice: true,
        loadingNotice: false,
      ));
    }
  }
}
