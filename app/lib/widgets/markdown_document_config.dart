import 'dart:math' as math;

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:markdown/markdown.dart' as m;
import 'package:markdown_widget/markdown_widget.dart';

import 'carbon_code_style.dart';
import 'markdown_heading_configs.dart';

/// Prose leading for a document body — the font's own (~1.2) is for labels.
/// Inline code and every marker that has to sit on a prose line tracks it, so
/// a run of code shares the line box of the paragraph around it.
const double _proseHeight = 1.55;

/// Widest an inline remote image is decoded, in logical pixels. The full
/// source resolution costs memory the pane rarely shows.
const double _imageDecodeWidth = 720;

/// A copy of [style] that merges with its parent's rather than replacing it.
///
/// Carbon text roles set `inherit: false`, and `TextStyle.merge` returns an
/// argument that does not inherit untouched, so a role used as a block style
/// would wipe the bold or italic of every span nested in it.
TextStyle _merging(TextStyle style) => style.copyWith(inherit: true);

/// Height of one prose line at the reader's text scale. A marker supplied
/// through a builder is placed verbatim, without the vertical padding the
/// package computes for its own default marker, so each one sizes its box to
/// this and aligns inside it. Scaled rather than constant: the paragraph beside
/// it grows with the system text size, and a fixed box would leave every marker
/// riding above the line it belongs to.
double _proseLine(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(_bodyStyle(context).fontSize!) *
    _proseHeight;

TextStyle _bodyStyle(BuildContext context) =>
    CarbonTheme.of(context).typography.body;

/// Gutter holding a list marker. Pinned instead of left to the package default
/// because both markers below align themselves inside it — a checkbox lands
/// there as a bare inline span with no alignment of its own.
const double _listGutter = CarbonSpacing.spacing05 * 2;

/// Whole-document markdown styling for the file viewer, on Carbon type roles
/// and colours: Plex Sans prose, Plex Mono code in the same face and palette as
/// the code viewer, links in `linkPrimary`, rules in `borderSubtle01`.
///
/// Deliberately a wider scale than `TranscriptMarkdown`: this is a file being
/// read, not a message being scanned, so headings carry real hierarchy and
/// tables and fences get surfaces of their own.
///
/// [onLinkTap] receives the raw href; classify it with `resolveMarkdownLink`.
MarkdownConfig buildMarkdownDocumentConfig(
  BuildContext context, {
  ValueChanged<String>? onLinkTap,
}) {
  final theme = CarbonTheme.of(context);
  final c = theme.colors;
  final type = theme.typography;
  final codeStyle = CarbonCodeStyle.of(context);
  final body = _merging(
    type.body.copyWith(color: c.textPrimary, height: _proseHeight),
  );
  final fence = _merging(codeStyle.text.copyWith(height: 1.5));
  // Colourless: the package merges this over every token's palette style, so a
  // colour here would flatten the highlighting to one hue.
  final fenceBase = _merging(
    CarbonCodeStyle.baseTextFor(theme).copyWith(height: 1.5),
  );

  return MarkdownConfig(
    configs: [
      PConfig(textStyle: body),
      LinkConfig(
        style: body.copyWith(
          color: c.linkPrimary,
          decoration: TextDecoration.underline,
          decorationColor: c.linkPrimary,
        ),
        onTap: onLinkTap,
      ),
      // Same size and leading as the prose around it: BoxHeightStyle.tight
      // sizes each selection rect to raw glyph metrics, so a smaller inline
      // font paints a shorter highlight box on the same line.
      // The tint is what marks a run of code in a sentence, as on GitHub and
      // in VS Code; the face change alone is easy to read past.
      CodeConfig(
        style: _merging(
          type.code.copyWith(
            fontSize: type.body.fontSize,
            color: c.textPrimary,
            height: _proseHeight,
            backgroundColor: c.layer01,
          ),
        ),
      ),
      PreConfig(
        textStyle: fenceBase,
        // The package defaults an untagged fence to Dart.
        language: 'plaintext',
        theme: codeStyle.highlightTheme,
        styleNotMatched: fence,
        decoration: BoxDecoration(
          color: c.layer01,
          border: Border.all(color: c.borderSubtle01),
        ),
        padding: const EdgeInsets.all(CarbonSpacing.spacing04),
        margin: const EdgeInsets.symmetric(vertical: CarbonSpacing.spacing03),
        wrapper: (child, code, language) =>
            _FenceFrame(code: code, child: child),
      ),
      // Carbon's heading roles, widened to one step per level: the title role
      // for H1 down to the body size at H4, with H5 and H6 stepping under it
      // in the label size. H1/H2 get their rule from
      // [markdownDocumentGenerator]. All six are pinned so H4-H6 never fall
      // back to the package's large defaults.
      H1ConfigNoRule(style: _heading(type.title, c.textPrimary)),
      H2ConfigNoRule(style: _heading(type.headingLarge, c.textPrimary)),
      H3ConfigNoRule(style: _heading(type.heading, c.textPrimary)),
      H4Config(style: _heading(type.body, c.textPrimary)),
      H5Config(style: _heading(type.label, c.textPrimary)),
      H6Config(style: _heading(type.label, c.textSecondary)),
      BlockquoteConfig(
        sideColor: c.borderStrong01,
        textColor: c.textSecondary,
        sideWith: CarbonBorders.indicator,
        padding: const EdgeInsets.fromLTRB(CarbonSpacing.spacing04, 0, 0, 0),
        margin: const EdgeInsets.symmetric(vertical: CarbonSpacing.spacing03),
      ),
      HrConfig(height: CarbonBorders.hairline, color: c.borderSubtle01),
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

TextStyle _heading(TextStyle role, Color color) => _merging(
  role.copyWith(color: color, fontWeight: FontWeight.w600, height: 1.35),
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
          top: CarbonSpacing.spacing02,
          right: CarbonSpacing.spacing02,
          child: CarbonButton.iconOnly(
            icon: const CarbonIcon(CarbonIcons.copy),
            semanticLabel: 'Copy',
            size: CarbonButtonSize.small,
            onPressed: () => Clipboard.setData(ClipboardData(text: code)),
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
    final theme = CarbonTheme.of(context);
    final c = theme.colors;
    return SizedBox(
      height: _proseLine(context),
      child: Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.only(right: CarbonSpacing.spacing03),
          child: isOrdered
              // Excluded from selection like the package's own `_OlMarker`:
              // the index is generated chrome, so copying a numbered list has
              // to yield its items and not `1.` glued to each one.
              ? SelectionContainer.disabled(
                  child: Text(
                    '${index + 1}.',
                    style: theme.typography.code.copyWith(
                      color: c.textSecondary,
                    ),
                  ),
                )
              : _Bullet(depth: depth, color: c.textSecondary),
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

/// Task-list box, drawn with Carbon status glyphs rather than Material's
/// checkbox glyphs.
class _TaskMarker extends StatelessWidget {
  const _TaskMarker({required this.checked});

  final bool checked;

  @override
  Widget build(BuildContext context) {
    final c = CarbonTheme.of(context).colors;
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
          padding: const EdgeInsets.only(right: CarbonSpacing.spacing03),
          child: CarbonIcon(
            checked ? CarbonIcons.checkmarkFilled : CarbonIcons.circleOutline,
            color: checked ? c.supportSuccess : c.iconSecondary,
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
      final cap = _imageDecodeWidth * MediaQuery.devicePixelRatioOf(context);
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
    final theme = CarbonTheme.of(context);
    final c = theme.colors;
    final label = alt.isNotEmpty ? alt : url.split('/').last;
    final open = onOpen;
    return CarbonInteraction(
      onPressed: open == null ? null : () => open(url),
      label: label,
      excludeChildSemantics: true,
      builder: (context, state, child) => CarbonFocusRing(
        visible: state.focusVisible,
        child: Container(
          constraints: BoxConstraints(minHeight: theme.smallControlHeight),
          padding: const EdgeInsets.symmetric(
            horizontal: CarbonSpacing.spacing03,
          ),
          decoration: BoxDecoration(
            color: state.hovered ? c.layerHover01 : c.layer01,
            border: Border.all(color: c.borderSubtle01),
          ),
          child: child,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: CarbonSpacing.spacing03,
        children: [
          CarbonIcon(CarbonIcons.documentBlank, color: c.iconSecondary),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.typography.code.copyWith(color: c.textSecondary),
            ),
          ),
        ],
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
    final c = CarbonTheme.of(context).colors;
    if (rows.isEmpty) return const SizedBox.shrink();
    final columns = rows.map((r) => r.cells.length).reduce(math.max);
    var bodyIndex = 0;
    final tableRows = [
      for (final row in rows)
        TableRow(
          decoration: row.header
              ? BoxDecoration(color: c.layerAccent01)
              // Zebra rows, so a wide row can be followed across the gutter.
              : (bodyIndex++).isOdd
              ? BoxDecoration(color: c.layer01)
              : null,
          children: [
            for (var i = 0; i < columns; i++)
              i < row.cells.length
                  ? Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: CarbonSpacing.spacing04,
                        vertical: CarbonSpacing.spacing03,
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
      builder: (context, constraints) => _HorizontalScroll(
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
              // borderSubtle01 rather than 00: the grid is the only thing
              // telling a cell from its neighbour, and the 00 rule over
              // the background is barely visible.
              border: TableBorder.all(color: c.borderSubtle01),
              children: tableRows,
            ),
          ),
        ),
      ),
    );
  }
}

/// A sideways scroll view with a Carbon-coloured bar that shows only while the
/// content overflows, as the code viewer's scrollbars do.
class _HorizontalScroll extends StatefulWidget {
  const _HorizontalScroll({required this.child});

  final Widget child;

  @override
  State<_HorizontalScroll> createState() => _HorizontalScrollState();
}

class _HorizontalScrollState extends State<_HorizontalScroll> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RawScrollbar(
      controller: _controller,
      scrollbarOrientation: ScrollbarOrientation.bottom,
      thumbVisibility: true,
      thickness: CarbonSpacing.spacing03,
      crossAxisMargin: CarbonSpacing.spacing01,
      thumbColor: CarbonTheme.of(context).colors.borderStrong01,
      child: SingleChildScrollView(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        // Room for the thumb, so it never sits on the last row's text.
        padding: const EdgeInsets.only(bottom: CarbonSpacing.spacing04),
        child: widget.child,
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
        margin: const EdgeInsets.only(top: CarbonSpacing.spacing03),
        padding: const EdgeInsets.only(bottom: CarbonSpacing.spacing03),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: CarbonTheme.of(context).colors.borderSubtle01,
            ),
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
  TextStyle get style => _withFaceOf(super.style, codeConfig.style).copyWith(
    // Null leaves the line's own (none), so only a config that tints code —
    // the file viewer's — paints one.
    backgroundColor: codeConfig.style.backgroundColor,
  );
}

/// [base] set in [face]'s family.
///
/// `TextStyle.fontFamily` reads back with the `packages/<name>/` prefix already
/// applied, and `copyWith` re-applies the style's own package on top of what it
/// is given, so copying the getter's value across doubles the prefix and the
/// face silently falls back. The prefix is split back off and handed over as
/// the package.
TextStyle _withFaceOf(TextStyle base, TextStyle face) {
  final match = RegExp(r'^packages/([^/]+)/').firstMatch(face.fontFamily ?? '');
  if (match == null) {
    return base.copyWith(
      fontFamily: face.fontFamily,
      fontFamilyFallback: face.fontFamilyFallback,
    );
  }
  final prefix = match.group(0)!;
  String bare(String family) =>
      family.startsWith(prefix) ? family.substring(prefix.length) : family;
  return base.copyWith(
    fontFamily: bare(face.fontFamily!),
    fontFamilyFallback: face.fontFamilyFallback?.map(bare).toList(),
    package: match.group(1),
  );
}
