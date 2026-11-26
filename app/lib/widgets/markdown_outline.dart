import 'package:flutter/widgets.dart';
import 'package:markdown_widget/markdown_widget.dart';

import '../design/ab_colors.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_list_row.dart';

/// The [TocController] a [MarkdownOutline] reads, extended with the two things
/// the package keeps to itself.
///
/// [MarkdownWidget] publishes the heading list and the scroll position only
/// into its controller — the first through [setTocList], the second through
/// [onIndexChanged] — and its own `TocWidget` is the sole consumer of either.
/// Overriding both is what lets the rail be built here instead, out of the
/// app's own row widget rather than `TocWidget`'s Material `ListTile`.
class MarkdownTocController extends TocController {
  MarkdownTocController({required this.onHeadingCount});

  /// Fires with the heading count each time the document is parsed.
  final ValueChanged<int> onHeadingCount;

  /// Widget index of the topmost item on screen.
  ///
  /// A notifier rather than widget state: this changes on every scroll, and a
  /// `setState` here would rebuild [MarkdownWidget], which re-parses the whole
  /// document in `didUpdateWidget`. Only the rail listens.
  final ValueNotifier<int> topVisibleIndex = ValueNotifier(0);

  @override
  void setTocList(List<Toc> list) {
    super.setTocList(list);
    // [tocList], not `list`: the base class keys headings by widget index, and
    // every heading inside one top-level block (a blockquote, say) carries the
    // same one — so the map collapses them and the rail renders fewer rows than
    // were parsed. The count gates that rail, so it has to be the count the
    // rail will actually show.
    onHeadingCount(tocList.length);
  }

  @override
  void onIndexChanged(int index) {
    super.onIndexChanged(index);
    topVisibleIndex.value = index;
  }

  @override
  void dispose() {
    topVisibleIndex.dispose();
    super.dispose();
  }
}

/// The heading spine of a rendered document: every `h1`-`h6` in reading order,
/// indented by level, with the section the reader is in marked.
///
/// A repo doc's headings are its real structure — the outline is the file's own
/// table of contents, not a decoration hung beside it — which is why this is
/// the one persistent fixture the preview adds rather than a menu the reader
/// has to go find.
///
/// [onJump] fires after a jump so a caller showing this over the document (the
/// narrow layout) can dismiss itself.
class MarkdownOutline extends StatelessWidget {
  const MarkdownOutline({super.key, required this.controller, this.onJump});

  final MarkdownTocController controller;
  final VoidCallback? onJump;

  @override
  Widget build(BuildContext context) {
    final headings = controller.tocList;
    // The rail does not scroll itself to the active entry. Nothing here knows a
    // row's height — density and the text scaler both move it — so following
    // the mark needs a per-row key and `ensureVisible`, which is only worth it
    // for a document with more headings than the rail can hold.
    return ValueListenableBuilder<int>(
      valueListenable: controller.topVisibleIndex,
      builder: (context, topVisible, _) {
        final active = activeOutlineIndex(headings, topVisible);
        return ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: AbTokens.space8),
          itemCount: headings.length,
          itemBuilder: (context, index) => _OutlineRow(
            heading: headings[index],
            selected: index == active,
            onTap: () {
              // No local selection to set: the jump moves the document, the
              // document reports its new position, and the mark follows.
              controller.jumpToIndex(headings[index].widgetIndex);
              onJump?.call();
            },
          ),
        );
      },
    );
  }
}

/// Which heading the reader is under, given the topmost item on screen.
///
/// The last heading at or above it, so a reader partway through a section's
/// body still sees that section marked — asking instead whether a heading is
/// itself on top leaves the mark stuck wherever it last landed, which for most
/// of a scroll is the wrong answer.
///
/// One known lag, and it is upstream: `MarkdownWidgetState` tracks a block only
/// while `visibleFraction == 1`, so a single block taller than the viewport is
/// never admitted and the topmost index stays on the block before it. Scrolling
/// through one long list — the shape a repo doc's "gotchas" section takes —
/// therefore holds the mark on the previous heading until the next block that
/// does fit comes fully into view. Every viewport-sized block tracks correctly.
int activeOutlineIndex(List<Toc> headings, int topWidgetIndex) {
  var active = 0;
  for (var i = 0; i < headings.length; i++) {
    if (headings[i].widgetIndex > topWidgetIndex) break;
    active = i;
  }
  return active;
}

class _OutlineRow extends StatelessWidget {
  const _OutlineRow({
    required this.heading,
    required this.selected,
    required this.onTap,
  });

  final Toc heading;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.antgrid;
    final level = headingTag2Level[heading.node.headingConfig.tag] ?? 1;

    return AbListRow(
      density: AbRowDensity.sm,
      horizontalPadding: AbTokens.space8,
      selected: selected,
      selectionStyle: AbRowSelection.accentBar,
      hoverable: true,
      title: Padding(
        padding: EdgeInsets.only(left: AbTokens.space8 * (level - 1)),
        child: Text(
          markdownHeadingText(heading.node),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AbTokens.monoStyle(
            fontSize: AbTokens.fontXs,
            color: selected ? c.textPrimary : c.textMuted,
            fontWeight: level == 1 ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
      onTap: onTap,
    );
  }
}

/// The plain text of a heading, for an outline label or an anchor slug.
///
/// [CodeNode] carries its text in a field rather than in a child [TextNode], so
/// walking children alone drops it — and `### \`copyWith\`` is a heading shape
/// repo docs use constantly, which would leave a blank row in the rail.
String markdownHeadingText(HeadingNode node) {
  final buffer = StringBuffer();
  void walk(SpanNode current) {
    switch (current) {
      case TextNode():
        buffer.write(current.text);
      case CodeNode():
        buffer.write(current.text);
      case ElementNode():
        for (final child in current.children) {
          walk(child);
        }
      default:
        break;
    }
  }

  walk(node);
  return buffer.toString().trim();
}
