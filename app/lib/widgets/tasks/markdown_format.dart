import 'package:flutter/services.dart';

/// Toolbar edits for a markdown source field, as pure [TextEditingValue]
/// transforms so the toolbar, the keyboard shortcuts and the tests all share
/// one implementation.
///
/// Markdown source rather than a WYSIWYG document on purpose: a task body
/// round-trips to a GitHub issue, and anything a rich-text model cannot
/// represent (HTML comments in issue templates, tables, footnotes) would be
/// silently rewritten on the first save and pushed back to GitHub.
abstract final class MarkdownFormat {
  /// Wraps the selection in [marker] (`**`, `_`, `~~`, `` ` ``), or unwraps it
  /// when it is already wrapped. With nothing selected it inserts the pair
  /// around [placeholder] and selects the placeholder so typing replaces it.
  static TextEditingValue wrap(
    TextEditingValue value,
    String marker, {
    String placeholder = 'text',
  }) {
    final text = value.text;
    final sel = _normalized(value);
    var start = sel.start;
    var end = sel.end;
    // Markers must hug the text: `**word **` is not emphasis in any markdown
    // flavour and renders as literal asterisks. A double-click or a drag picks
    // up an edge space easily, so the space stays outside the markers.
    while (start < end && _isSpace(text[start])) {
      start++;
    }
    while (end > start && _isSpace(text[end - 1])) {
      end--;
    }
    final selection = text.substring(start, end);
    if (selection.length >= marker.length * 2 &&
        selection.startsWith(marker) &&
        selection.endsWith(marker)) {
      final inner = selection.substring(
        marker.length,
        selection.length - marker.length,
      );
      return TextEditingValue(
        text: text.replaceRange(start, end, inner),
        selection: TextSelection(
          baseOffset: start,
          extentOffset: start + inner.length,
        ),
      );
    }

    final before = start >= marker.length
        ? text.substring(start - marker.length, start)
        : '';
    final after = end + marker.length <= text.length
        ? text.substring(end, end + marker.length)
        : '';
    if (before == marker && after == marker) {
      final next = text.replaceRange(end, end + marker.length, '');
      return TextEditingValue(
        text: next.replaceRange(start - marker.length, start, ''),
        selection: TextSelection(
          baseOffset: start - marker.length,
          extentOffset: end - marker.length,
        ),
      );
    }

    final inner = start == end ? placeholder : selection;
    return TextEditingValue(
      text: text.replaceRange(start, end, '$marker$inner$marker'),
      selection: TextSelection(
        baseOffset: start + marker.length,
        extentOffset: start + marker.length + inner.length,
      ),
    );
  }

  /// Inline code for a selection on one line, a fenced block for one that
  /// spans lines — the same split GitHub's own toolbar makes.
  static TextEditingValue code(TextEditingValue value) {
    final sel = _normalized(value);
    final selected = value.text.substring(sel.start, sel.end);
    if (!selected.contains('\n')) return wrap(value, '`', placeholder: 'code');
    final text = value.text;
    final lead = sel.start == 0 || text[sel.start - 1] == '\n' ? '' : '\n';
    final block = '$lead```\n$selected\n```';
    return TextEditingValue(
      text: text.replaceRange(sel.start, sel.end, block),
      selection: TextSelection(
        baseOffset: sel.start + lead.length + 4,
        extentOffset: sel.start + lead.length + 4 + selected.length,
      ),
    );
  }

  /// `[selection](url)` with `url` selected, ready to be pasted over.
  static TextEditingValue link(TextEditingValue value) {
    final sel = _normalized(value);
    final text = value.text;
    final label = sel.isCollapsed ? 'text' : text.substring(sel.start, sel.end);
    const url = 'url';
    final inserted = '[$label]($url)';
    final urlStart = sel.start + label.length + 3;
    return TextEditingValue(
      text: text.replaceRange(sel.start, sel.end, inserted),
      selection: sel.isCollapsed
          ? TextSelection(
              baseOffset: sel.start + 1,
              extentOffset: sel.start + 1 + label.length,
            )
          : TextSelection(
              baseOffset: urlStart,
              extentOffset: urlStart + url.length,
            ),
    );
  }

  /// Prefixes every line the selection touches with [prefix] (`# `, `> `,
  /// `- `, `- [ ] `), or strips it when every one of them already has it.
  /// [numbered] writes `1. `, `2. `, … instead of a fixed prefix.
  static TextEditingValue linePrefix(
    TextEditingValue value,
    String prefix, {
    bool numbered = false,
  }) {
    final text = value.text;
    final sel = _normalized(value);
    final blockStart = sel.start == 0
        ? 0
        : text.lastIndexOf('\n', sel.start - 1) + 1;
    var blockEnd = text.indexOf('\n', sel.end);
    if (blockEnd == -1) blockEnd = text.length;
    final lines = text.substring(blockStart, blockEnd).split('\n');

    final numberedPattern = RegExp(r'^\d+\. ');
    bool has(String line) =>
        numbered ? numberedPattern.hasMatch(line) : line.startsWith(prefix);
    final removing = lines.every(has);

    final next = <String>[
      for (var i = 0; i < lines.length; i++)
        removing
            ? lines[i].replaceFirst(
                numbered ? numberedPattern : RegExp(RegExp.escape(prefix)),
                '',
              )
            : '${numbered ? '${i + 1}. ' : prefix}${lines[i]}',
    ];
    final replaced = next.join('\n');
    final delta = replaced.length - (blockEnd - blockStart);
    final firstDelta = next.first.length - lines.first.length;
    final nextText = text.replaceRange(blockStart, blockEnd, replaced);
    return TextEditingValue(
      text: nextText,
      selection: sel.isCollapsed
          ? TextSelection.collapsed(
              offset: (sel.start + firstDelta).clamp(
                blockStart,
                nextText.length,
              ),
            )
          : TextSelection(
              baseOffset: blockStart,
              extentOffset: blockEnd + delta,
            ),
    );
  }

