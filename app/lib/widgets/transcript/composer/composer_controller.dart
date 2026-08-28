import 'package:fleather/fleather.dart';
import 'package:flutter/widgets.dart';
import 'package:parchment/codecs.dart';

import '../../../util/ab_log.dart';

/// Adapter around [FleatherController] exposing exactly what the transcript
/// composer needs. Fleather stays an implementation detail of the composer
/// module — the transcript view never imports fleather directly.
class ComposerController extends ChangeNotifier {
  ComposerController({ParchmentDocument? document})
    : fleather = FleatherController(
        document: document,
        // Block-level shortcuts only (# - * 1. ``` > []); inline **bold**
        // etc. is out of scope for v1, links stay literal text.
        autoFormats: AutoFormats(autoFormats: [MarkdownLineShortcuts()]),
      ) {
    fleather.addListener(notifyListeners);
  }

  final FleatherController fleather;

  // '-' bullets to match what the user typed to trigger the format.
  static final _markdown = ParchmentMarkdownCodec(unorderedListToken: '-');

  bool get isEmpty => fleather.document.toPlainText().trim().isEmpty;

  /// First line's plain text plus the caret offset within it, or null when
  /// the selection is invalid or the caret sits past the first line. This is
  /// the slash-suggestion anchor — suggestions only ever apply to line 0.
  ({String text, int caret})? get firstLine {
    final sel = fleather.selection;
    // A range selection isn't a command-typing caret; don't offer suggestions
    // (and the anchor offset below would be meaningless for a range).
    if (!sel.isValid || !sel.isCollapsed) return null;
    final text = fleather.document.toPlainText();
    final newline = text.indexOf('\n');
    final end = newline < 0 ? text.length : newline;
    if (sel.baseOffset > end) return null;
    return (text: text.substring(0, end), caret: sel.baseOffset);
  }

  /// True when the caret's line carries no block or heading attribute — an
  /// unformatted paragraph. Drives both slash-suggestion eligibility and
  /// Smart-Enter (a formatted line continues on Enter instead of sending).
  bool get caretLineIsPlain {
    // Single getSelectionStyle() pass — this runs per keystroke via
    // _deriveSuggestions, so don't recompute it once per attribute.
    final style = fleather.getSelectionStyle();
    return style.get(ParchmentAttribute.block) == null &&
        style.get(ParchmentAttribute.heading) == null;
  }

  /// Markdown for submission. A formatting bug must never make the prompt
  /// un-sendable, so codec failures degrade to the raw plain text.
  String toMarkdown() {
    try {
      return _markdown.encode(fleather.document).trim();
    } catch (e) {
      // Degrade to plain text so a codec bug never blocks send, but surface it
      // in debug so the underlying document-state defect stays diagnosable
      // instead of silently recurring.
      AbLog.warn(
        'Composer',
        'markdown encode failed, sending plain text',
        fields: {'error': '$e'},
      );
      return fleather.document.toPlainText().trim();
    }
  }

  /// The @-mention token under the caret: offset of the '@' in the document's
  /// plain text plus the query typed after it. Null when the selection is
  /// invalid or non-collapsed, the caret line is formatted, whitespace sits
  /// between the '@' and the caret, or the '@' is not at line/doc start or
  /// preceded by whitespace (so emails like a@b never trigger).
  ({int start, String query})? get mentionToken {
    final sel = fleather.selection;
    if (!sel.isValid || !sel.isCollapsed) return null;
    if (!caretLineIsPlain) return null;
    final text = fleather.document.toPlainText();
    final caret = sel.baseOffset;
    if (caret <= 0 || caret > text.length) return null;
    for (var i = caret - 1; i >= 0; i--) {
      final ch = text[i];
      if (ch == ' ' || ch == '\t' || ch == '\n') return null;
      if (ch == '@') {
        if (i > 0) {
          final prev = text[i - 1];
          if (prev != ' ' && prev != '\t' && prev != '\n') return null;
        }
        return (start: i, query: text.substring(i + 1, caret));
      }
    }
    return null;
  }

  /// Replace the active mention token with `@<path> `, caret after the space.
  /// Recomputes [mentionToken] at call time (same pattern as [acceptCommand]
  /// re-reading [firstLine]) so a stale build-frame offset can never corrupt
  /// the document; no-op when no token is active. Replaces the WHOLE token —
  /// forward to the next whitespace, absorbing one trailing space like
  /// [acceptCommand] — so a mid-query accept leaves no suffix or double space.
  void acceptMention(String path) {
    final token = mentionToken;
    if (token == null) return;
    final text = fleather.document.toPlainText();
    var end = fleather.selection.baseOffset;
    while (end < text.length &&
        text[end] != ' ' &&
        text[end] != '\t' &&
        text[end] != '\n') {
      end++;
    }
    if (end < text.length && text[end] == ' ') end++;
    final head = '@$path ';
    fleather.replaceText(
      token.start,
      end - token.start,
      head,
      selection: TextSelection.collapsed(offset: token.start + head.length),
    );
  }

  /// Rewrite the first token to `/name ` (slash-suggestion accept),
  /// preserving anything after the token, caret placed after the space.
  void acceptCommand(String name) {
    final line = firstLine ?? (text: '', caret: 0);
    final firstSpace = line.text.indexOf(' ');
    // Replace token + its trailing space (if any); head re-adds the space.
    final replaceLen = firstSpace < 0 ? line.text.length : firstSpace + 1;
    final head = '/$name ';
    fleather.replaceText(
      0,
      replaceLen,
      head,
      selection: TextSelection.collapsed(offset: head.length),
    );
  }

  /// Appends [text] on its own line and leaves the caret on a fresh line
  /// under it — the landing point for content handed to the composer from
  /// elsewhere (a preview capture's source label), which the user then types
  /// their own message beneath rather than into the middle of.
  ///
  /// Appends rather than replaces: a draft already being typed is the user's,
  /// and a handoff arriving mid-sentence must not eat it.
  void appendText(String text) {
    final body = text.trim();
    if (body.isEmpty) return;
    // Parchment always keeps one trailing newline, so the last insertable
    // offset is one before the document length — inserting AT the length
    // would land past the document's own terminator.
    final end = fleather.document.length - 1;
    final insert = isEmpty ? '$body\n' : '\n$body\n';
    fleather.replaceText(
      end,
      0,
      insert,
      selection: TextSelection.collapsed(offset: end + insert.length),
    );
  }

  void clear() => fleather.clear();

  @override
  void dispose() {
    fleather.removeListener(notifyListeners);
    fleather.dispose();
    super.dispose();
  }
}
