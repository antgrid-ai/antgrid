import 'dart:convert';

import 'package:markdown/markdown.dart' as md;

import '../../../models/agent_event.dart';
import '../diff_view.dart';

/// The Markdown and HTML copy representations of one selectable transcript
/// block. Plain-text copy always comes from the live native selection (see
/// copy_resolver), never from this source, so no plaintext field is kept.
class BlockSource {
  final String markdown;
  final String html;
  const BlockSource({required this.markdown, required this.html});
}

/// Assistant message: text is already Markdown, so it is the Markdown source
/// verbatim; HTML is derived from it.
BlockSource assistantSource(String markdownText) => BlockSource(
  markdown: markdownText,
  html: _sanitizeHtml(
    md
        .markdownToHtml(markdownText, extensionSet: md.ExtensionSet.gitHubWeb)
        .trimRight(),
  ),
);

/// Neutralizes the script/style/event-handler vectors in generated HTML before
/// it reaches the clipboard's `text/html` format. CommonMark passes raw HTML in
/// the source through verbatim, and assistant text can relay untrusted tool
/// output — so a rich paste into an HTML-rendering target must not carry live
/// markup. Defense-in-depth (a strip, not a full allowlist sanitizer); the
/// on-screen renderer already treats raw HTML as inert.
String _sanitizeHtml(String html) => html
    .replaceAll(_scriptTag, '')
    .replaceAll(_styleTag, '')
    .replaceAll(_eventAttr, '')
    .replaceAll(_jsScheme, '');

// Hoisted so a multi-block rich copy doesn't recompile these per touched block.
final _scriptTag = RegExp(
  r'<script\b[^>]*>[\s\S]*?</script\s*>',
  caseSensitive: false,
);
final _styleTag = RegExp(
  r'<style\b[^>]*>[\s\S]*?</style\s*>',
  caseSensitive: false,
);
final _eventAttr = RegExp(
  r'''\son\w+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)''',
  caseSensitive: false,
);
final _jsScheme = RegExp('javascript:', caseSensitive: false);

/// Plain content (user message, reasoning body): no formatting to preserve.
BlockSource plainTextSource(String text) => BlockSource(
  markdown: text,
  html: '<p>${htmlEscape.convert(text).replaceAll('\n', '<br>')}</p>',
);

BlockSource planSource(List<PlanEntry> entries) => BlockSource(
  markdown: entries
      .map((e) => '- [${e.status == 'completed' ? 'x' : ' '}] ${e.text}')
      .join('\n'),
  html:
      '<ul>${entries.map((e) => '<li>${htmlEscape.convert(e.text)}</li>').join()}</ul>',
);

/// Monospace block (terminal output, tool text, raw JSON). [language] tags the
/// Markdown fence; empty means a bare fence.
BlockSource codeSource(String text, {String language = ''}) => BlockSource(
  markdown: '```$language\n$text\n```',
  html: '<pre><code>${htmlEscape.convert(text)}</code></pre>',
);

BlockSource diffSource(List<DiffLine> lines) {
  final body = lines
      .map(
        (l) =>
            '${switch (l.op) {
              DiffOp.add => '+',
              DiffOp.del => '-',
              DiffOp.context => ' ',
            }}${l.text}',
      )
      .join('\n');
  return BlockSource(
    markdown: '```diff\n$body\n```',
    html: '<pre><code>${htmlEscape.convert(body)}</code></pre>',
  );
}
