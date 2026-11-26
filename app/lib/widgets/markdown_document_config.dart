import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:markdown/markdown.dart' as m;
import 'package:markdown_widget/markdown_widget.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_scrollbar.dart';
import 'markdown_heading_configs.dart';

/// Prose leading for a document body — the font's own (~1.2) is for labels.
/// Inline code and every marker that has to sit on a prose line tracks it, so
/// a run of code shares the line box of the paragraph around it.
const double _proseHeight = 1.55;

/// Height of one prose line at the reader's text scale. A marker supplied
/// through a builder is placed verbatim, without the vertical padding the
/// package computes for its own default marker, so each one sizes its box to
/// this and aligns inside it. Scaled rather than constant: the paragraph beside
/// it grows with the system text size, and a fixed box would leave every marker
/// riding above the line it belongs to.
double _proseLine(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(AbTokens.fontBody) * _proseHeight;

/// Gutter holding a list marker. Pinned instead of left to the package default
/// because both markers below align themselves inside it — a checkbox lands
/// there as a bare inline span with no alignment of its own.
const double _listGutter = AbTokens.space16 * 2;

/// Whole-document markdown styling for the file viewer.
///
/// Deliberately a wider scale than `TranscriptMarkdown`: this is a file being
/// read, not a message being scanned, so headings carry real hierarchy and
/// tables and fences get surfaces of their own. Everything else stays in
/// lockstep with `transcript/markdown_body.dart` — same heading tone, same
/// underline-only links, same uncoloured fences.
///
/// [onLinkTap] receives the raw href; classify it with `resolveMarkdownLink`.
MarkdownConfig buildMarkdownDocumentConfig(
  BuildContext context, {
  ValueChanged<String>? onLinkTap,
}) {
  final c = context.antgrid;
  final body = AbTokens.sansStyle(color: c.textPrimary, height: _proseHeight);
  final fence = AbTokens.monoStyle(color: c.textPrimary, height: 1.5);

  return MarkdownConfig(
    configs: [
      PConfig(textStyle: body),
      // Underline is the whole affordance — links take body color, no tint.
      // The package default is GitHub blue (#0969DA), a light-theme link color
      // that lands near 3:1 on our dark surfaces.
      LinkConfig(
        style: body.copyWith(decoration: TextDecoration.underline),
        onTap: onLinkTap,
      ),
      // Same size and leading as the prose around it: BoxHeightStyle.tight
      // sizes each selection rect to raw glyph metrics, so a smaller inline
      // font paints a shorter highlight box on the same line.
      // The tint is what marks a run of code in a sentence, as on GitHub and
      // in VS Code; the face change alone is easy to read past.
      CodeConfig(
        style: AbTokens.monoStyle(
          color: c.textPrimary,
          height: _proseHeight,
        ).copyWith(backgroundColor: c.bgSurface),
      ),
      PreConfig(
        textStyle: fence,
        // Package default is a11yLightTheme — light-bg token colors on our dark
        // surfaces, and the spec says no syntax coloring (v1). Empty theme +
        // styleNotMatched = plain mono.
        theme: const {},
        styleNotMatched: fence,
        decoration: BoxDecoration(
          color: c.bgSurface,
          border: Border.all(color: c.borderDefault),
          borderRadius: AbTokens.borderRadius,
        ),
        padding: const EdgeInsets.all(AbTokens.space12),
        margin: const EdgeInsets.symmetric(vertical: AbTokens.space8),
        wrapper: (child, code, language) =>
            _FenceFrame(code: code, child: child),
      ),
      // GitHub's and VS Code's document scale over a 14px body — roughly 1.7,
      // 1.3, 1.15, 1, 0.93, 0.86em — in the body's own colour, so a heading
      // outranks the prose it heads; only H6 drops to muted, as theirs does.
      // H1/H2 get their rule from [markdownDocumentGenerator]. All six are
      // pinned so H4-H6 never fall back to the package's large defaults.
      H1ConfigNoRule(style: _heading(c.textPrimary, AbTokens.fontDisplaySm)),
      H2ConfigNoRule(style: _heading(c.textPrimary, AbTokens.fontXl)),
      H3ConfigNoRule(style: _heading(c.textPrimary, AbTokens.fontLg)),
      H4Config(style: _heading(c.textPrimary, AbTokens.fontBody)),
      H5Config(style: _heading(c.textPrimary, AbTokens.fontMd)),
      H6Config(style: _heading(c.textSecondary, AbTokens.fontSm)),
      // Defaults are GitHub's light-theme greys — a #d0d7de rule beside #57606a
      // body text, which on our ground reads as a bright bar next to an
      // invisible quote.
      BlockquoteConfig(
        sideColor: c.borderStrong,
        textColor: c.textSecondary,
        sideWith: 2,
        padding: const EdgeInsets.fromLTRB(AbTokens.space12, 0, 0, 0),
        margin: const EdgeInsets.symmetric(vertical: AbTokens.space8),
      ),
      HrConfig(height: 1, color: c.borderDefault),
      // Tables are built by [markdownDocumentGenerator] (`_DocTableNode`), not
      // from a TableConfig: the package's own node centres every header,
      // ignores column alignment, and never wraps a column.
      ListConfig(
        marginLeft: _listGutter,
        marker: (isOrdered, depth, index) =>
            _ListMarker(isOrdered: isOrdered, depth: depth, index: index),
      ),
      // The package default draws a raw Material `Icons.check_box`.
      CheckBoxConfig(builder: (checked) => _TaskMarker(checked: checked)),
      ImgConfig(
        builder: (url, attributes) => _MarkdownImage(
          url: url,
          alt: attributes['alt'] ?? '',
          width: double.tryParse(attributes['width'] ?? ''),
          height: double.tryParse(attributes['height'] ?? ''),
          onOpen: onLinkTap,
        ),
      ),
    ],
  );
}

TextStyle _heading(Color color, double fontSize) => AbTokens.sansStyle(
  fontSize: fontSize,
  color: color,
  fontWeight: fontSize >= AbTokens.fontLg ? FontWeight.w700 : FontWeight.w600,
  height: fontSize >= AbTokens.fontLg ? 1.3 : 1.35,
);

/// Hangs a copy button over a code fence, matching the transcript's fences.
class _FenceFrame extends StatelessWidget {
  const _FenceFrame({required this.code, required this.child});

  final String code;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        Positioned(
          top: AbTokens.space6,
          right: AbTokens.space6,
          child: AbIconButton(
            icon: AbIcons.copy,
            tone: AbIconButtonTone.muted,
            tooltip: 'Copy',
            onTap: () => Clipboard.setData(ClipboardData(text: code)),
          ),
        ),
      ],
    );
  }
}

