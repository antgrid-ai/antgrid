import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../models/search_models.dart';

/// Content-search results as a tree: a file is a branch that folds, a match is
/// a leaf. Only for use inside an `AbCarbonScope`.
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
  late final ScrollController _scroll;

  // The flat rows depend only on the results list and which files are
  // collapsed, so a parent rebuild must not reallocate one item per match.
  List<_ResultRow> _rows = const [];
  Map<String, SearchFileGroup> _groups = const {};
  List<SearchFileGroup>? _rowsSource;
  int _collapseVersion = 0;
  int _rowsVersion = -1;

  @override
  void initState() {
    super.initState();
    // A tree has no PageStorageKey of its own to restore a scroll with, and a
    // list left for a file and returned to must come back where it was.
    final saved = PageStorage.maybeOf(context)?.readState(context);
    _scroll = ScrollController(initialScrollOffset: saved is double ? saved : 0)
      ..addListener(_saveOffset);
  }

  void _saveOffset() {
    if (!mounted || !_scroll.hasClients) return;
    PageStorage.maybeOf(context)?.writeState(context, _scroll.offset);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  void reassemble() {
    super.reassemble();
    _rowsSource = null;
  }

  List<_ResultRow> _flatRows() {
    if (identical(widget.results, _rowsSource) &&
        _rowsVersion == _collapseVersion) {
      return _rows;
    }
    final rows = <_ResultRow>[];
    final groups = <String, SearchFileGroup>{};
    for (final group in widget.results) {
      groups[group.path] = group;
      rows.add(_HeaderItem(group));
      if (_collapsedFiles.contains(group.path)) continue;
      for (var i = 0; i < group.matches.length; i++) {
        rows.add(_MatchItem(group, group.matches[i], i));
      }
    }
    _rowsSource = widget.results;
    _rowsVersion = _collapseVersion;
    _groups = groups;
    return _rows = rows;
  }

  void _toggle(String path) {
    setState(() {
      _collapseVersion++;
      if (!_collapsedFiles.remove(path)) _collapsedFiles.add(path);
    });
  }

  void _openMatch(String path, int index) {
    final match = _groups[path]?.matches[index];
    if (match == null) return;
    widget.onMatchTap(path, match.line, match.column);
  }

  @override
  Widget build(BuildContext context) {
    final rows = _flatRows();
    final highlightQuery = widget.caseSensitive
        ? widget.query
        : widget.query.toLowerCase();

    return CarbonTreeView(
      controller: _scroll,
      semanticLabel: 'Search results',
      itemCount: rows.length,
      itemBuilder: (context, index) => switch (rows[index]) {
        _HeaderItem(:final group) => CarbonTreeNodeData(
          id: ('file', group.path),
          label: group.path,
          semanticLabel: '${group.path}, ${group.matches.length} matches',
          isBranch: true,
          expanded: !_collapsedFiles.contains(group.path),
          content: _FileLabel(path: group.path),
          trailing: CarbonTag(
            label: '${group.matches.length}',
            size: CarbonTagSize.small,
          ),
        ),
        _MatchItem(:final group, :final match, :final index) =>
          CarbonTreeNodeData(
            id: ('match', group.path, index),
            label: match.lineContent,
            semanticLabel: 'Line ${match.line}: ${match.lineContent}',
            depth: 1,
            content: _MatchLine(
              match: match,
              query: widget.query,
              highlightQuery: highlightQuery,
              isRegex: widget.isRegex,
              caseSensitive: widget.caseSensitive,
            ),
          ),
      },
      onToggle: (id) {
        if (id case ('file', final String path)) _toggle(path);
      },
      onActivate: (id) {
        if (id case ('match', final String path, final int index)) {
          _openMatch(path, index);
        }
      },
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
  const _MatchItem(super.group, this.match, this.index);
  final SearchMatch match;

  /// Position within the group's matches; with the path it names the match.
  final int index;
}

/// The file's name with the folder it sits in beside it, muted: with matches
/// from many folders, the name alone does not say which file a row is.
class _FileLabel extends StatelessWidget {
  const _FileLabel({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final inherited = DefaultTextStyle.of(context).style;
    final slash = path.lastIndexOf('/');
    final name = slash < 0 ? path : path.substring(slash + 1);
    final folder = slash < 0 ? '' : path.substring(0, slash);
    final code = theme.typography.code;
    return Row(
      children: [
        Flexible(
          child: Text(
            name,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: code.copyWith(
              color: inherited.color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (folder.isNotEmpty) ...[
          const SizedBox(width: CarbonSpacing.spacing03),
          Flexible(
            child: Text(
              folder,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: code.copyWith(color: theme.colors.textPlaceholder),
            ),
          ),
        ],
      ],
    );
  }
}

class _MatchLine extends StatelessWidget {
  final SearchMatch match;
  final String query;

  /// [query] in the form lines are matched against (lowercased unless
  /// [caseSensitive]); passed in so it is computed once per list build, not
  /// once per row.
  final String highlightQuery;
  final bool isRegex;
  final bool caseSensitive;

  const _MatchLine({
    required this.match,
    required this.query,
    required this.highlightQuery,
    required this.isRegex,
    required this.caseSensitive,
  });

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final colors = theme.colors;
    final inherited = DefaultTextStyle.of(context).style;
    final base = theme.typography.code.copyWith(color: inherited.color);
    return Row(
      children: [
        SizedBox(
          width: CarbonSpacing.spacing09,
          child: Text(
            '${match.line}',
            style: base.copyWith(color: colors.textPlaceholder),
            textAlign: TextAlign.right,
            maxLines: 1,
          ),
        ),
        const SizedBox(width: CarbonSpacing.spacing03),
        Expanded(child: _highlighted(base, colors)),
      ],
    );
  }

  Widget _highlighted(TextStyle base, CarbonColors colors) {
    final line = match.lineContent;
    if (query.isEmpty || isRegex) {
      return Text(
        line,
        style: base,
        maxLines: 1,
        softWrap: false,
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
            backgroundColor: colors.highlight,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
      start = index + query.length;
    }

    return RichText(
      text: TextSpan(style: base, children: spans),
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
    );
  }
}