  /// Flips the [index]th task-list box in [source] (`[ ]` ↔ `[x]`), counting
  /// in document order, or null when there is no such box.
  ///
  /// A rendered box knows only its position among the boxes, so this must
  /// count exactly the boxes the renderer draws: fenced code is skipped, since
  /// a `- [ ]` inside a fence is text, not a box, and so are HTML comments,
  /// which are never rendered as markdown (see [splitComments]).
  static String? toggleTask(String source, int index) {
    final at = _taskBoxes(source).elementAtOrNull(index);
    if (at == null) return null;
    final flipped = source[at] == ' ' ? 'x' : ' ';
    return source.replaceRange(at, at + 1, flipped);
  }

  /// How many boxes [toggleTask] can reach in [source].
  static int taskCount(String source) => _taskBoxes(source).length;

  /// Offsets of each box's mark character, in document order.
  static List<int> _taskBoxes(String source) {
    // Same length as [source], so an offset found here is one there.
    final masked = _maskComments(source);
    final boxes = <int>[];
    var offset = 0;
    String? fence;
    for (final line in masked.split('\n')) {
      final fenceMatch = _fence.firstMatch(line);
      if (fenceMatch != null) {
        final marker = fenceMatch.group(1)!;
        if (fence == null) {
          fence = marker;
        } else if (marker[0] == fence[0] && marker.length >= fence.length) {
          fence = null;
        }
      } else if (fence == null) {
        final task = _taskItem.firstMatch(line);
        if (task != null) boxes.add(offset + task.group(1)!.length + 1);
      }
      offset += line.length + 1;
    }
    return boxes;
  }

  /// [source] cut into prose and the HTML comments between it, in order.
  ///
  /// Issue templates carry their guidance as `<!-- -->` comments, which
  /// GitHub hides; rendered as markdown they show up as raw markup. A comment
  /// inside fenced code is code, not guidance, and stays in its prose. An
  /// unterminated comment runs to the end, as it does in HTML.
  static List<MarkdownSegment> splitComments(String source) {
    final segments = <MarkdownSegment>[];
    var from = 0;
    for (final (start, end) in _commentRanges(source)) {
      if (start > from) {
        segments.add(MarkdownSegment(source.substring(from, start)));
      }
      final inner = source.substring(start + 4, end);
      segments.add(
        MarkdownSegment(
          (inner.endsWith('-->') ? inner.substring(0, inner.length - 3) : inner)
              .trim(),
          isComment: true,
        ),
      );
      from = end;
    }
    if (from < source.length) {
      segments.add(MarkdownSegment(source.substring(from)));
    }
    return segments;
  }

  static String _maskComments(String source) {
    final ranges = _commentRanges(source);
    if (ranges.isEmpty) return source;
    final out = StringBuffer();
    var from = 0;
    for (final (start, end) in ranges) {
      out.write(source.substring(from, start));
      out.write(source.substring(start, end).replaceAll(RegExp(r'[^\n]'), ' '));
      from = end;
    }
    out.write(source.substring(from));
    return out.toString();
  }

  /// `[start, end)` of each `<!-- … -->` outside fenced code.
  static List<(int, int)> _commentRanges(String source) {
    final ranges = <(int, int)>[];
    var offset = 0;
    int? open;
    String? fence;
    for (final line in source.split('\n')) {
      if (open == null) {
        final fenceMatch = _fence.firstMatch(line);
        if (fenceMatch != null) {
          final marker = fenceMatch.group(1)!;
          if (fence == null) {
            fence = marker;
          } else if (marker[0] == fence[0] && marker.length >= fence.length) {
            fence = null;
          }
          offset += line.length + 1;
          continue;
        }
      }
      if (fence == null) {
        var i = 0;
        while (true) {
          if (open == null) {
            final at = line.indexOf('<!--', i);
            if (at < 0) break;
            open = offset + at;
            i = at + 4;
          } else {
            final at = line.indexOf('-->', i);
            if (at < 0) break;
            ranges.add((open, offset + at + 3));
            open = null;
            i = at + 3;
          }
        }
      }
      offset += line.length + 1;
    }
    if (open != null) ranges.add((open, source.length));
    return ranges;
  }

  static final _fence = RegExp(r'^ {0,3}(`{3,}|~{3,})');

  /// A list item — bullet or ordered, optionally inside block quotes — whose
  /// text opens with a box. Group 1 ends right before the `[`.
  static final _taskItem = RegExp(
    r'^((?:\s*>)*\s*(?:[-*+]|\d{1,9}[.)])\s+)\[[ xX]\](?=\s|$)',
  );

  static bool _isSpace(String c) => c.trim().isEmpty;

  /// A selection the field has never placed (offset -1) reads as a caret at
  /// the end, which is where a toolbar click on an untouched field should act.
  static TextSelection _normalized(TextEditingValue value) {
    final sel = value.selection;
    if (!sel.isValid) return TextSelection.collapsed(offset: value.text.length);
    return TextSelection(baseOffset: sel.start, extentOffset: sel.end);
  }
}

/// One run of a markdown source: prose, or the text of an HTML comment.
class MarkdownSegment {
  const MarkdownSegment(this.text, {this.isComment = false});

  final String text;
  final bool isComment;
}
