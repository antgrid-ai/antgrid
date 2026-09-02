import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:markdown_widget/markdown_widget.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_icon_button.dart';
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
      CodeConfig(
        style: AbTokens.monoStyle(color: c.textPrimary, height: _proseHeight),
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
      // Document scale (a full file, so more hierarchy than the chat
      // transcript): explicit sizes + weight, and all six levels pinned so
      // H4-H6 don't fall back to the package's large defaults. Headings use
      // textSecondary (body is textPrimary) so tone plus weight, not size
      // alone, sets them apart.
      H1ConfigNoRule(style: _heading(c.textSecondary, AbTokens.fontXl)),
      H2ConfigNoRule(style: _heading(c.textSecondary, AbTokens.fontLg)),
      H3ConfigNoRule(style: _heading(c.textSecondary, AbTokens.fontBody)),
      H4Config(style: _heading(c.textSecondary, AbTokens.fontMd)),
      H5Config(style: _heading(c.textSecondary, AbTokens.fontSm)),
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
      TableConfig(
        // borderDefault, not borderSubtle: the grid is the only thing telling
        // a cell from its neighbour, and borderSubtle over bgDeepest is ~1.15:1
        // — a table that reads as unaligned columns of floating text.
        border: TableBorder.all(color: c.borderDefault),
        headerRowDecoration: BoxDecoration(color: c.bgSurface),
        // A table in a repo doc is data, so it reads mono. This one style
        // reaches the body rows too — the package resolves TBodyNode's style
        // from `headerStyle` as well, and never from `bodyStyle` — which is why
        // the header's prominence lives in its fill rather than its weight.
        headerStyle: AbTokens.monoStyle(
          fontSize: AbTokens.fontSm,
          color: c.textPrimary,
          height: 1.5,
        ),
        headPadding: const EdgeInsets.symmetric(
          horizontal: AbTokens.space8,
          vertical: AbTokens.space6,
        ),
        bodyPadding: const EdgeInsets.symmetric(
          horizontal: AbTokens.space8,
          vertical: AbTokens.space6,
        ),
        // Columns size to their content, so a wide table would otherwise run
        // off the measure instead of scrolling.
        wrapper: (table) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: table,
        ),
      ),
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
      // The measure is the widest this can ever paint, so decoding beyond it
      // buys nothing and costs the full source resolution in memory — a 4000px
      // photo is ~48MB of ARGB the reader never sees a pixel of.
      final cap = AbTokens.documentMaxWidth *
          MediaQuery.devicePixelRatioOf(context);
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
  generators: [
    SpanNodeGeneratorWithTag(
      tag: MarkdownTag.code.name,
      generator: (e, config, visitor) => _CodeSpan(e.textContent, config.code),
    ),
  ],
);

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
  );
}