/// Bullet or index for one list item.
///
/// Replaces the package default for two reasons: it paints markers in the
/// inherited text color, which is body-bright and pulls the eye off the text
/// they belong to, and it sets ordered indices in the paragraph face — an
/// index is data, so it belongs in mono like every other index in the app.
class _ListMarker extends StatelessWidget {
  const _ListMarker({
    required this.isOrdered,
    required this.depth,
    required this.index,
  });

  final bool isOrdered;
  final int depth;
  final int index;

  @override
  Widget build(BuildContext context) {
    final c = context.antgrid;
    return SizedBox(
      height: _proseLine(context),
      child: Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.only(right: AbTokens.space8),
          child: isOrdered
              // Excluded from selection like the package's own `_OlMarker`:
              // the index is generated chrome, so copying a numbered list has
              // to yield its items and not `1.` glued to each one.
              ? SelectionContainer.disabled(
                  child: Text(
                    '${index + 1}.',
                    style: AbTokens.monoStyle(
                      fontSize: AbTokens.fontSm,
                      color: c.textMuted,
                    ),
                  ),
                )
              : _Bullet(depth: depth, color: c.textMuted),
        ),
      ),
    );
  }
}

/// Nesting depth read as shape — filled, outlined, then square — so a nested
/// list stays legible without an indent guide.
class _Bullet extends StatelessWidget {
  const _Bullet({required this.depth, required this.color});

