import 'dart:convert';

import 'block_source.dart';

/// The three built copy representations of the current selection.
class CopyOutput {
  final String plain;
  final String markdown;
  final String html;
  const CopyOutput({
    required this.plain,
    required this.markdown,
    required this.html,
  });
}

/// One touched block (its local range is only used upstream to decide the block
/// was touched at all; the copy output never slices it — see [resolveCopy]).
class BlockSelection {
  final BlockSource source;
  final int order;
  const BlockSelection({required this.source, required this.order});
}

/// Plain output is always the exact native selection. For Markdown/HTML, every
/// touched block contributes its FULL source — we deliberately do NOT try to
/// slice a block to the selected sub-range.
///
/// Why no sub-slicing: the native selection offsets index the *rendered* text,
/// while our Markdown/HTML is rebuilt from the block's source. The two flatten
/// whitespace, HTML entities, and block boundaries differently and never line
/// up, so any "is the whole block selected?" comparison misfires and silently
/// degrades rich/Markdown copies to plain. Whole-block source is the only
/// reliable Markdown/HTML we can emit — and it's correct even when the rendered
/// selection can't cover the entire block. [touched] must be pre-sorted by `order`.
CopyOutput resolveCopy(List<BlockSelection> touched, String nativePlain) {
  final plain = nativePlain.trim();
  final String markdown;
  final String html;

  if (touched.isEmpty) {
    // Nothing registered a block range (e.g. a selection entirely within
    // disabled chrome) — fall back to the raw native plain text.
    markdown = nativePlain;
    // Preserve line breaks in the rich paste — mirror plainTextSource's HTML.
    html = '<p>${htmlEscape.convert(plain).replaceAll('\n', '<br>')}</p>';
  } else {
    markdown = touched.map((b) => b.source.markdown.trim()).join('\n\n');
    html = touched.map((b) => b.source.html).join('\n');
  }

  return CopyOutput(plain: plain, markdown: markdown.trim(), html: html);
}
