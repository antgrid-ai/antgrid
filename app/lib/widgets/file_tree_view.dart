import 'package:flutter/material.dart';

import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/ab_colors.dart';
import 'git_status_color.dart';
import '../design/widgets/ab_empty_state.dart';
import '../design/widgets/ab_chip.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_tap_target.dart';
import '../models/file_tree_models.dart';

/// A widget that renders a file tree with expand/collapse, file selection,
/// directory-first sorting, and optional name filtering.
class FileTreeView extends StatelessWidget {
  final FileNode? root;
  final Set<String> expandedPaths;
  final String? selectedFilePath;
  final String? filterQuery;
  final Map<String, String> gitFileStatuses;
  final bool showChangedOnly;
  final void Function(String path) onToggleExpanded;
  final void Function(String path) onFileSelected;
  final void Function(String path)? onDiscard;

  const FileTreeView({
    super.key,
    required this.root,
    required this.expandedPaths,
    this.selectedFilePath,
    this.filterQuery,
    this.gitFileStatuses = const {},
    this.showChangedOnly = false,
    required this.onToggleExpanded,
    required this.onFileSelected,
    this.onDiscard,
  });

  @override
  Widget build(BuildContext context) {
    if (showChangedOnly) {
      return _buildChangedOnly(context);
    }

    if (root == null) {
      return const AbEmptyState(
        icon: AbIcons.folder,
        title: 'No files available',
      );
    }

    final flatList = _flattenVisibleNodes(root!, expandedPaths, filterQuery);

    if (flatList.isEmpty) {
      return const AbEmptyState(
        icon: AbIcons.search,
        title: 'No matching files',
      );
    }

    return ListView.builder(
      itemCount: flatList.length,
      itemBuilder: (context, index) {
        final (node, depth) = flatList[index];
        final gitStatus = gitFileStatuses[node.path];
        return _FileTreeRow(
          node: node,
          depth: depth,
          isExpanded: expandedPaths.contains(node.path),
          isSelected: node.path == selectedFilePath,
          gitStatus: gitStatus,
          onTap: () {
            if (node.type == FileNodeType.directory) {
              onToggleExpanded(node.path);
            } else {
              onFileSelected(node.path);
            }
          },
        );
      },
    );
  }

  Widget _buildChangedOnly(BuildContext context) {
    if (gitFileStatuses.isEmpty) {
      return const AbEmptyState(icon: AbIcons.check, title: 'No changed files');
    }

    final entries = gitFileStatuses.entries.toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AbTokens.space12,
            vertical: AbTokens.space8,
          ),
          child: Text(
            '${entries.length} changed file${entries.length == 1 ? '' : 's'}',
            style: AbTokens.monoStyle(
              fontWeight: FontWeight.w600,
              color: context.antgrid.textMuted,
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: entries.length,
            itemBuilder: (context, index) {
              final entry = entries[index];
              final path = entry.key;
              final status = entry.value;
              final lastSlash = path.lastIndexOf('/');
              final fileName = lastSlash >= 0
                  ? path.substring(lastSlash + 1)
                  : path;
              final dirPath = lastSlash >= 0
                  ? path.substring(0, lastSlash)
                  : '';

              return _ChangedFileRow(
                fileName: fileName,
                dirPath: dirPath,
                status: status,
                isSelected: path == selectedFilePath,
                onTap: () => onFileSelected(path),
                onDiscard: onDiscard == null ? null : () => onDiscard!(path),
              );
            },
          ),
        ),
      ],
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

class _FileTreeRow extends StatelessWidget {
  final FileNode node;
  final int depth;
  final bool isExpanded;
  final bool isSelected;
  final String? gitStatus;
  final VoidCallback onTap;

  const _FileTreeRow({
    required this.node,
    required this.depth,
    required this.isExpanded,
    required this.isSelected,
    this.gitStatus,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDirectory = node.type == FileNodeType.directory;

    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          color: isSelected ? context.antgrid.bgSurface : null,
          padding: EdgeInsets.only(
            left: AbTokens.space12 + (depth * AbTokens.space16),
            right: AbTokens.space8,
            top: AbTokens.space6,
            bottom: AbTokens.space6,
          ),
          child: Row(
            children: [
              if (isDirectory)
                Text(
                  isExpanded ? '\u25BC ' : '\u25B6 ',
                  style: TextStyle(
                    fontSize: AbTokens.fontXxs,
                    color: context.antgrid.textMuted,
                  ),
                )
              else
                const Text('  ', style: TextStyle(fontSize: AbTokens.fontXxs)),
              const SizedBox(width: AbTokens.space2),
              Expanded(
                child: Text(
                  node.name,
                  style: AbTokens.monoStyle(
                    fontSize: AbTokens.fontSm,
                    fontWeight: isDirectory
                        ? FontWeight.w500
                        : FontWeight.normal,
                    color: isSelected
                        ? context.antgrid.accent
                        : isDirectory
                        ? context.antgrid.textSecondary
                        : context.antgrid.textPrimary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (gitStatus != null) _GitBadge(status: gitStatus!),
            ],
          ),
        ),
      ),
    );
  }
}

class _GitBadge extends StatelessWidget {
  final String status;
  const _GitBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: AbTokens.space4),
      child: AbChip.label(
        label: status,
        color: gitStatusColor(context, status),
      ),
    );
  }
}

class _ChangedFileRow extends StatelessWidget {
  final String fileName;
  final String dirPath;
  final String status;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback? onDiscard;

  const _ChangedFileRow({
    required this.fileName,
    required this.dirPath,
    required this.status,
    required this.isSelected,
    required this.onTap,
    this.onDiscard,
  });

  @override
  Widget build(BuildContext context) {
    final badgeColor = gitStatusColor(context, status);

    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          color: isSelected ? context.antgrid.bgSurface : null,
          padding: const EdgeInsets.symmetric(
            horizontal: AbTokens.space12,
            vertical: AbTokens.space6,
          ),
          // A file row is tappable across its whole height, so the discard
          // glyph is inline chrome and must not set the row's height.
          child: AbCompactTapTargets(
            child: Row(
              children: [
                const SizedBox(width: AbTokens.space16),
                Expanded(
                  child: Row(
                    children: [
                      // File name has priority: inflexible, so it's laid out at
                      // full width first and the Expanded dir path below takes only
                      // the leftover (ellipsizing, then vanishing when there's no
                      // room). Only a name wider than the whole row can overflow.
                      Text(
                        fileName,
                        style: AbTokens.monoStyle(
                          fontSize: AbTokens.fontSm,
                          color: isSelected
                              ? context.antgrid.accent
                              : context.antgrid.textPrimary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(width: AbTokens.space8),
                      Expanded(
                        child: Text(
                          dirPath,
                          style: AbTokens.monoStyle(
                            fontSize: AbTokens.fontXxs,
                            color: context.antgrid.textMuted,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AbTokens.space8),
                Text(
                  status,
                  style: TextStyle(
                    fontFamily: AbTokens.fontSans,
                    fontFamilyFallback: AbTokens.fontSansFallbacks,
                    fontSize: AbTokens.fontXs,
                    fontWeight: FontWeight.w600,
                    color: badgeColor,
                  ),
                ),
                if (onDiscard != null) ...[
                  const SizedBox(width: AbTokens.space4),
                  AbIconButton(
                    icon: AbIcons.trash,
                    onTap: onDiscard,
                    tooltip: 'Discard changes',
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