  final int depth;
  final Color color;

  static const _size = 5.0;

  @override
  Widget build(BuildContext context) {
    final shape = depth % 3;
    return Container(
      width: _size,
      height: _size,
      decoration: BoxDecoration(
        color: shape == 1 ? null : color,
        border: shape == 1 ? Border.all(color: color) : null,
        shape: shape == 2 ? BoxShape.rectangle : BoxShape.circle,
      ),
    );
  }
}

/// Task-list box, drawn with the app's own toggle pair rather than Material's
/// checkbox glyphs.
class _TaskMarker extends StatelessWidget {
  const _TaskMarker({required this.checked});

  final bool checked;

  @override
  Widget build(BuildContext context) {
    final c = context.antgrid;
    // Same box and alignment as [_ListMarker]: the package drops a checkbox
    // into the marker gutter as a raw inline span, so anything narrower than
    // the gutter hugs its left edge and the boxes step left of the bullets
    // above them in a mixed list.
    return SizedBox(
      height: _proseLine(context),
      width: _listGutter,
      child: Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.only(right: AbTokens.space8),
          child: AbIcon(
            checked ? AbIcons.circleCheck : AbIcons.circle,
            size: AbTokens.fontSm,
            color: checked ? c.success : c.textMuted,
          ),
        ),
      ),
    );
  }
}

/// An image referenced by a document.
///
/// A repo-relative `src` has no URL this layer can fetch — file bytes arrive
/// over the bridge, not over HTTP — so in place of the package's broken-image
/// glyph it renders a chip naming the image, which opens the file in the
/// viewer's own image view when tapped.
class _MarkdownImage extends StatelessWidget {
  const _MarkdownImage({
    required this.url,
    required this.alt,
    this.width,
    this.height,
    this.onOpen,
  });

  final String url;
  final String alt;
  final double? width;
  final double? height;
  final ValueChanged<String>? onOpen;

  /// Case-insensitively, because a scheme is case-insensitive and `HTTPS://`
  /// appears in real documents — matching it as written would send a web image
  /// down the repo-file branch and render a chip that opens nothing.
  bool get _isRemote {
    final scheme = url.toLowerCase();
    return scheme.startsWith('http://') || scheme.startsWith('https://');
  }

  @override
  Widget build(BuildContext context) {
    if (_isRemote) {
      // Decoded no wider than a comfortable reading width: the full source
      // resolution costs memory the pane rarely shows — a 4000px photo is
      // ~48MB of ARGB. It paints at that decoded size, never stretched.
      final cap =
          AbTokens.documentMaxWidth * MediaQuery.devicePixelRatioOf(context);
      return Image.network(
        url,
        width: width,
        height: height,
        cacheWidth: cap.round(),
        errorBuilder: (context, error, stack) => _chip(context),
      );
    }
    return _chip(context);
  }

