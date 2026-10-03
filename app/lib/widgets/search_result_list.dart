import 'package:flutter/material.dart';

import '../design/ab_tokens.dart';
import '../design/ab_colors.dart';
import '../models/search_models.dart';

class SearchResultList extends StatefulWidget {
  final List<SearchFileGroup> results;
  final String query;
  final bool isRegex;
  final bool caseSensitive;
  final void Function(String path, int line, int column) onMatchTap;

  const SearchResultList({
    super.key,
    required this.results,
    required this.query,
    required this.isRegex,
    this.caseSensitive = false,
    required this.onMatchTap,
  });

  @override
  State<SearchResultList> createState() => _SearchResultListState();
}

class _SearchResultListState extends State<SearchResultList> {
  final Set<String> _collapsedFiles = {};

  @override
  Widget build(BuildContext context) {
    final rows = <_ResultRow>[];
    for (final group in widget.results) {
      rows.add(_HeaderItem(group));
      if (_collapsedFiles.contains(group.path)) continue;
      for (final match in group.matches) {
        rows.add(_MatchItem(group, match));
      }
    }
    final highlightQuery = widget.caseSensitive
        ? widget.query
        : widget.query.toLowerCase();

    return ListView.builder(
      key: const PageStorageKey('search_results'),
      itemCount: rows.length,
      itemBuilder: (context, index) => switch (rows[index]) {
        _HeaderItem(:final group) => _buildFileHeader(context, group),
        _MatchItem(:final group, :final match) => _MatchRow(
          match: match,
          query: widget.query,
          highlightQuery: highlightQuery,
          isRegex: widget.isRegex,
          caseSensitive: widget.caseSensitive,
          filePath: group.path,
          onTap: () => widget.onMatchTap(group.path, match.line, match.column),
        ),
      },
    );
  }

  Widget _buildFileHeader(BuildContext context, SearchFileGroup group) {
    final isCollapsed = _collapsedFiles.contains(group.path);
    return GestureDetector(
      onTap: () {
        setState(() {
          if (isCollapsed) {
            _collapsedFiles.remove(group.path);
          } else {
            _collapsedFiles.add(group.path);
          }
        });
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AbTokens.space12,
            vertical: AbTokens.space6,
          ),
          color: context.antgrid.bgDeep,
          child: Row(
            children: [
              Text(
                isCollapsed ? '\u25B6' : '\u25BC',
                style: TextStyle(
                  fontSize: AbTokens.fontXxs,
                  color: context.antgrid.iconMuted,
                ),
              ),
              const SizedBox(width: AbTokens.space6),
              Expanded(
                child: Text(
                  group.path,
                  style: AbTokens.monoStyle(
                    fontWeight: FontWeight.w600,
                    color: context.antgrid.textSecondary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AbTokens.space6,
                  vertical: 1,
                ), // 1px badge inset
                decoration: BoxDecoration(
                  color: context.antgrid.bgElevated,
                  borderRadius: AbTokens.borderRadius3,
                ),
                child: Text(
                  '${group.matches.length}',
                  style: AbTokens.monoStyle(
                    fontSize: AbTokens.fontXxs,
                    color: context.antgrid.textMuted,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Flat so the list builds only the rows on screen; holding a file's rows in
/// one item would build and lay out every one of them, off-screen rows
/// included.
sealed class _ResultRow {
  const _ResultRow(this.group);
  final SearchFileGroup group;
}

class _HeaderItem extends _ResultRow {
  const _HeaderItem(super.group);
}

class _MatchItem extends _ResultRow {
  const _MatchItem(super.group, this.match);
  final SearchMatch match;
}

class _MatchRow extends StatelessWidget {
  final SearchMatch match;
  final String query;

  /// [query] in the form lines are matched against (lowercased unless
  /// [caseSensitive]); passed in so it is computed once per list build, not
  /// once per row.
  final String highlightQuery;
  final bool isRegex;
  final bool caseSensitive;
  final String filePath;
  final VoidCallback onTap;

  const _MatchRow({
    required this.match,
    required this.query,
    required this.highlightQuery,
    required this.isRegex,
    this.caseSensitive = false,
    required this.filePath,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AbTokens.space12,
            vertical: 3,
          ), // 3px row inset
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 48,
                child: Text(
                  '${match.line}',
                  style: AbTokens.monoStyle(color: context.antgrid.textMuted),
                  textAlign: TextAlign.right,
                ),
              ),
              const SizedBox(width: AbTokens.space8),
              Expanded(
                child: _buildHighlightedLine(context, match.lineContent),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHighlightedLine(BuildContext context, String line) {
    final baseStyle = AbTokens.monoStyle();

    if (query.isEmpty || isRegex) {
      return Text(
        line,
        style: baseStyle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }

    final searchLine = caseSensitive ? line : line.toLowerCase();
    final spans = <TextSpan>[];
    int start = 0;

    while (start < line.length) {
      final index = searchLine.indexOf(highlightQuery, start);
      if (index == -1) {
        spans.add(TextSpan(text: line.substring(start)));
        break;
      }
      if (index > start) {
        spans.add(TextSpan(text: line.substring(start, index)));
      }
      spans.add(
        TextSpan(
          text: line.substring(index, index + query.length),
          style: TextStyle(
            backgroundColor: context.antgrid.accent.withValues(alpha: 0.3),
            fontWeight: FontWeight.w700,
            color: context.antgrid.accent,
          ),
        ),
      );
      start = index + query.length;
    }

    return RichText(
      text: TextSpan(style: baseStyle, children: spans),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}
