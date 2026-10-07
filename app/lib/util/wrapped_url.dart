/// How far short of the right edge a row may stop and still count as wrapped.
/// Agent TUIs wrap inside their own margin (a gutter, a box rule), never
/// exactly at the terminal's last column.
const int _wrapEdgeSlack = 4;

final RegExp _urlContinuation = RegExp(r'''^[^\s<>"']+''');

/// Leading box-drawing rules and gutter glyphs a TUI repeats at the start of a
/// wrapped row, which are not part of the URL it continues.
final RegExp _rowGutter = RegExp(r'^[\s│┃|]*');

/// Rejoins a URL that an agent TUI HARD-wrapped across rows.
///
/// Ink-based CLIs (Claude Code, Codex) break a long word at their own width by
/// writing a newline, not by letting the terminal soft-wrap, so the terminal
/// sees two lines and link detection stops at the first — on a phone-width
/// pane that is usually right before the query string or fragment. When [uri]
/// ends a row that reaches the wrap edge of a [cols]-wide terminal, the URL
/// characters that open each following row are appended, for as long as those
/// rows also run to the edge.
///
/// Returns [uri] unchanged when it is not found at the end of a full row: a
/// short line ending in a URL is a finished URL, and the next line is prose.
String extendWrappedUrl(String uri, List<String> lines, int cols) {
  if (uri.isEmpty || cols <= _wrapEdgeSlack) return uri;
  bool reachesEdge(String row) {
    final len = row.trimRight().length;
    return len >= cols - _wrapEdgeSlack && len <= cols;
  }

  for (var i = lines.length - 1; i >= 0; i--) {
    final row = lines[i].trimRight();
    if (!row.endsWith(uri) || !reachesEdge(row)) continue;
    final buffer = StringBuffer(uri);
    var next = i + 1;
    while (next < lines.length) {
      final rest = lines[next].replaceFirst(_rowGutter, '');
      final match = _urlContinuation.firstMatch(rest);
      if (match == null) break;
      final piece = match.group(0)!;
      // A continuation that starts its own scheme is a second URL.
      if (piece.contains('://')) break;
      buffer.write(piece);
      // Only a row the continuation fills to the edge can wrap again.
      if (piece.length != rest.trimRight().length ||
          !reachesEdge(lines[next])) {
        break;
      }
      next++;
    }
    return _trimSentencePunctuation(buffer.toString());
  }
  return uri;
}

/// Drops the punctuation a sentence leaves after a URL. A closing parenthesis
/// counts only while it is unmatched: `Foo_(bar)` is a common path shape, and
/// stripping its `)` sends the reader to a page that does not exist.
String _trimSentencePunctuation(String url) {
  var end = url.length;
  while (end > 0) {
    final ch = url[end - 1];
    if (ch == ')') {
      final head = url.substring(0, end);
      final closers = ')'.allMatches(head).length;
      final openers = '('.allMatches(head).length;
      if (closers <= openers) break;
    } else if (!'.,;:!?'.contains(ch)) {
      break;
    }
    end--;
  }
  return url.substring(0, end);
}