  Widget _chip(BuildContext context) {
    final c = context.antgrid;
    final label = alt.isNotEmpty ? alt : url.split('/').last;
    return GestureDetector(
      onTap: onOpen == null ? null : () => onOpen!(url),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AbTokens.space8,
          vertical: AbTokens.space4,
        ),
        decoration: BoxDecoration(
          border: Border.all(color: c.borderDefault),
          borderRadius: AbTokens.borderRadius,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AbIcon(
              AbIcons.fileBinary,
              size: AbTokens.fontSm,
              color: c.textMuted,
            ),
            const SizedBox(width: AbTokens.space6),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AbTokens.monoStyle(
                  fontSize: AbTokens.fontSm,
                  color: c.textMuted,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The generator every Antgrid markdown surface renders with, for the one node
/// a [MarkdownConfig] alone cannot style.
final MarkdownGenerator markdownAntgridGenerator = MarkdownGenerator(
  generators: [_inlineCodeGenerator],
);

final _inlineCodeGenerator = SpanNodeGeneratorWithTag(
  tag: MarkdownTag.code.name,
  generator: (e, config, visitor) => _CodeSpan(e.textContent, config.code),
);

/// The file viewer's generator: [markdownAntgridGenerator] plus the two things
/// that make a repo document read the way GitHub and VS Code render it.
///
/// A single newline inside a paragraph is a SOFT break — the source was
/// wrapped at 80 columns for the editor, not for the reader — so it joins the
/// lines with a space. The package passes it through as a literal newline,
/// which tore every hard-wrapped README into ragged half-lines. A hard break
/// (two trailing spaces, a backslash) still arrives as its own `br` node, and a
/// fence renders from its own raw text, so neither is touched.
///
/// H1 and H2 carry a rule under them, which is what tells a document's
/// sections apart at a glance. Drawn here rather than through the package's
/// `HeadingDivider`, which paints a Material `Divider` in the heading's own text
/// colour — a bright bar on our ground.
///
/// Not used by the chat transcript: a newline in a message is meant.
final MarkdownGenerator markdownDocumentGenerator = MarkdownGenerator(
  generators: [
    _inlineCodeGenerator,
    SpanNodeGeneratorWithTag(
      tag: MarkdownTag.h1.name,
      generator: (e, config, visitor) => _RuledHeadingNode(config.h1, visitor),
    ),
    SpanNodeGeneratorWithTag(
      tag: MarkdownTag.h2.name,
      generator: (e, config, visitor) => _RuledHeadingNode(config.h2, visitor),
    ),
    SpanNodeGeneratorWithTag(
      tag: MarkdownTag.table.name,
      generator: (e, config, visitor) => _DocTableNode(visitor),
    ),
    for (final section in [MarkdownTag.thead, MarkdownTag.tbody])
      SpanNodeGeneratorWithTag(
        tag: section.name,
        generator: (e, config, visitor) =>
            _TableSectionNode(header: section == MarkdownTag.thead),
      ),
    for (final cell in [MarkdownTag.th, MarkdownTag.td])
      SpanNodeGeneratorWithTag(
        tag: cell.name,
        generator: (e, config, visitor) => _TableCellNode(
          align: e.attributes['align'] ?? '',
          style: cell == MarkdownTag.th
              ? config.p.textStyle.copyWith(
                  fontWeight: FontWeight.w600,
                  height: _cellHeight,
                )
              : config.p.textStyle.copyWith(height: _cellHeight),
        ),
      ),
  ],
  textGenerator: (node, config, visitor) =>
      node is m.Text && node.text.contains('\n')
      ? TextNode(text: joinSoftBreaks(node.text), style: config.p.textStyle)
      : null,
);

/// Joins a paragraph's soft-wrapped lines, eating the indentation a wrapped
/// list item or quote carries on its continuation lines.
@visibleForTesting
String joinSoftBreaks(String text) => text.replaceAll(_softBreak, ' ');

final _softBreak = RegExp(r'[ \t]*\n[ \t]*');

/// Cell leading: tighter than prose, since a wrapped cell is a few lines at
/// most and a row should not read as a paragraph.
const double _cellHeight = 1.45;

/// `thead`/`tbody`. Only marks which rows it holds; the table reads them.
class _TableSectionNode extends ElementNode {
  _TableSectionNode({required this.header});

  final bool header;
}

/// `th`/`td`, carrying the column alignment the source's `:---:` gave it and
/// its own style — header cells bold, every cell in the body face.
class _TableCellNode extends ElementNode {
  _TableCellNode({required this.align, required TextStyle style})
    : _style = style;

  final String align;
  final TextStyle _style;

  @override
  TextStyle get style => _style;

  Alignment get alignment => align.contains('center')
      ? Alignment.topCenter
      : align.contains('right')
      ? Alignment.topRight
      : Alignment.topLeft;
}

/// A markdown table laid out the way GitHub and VS Code lay one out, in place
/// of the package's node (which centres every header, ignores column
/// alignment, and never wraps a column).
class _DocTableNode extends ElementNode {
  _DocTableNode(this.visitor);

  final WidgetVisitor visitor;

  @override
  InlineSpan build() {
    final rows = <({bool header, List<_TableCellNode> cells})>[];
    for (final section in children.whereType<_TableSectionNode>()) {
      for (final tr in section.children.whereType<ElementNode>()) {
        rows.add((
          header: section.header,
          cells: tr.children.whereType<_TableCellNode>().toList(),
        ));
      }
    }
    return WidgetSpan(
      child: _MarkdownTable(rows: rows, visitor: visitor),
    );
  }
}

class _MarkdownTable extends StatelessWidget {
  const _MarkdownTable({required this.rows, required this.visitor});

  final List<({bool header, List<_TableCellNode> cells})> rows;
  final WidgetVisitor visitor;

  @override
  Widget build(BuildContext context) {
    final c = context.antgrid;
    if (rows.isEmpty) return const SizedBox.shrink();
    final columns = rows.map((r) => r.cells.length).reduce(math.max);
    var bodyIndex = 0;
    final tableRows = [
      for (final row in rows)
        TableRow(
          decoration: row.header
              ? BoxDecoration(color: c.bgSurface)
              // Zebra rows, so a wide row can be followed across the gutter.
              : (bodyIndex++).isOdd
              ? BoxDecoration(color: c.bgDeep)
              : null,
          children: [
            for (var i = 0; i < columns; i++)
              i < row.cells.length
                  ? Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AbTokens.space12,
                        vertical: AbTokens.space6,
                      ),
                      child: Align(
                        alignment: row.cells[i].alignment,
                        child: ProxyRichText(
                          row.cells[i].childrenSpan,
                          richTextBuilder: visitor.richTextBuilder,
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
          ],
        ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) => AbHorizontalScrollView(
        // Capped at the pane and sized to the content beneath that cap: a
        // table that fits keeps its natural width, and one that does not
        // fills the pane with its columns wrapping (flex shrinks a column no
        // narrower than its longest word). Only a table whose words alone
        // outgrow the pane is left to scroll sideways.
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: constraints.maxWidth),
          child: IntrinsicWidth(
            child: Table(
              defaultColumnWidth: const IntrinsicColumnWidth(flex: 1),
              defaultVerticalAlignment: TableCellVerticalAlignment.top,
              // borderDefault, not borderSubtle: the grid is the only thing
              // telling a cell from its neighbour, and borderSubtle over
              // bgDeepest is ~1.15:1.
              border: TableBorder.all(color: c.borderDefault),
              children: tableRows,
            ),
          ),
        ),
      ),
    );
  }
}

/// An H1/H2 with a hairline under it, GitHub-style.
class _RuledHeadingNode extends HeadingNode {
  _RuledHeadingNode(super.headingConfig, super.visitor);

  @override
  InlineSpan build() => WidgetSpan(
    child: Builder(
      builder: (context) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(top: AbTokens.space8),
        padding: const EdgeInsets.only(bottom: AbTokens.space6),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: context.antgrid.borderDefault),
          ),
        ),
        child: ProxyRichText(
          childrenSpan,
          richTextBuilder: visitor.richTextBuilder,
        ),
      ),
    ),
  );
}

/// Inline code, put back into the mono face.
///
/// `CodeNode.style` resolves as `codeConfig.style.merge(parentStyle)`, and
/// `merge` lets the ARGUMENT win every non-null field — so the paragraph's sans
/// family overwrites the configured mono one and `` `flutter test` `` renders
/// byte for byte like the prose around it. Nothing consults [CodeConfig] again
/// after that merge, which leaves this the only place to assert the family.
///
/// Family only: size, weight, colour and leading stay whatever the line it sits
/// in uses, so a run of code keeps the baseline of its sentence — and inline
/// code in a heading still reads at heading weight.
class _CodeSpan extends CodeNode {
  _CodeSpan(super.text, super.config);

  @override
  TextStyle get style => super.style.copyWith(
    fontFamily: codeConfig.style.fontFamily,
    fontFamilyFallback: codeConfig.style.fontFamilyFallback,
    // Null leaves the line's own (none), so only a config that tints code —
    // the file viewer's — paints one.
    backgroundColor: codeConfig.style.backgroundColor,
  );
}
