import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:markdown_widget/markdown_widget.dart';

import '../constants/breakpoints.dart';
import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_separator.dart';
import '../models/file_tree_models.dart';
import '../util/detached.dart';
import '../util/external_url.dart';
import '../util/markdown_link_target.dart';
import 'markdown_document_config.dart';
import 'markdown_outline.dart';
import 'preview_with_source_toggle.dart';

/// Below this many headings an outline says less than the document already
/// does, so the rail and its toggle never appear.
const int _minOutlineHeadings = 3;

/// Renders a markdown file. Defaults to the rendered preview; a header toggle
/// switches to the full source code view.
///
/// [onOpenFile] receives a project-relative path when the reader follows a link
/// to another file in the repo. Callers that view a file outside the explorer's
/// selection — the attachment overlay, the git panel — leave it null, and such
/// links then do nothing rather than navigating a surface that has nowhere to
/// navigate to.
class MarkdownPreview extends StatefulWidget {
  final FileContent content;
  final VoidCallback? onClose;
  final VoidCallback? onRefreshContent;
  final bool fileWasModified;
  final int? searchLine;
  final String? searchQuery;
  final ValueChanged<String>? onOpenFile;

  const MarkdownPreview({
    super.key,
    required this.content,
    this.onClose,
    this.onRefreshContent,
    this.fileWasModified = false,
    this.searchLine,
    this.searchQuery,
    this.onOpenFile,
  });

  @override
  State<MarkdownPreview> createState() => _MarkdownPreviewState();
}

class _MarkdownPreviewState extends State<MarkdownPreview> {
  late final MarkdownTocController _toc = MarkdownTocController(
    onHeadingCount: _onHeadingCount,
  );

  int _headingCount = 0;

  /// Null until the reader touches the toggle, and then their choice. The
  /// default is a property of the pane's width, which is not known here.
  bool? _outlineOpen;

  MarkdownWidget? _cachedDocument;
  String? _cachedData;
  AbColors? _cachedColors;
  double? _cachedGutter;

  @override
  void dispose() {
    _toc.dispose();
    super.dispose();
  }

  void _onHeadingCount(int count) {
    if (count == _headingCount) return;
    // The count arrives while MarkdownWidget is building its children, so the
    // rebuild it implies has to wait for the frame to finish.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _headingCount = count);
    });
  }

  void _onLinkTap(String href) {
    final target = resolveMarkdownLink(href, fromPath: widget.content.path);
    switch (target.kind) {
      case MarkdownLinkKind.external:
        detached(
          'MarkdownPreview',
          'open external link',
          () => openExternalUrl(context, target.value),
        );
      case MarkdownLinkKind.repoFile:
        widget.onOpenFile?.call(target.value);
      case MarkdownLinkKind.anchor:
        _jumpToAnchor(target.value);
      case MarkdownLinkKind.unsupported:
        break;
    }
  }

  void _jumpToAnchor(String fragment) {
    final wanted = slugifyMarkdownHeading(fragment);
    for (final toc in _toc.tocList) {
      if (slugifyMarkdownHeading(markdownHeadingText(toc.node)) == wanted) {
        _toc.jumpToIndex(toc.widgetIndex);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // The rail and the document need room to sit side by side; below that
        // the outline covers the document instead.
        final wide = constraints.maxWidth >= kMediumBreakpoint;
        final hasOutline = _headingCount >= _minOutlineHeadings;
        final showOutline = hasOutline && (_outlineOpen ?? wide);

        return PreviewWithSourceToggle(
          content: widget.content,
          onClose: widget.onClose,
          onRefreshContent: widget.onRefreshContent,
          fileWasModified: widget.fileWasModified,
          searchLine: widget.searchLine,
          searchQuery: widget.searchQuery,
          extraActions: [
            if (hasOutline)
              AbIconButton(
                icon: AbIcons.list,
                selected: showOutline,
                tooltip: showOutline ? 'Hide outline' : 'Show outline',
                onTap: () => setState(() => _outlineOpen = !showOutline),
              ),
          ],
          previewBuilder: (context) =>
              _buildBody(context, wide: wide, showOutline: showOutline),
        );
      },
    );
  }

  Widget _buildBody(
    BuildContext context, {
    required bool wide,
    required bool showOutline,
  }) {
    final c = context.antgrid;
    final outline = MarkdownOutline(
      controller: _toc,
      // Back to following the pane width rather than latching closed: a
      // narrow pane hides the overlay either way, but latching would also
      // withhold the docked rail forever once the pane grows.
      onJump: wide ? null : () => setState(() => _outlineOpen = null),
    );

    return ColoredBox(
      color: c.bgDeepest,
      child: Stack(
        // Tight constraints for the row beneath: a loose-fit stack would leave
        // the document's list to shrink-wrap a height it cannot compute.
        fit: StackFit.expand,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _buildDocument(context)),
              if (showOutline && wide) ...[
                const AbSeparator.vertical(),
                SizedBox(
                  width: AbTokens.documentOutlineWidth,
                  child: outline,
                ),
              ],
            ],
          ),
          // Narrow panes get the outline over the document rather than in place
          // of it: unmounting the document would drop the scroll position the
          // reader is about to jump within, and the controller with it.
          if (showOutline && !wide)
            Positioned.fill(
              child: ColoredBox(color: c.bgDeepest, child: outline),
            ),
        ],
      ),
    );
  }

  Widget _buildDocument(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // The measure is capped with padding, never by boxing the document in a
        // narrower `ConstrainedBox`: the scrollable itself has to stay as wide
        // as the pane, or a wheel turn or drag landing in the gutter beside the
        // text hits no `Scrollable` and the document sits still.
        final gutter = math.max(
          0.0,
          constraints.maxWidth - AbTokens.documentMaxWidth,
        );
        return _document(context, gutter);
      },
    );
  }

  /// The document, reused verbatim while nothing it renders from has changed.
  ///
  /// `MarkdownWidgetState.didUpdateWidget` re-parses the WHOLE file on every
  /// rebuild — it never looks at whether `data` moved — so handing back the
  /// identical instance, which `Element.updateChild` short-circuits on, is the
  /// only thing keeping the heading-count `setState`, an outline toggle or a
  /// theme rebuild from re-parsing a document nobody edited. Every argument
  /// below is part of the key: one added without a matching field here renders
  /// stale, and nothing warns.
  MarkdownWidget _document(BuildContext context, double gutter) {
    final data = widget.content.content ?? '';
    final colors = context.antgrid;
    final cached = _cachedDocument;
    if (cached != null &&
        _cachedData == data &&
        identical(_cachedColors, colors) &&
        _cachedGutter == gutter) {
      return cached;
    }
    _cachedData = data;
    _cachedColors = colors;
    _cachedGutter = gutter;
    return _cachedDocument = MarkdownWidget(
      data: data,
      tocController: _toc,
      markdownGenerator: markdownAntgridGenerator,
      padding: EdgeInsets.fromLTRB(
        AbTokens.space16,
        AbTokens.space16,
        AbTokens.space16 + gutter,
        AbTokens.space16,
      ),
      config: buildMarkdownDocumentConfig(context, onLinkTap: _onLinkTap),
    );
  }
}
