import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/ab_colors.dart';
import '../../../design/ab_icons.dart';
import '../../../design/ab_tokens.dart';
import '../../../design/widgets/ab_icon_button.dart';
import '../../../design/widgets/ab_tooltip.dart';
import '../../../models/agent_event.dart';
import '../../../providers/now_ticker.dart';
import '../../../util/relative_time.dart';
import '../markdown_body.dart';
import '../selection/block_source.dart';
import '../selection/transcript_selection_scope.dart';
import '../transcript_rows.dart';
import 'usage_footer_row.dart';

const _kUserCollapseLines = 8;
// A long single wrapped line has no newlines to count, so also collapse past a
// rough character budget (~8 lines of wrapped prose) — otherwise a pasted URL
// or minified blob overflows the line cap uncollapsed.
const _kUserCollapseChars = 400;

class MessageRow extends StatefulWidget {
  final MessageRowData data;
  final int rowIndex;
  final VoidCallback? onRevert;
  const MessageRow({
    super.key,
    required this.data,
    required this.rowIndex,
    this.onRevert,
  });

  @override
  State<MessageRow> createState() => _MessageRowState();
}

class _MessageRowState extends State<MessageRow> {
  bool _expanded = false;

  // Copy source = what's on screen. When collapsed, the widget clips to
  // _kUserCollapseLines (unrendered tail is unselectable), so a cross-block
  // selection must not leak the hidden tail into Markdown/HTML output. Read at
  // copy time (via the lazy sourceBuilder) so expanding widens the copy too.
  // Approximate: line/char preview vs the renderer's wrapped-line clip.
  String _visibleText(String text, bool collapsible) {
    if (!collapsible || _expanded) return text;
    final preview = text.split('\n').take(_kUserCollapseLines).join('\n');
    if (preview.length <= _kUserCollapseChars) return preview;
    // Don't slice through a surrogate pair (an emoji straddling the budget) —
    // a lone surrogate corrupts the copied text.
    var end = _kUserCollapseChars;
    final unit = preview.codeUnitAt(end - 1);
    if (unit >= 0xD800 && unit <= 0xDBFF) end -= 1;
    return preview.substring(0, end);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.antgrid;
    final text = widget.data.item.text ?? '';
    if (!widget.data.isUser) {
      return Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AbTokens.space8,
          vertical: AbTokens.space4,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableBlock(
              order: widget.rowIndex * 1000,
              sourceBuilder: () => assistantSource(text),
              child: TranscriptMarkdown(data: text),
            ),
            _MessageMetaRow(
              when: widget.data.timestamp,
              usage: widget.data.usage,
            ),
          ],
        ),
      );
    }

    final lines = '\n'.allMatches(text).length + 1;
    final collapsible =
        lines > _kUserCollapseLines || text.length > _kUserCollapseChars;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AbTokens.space8,
        vertical: AbTokens.space4,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(AbTokens.space8),
            decoration: BoxDecoration(
              color: c.bgElevated,
              border: Border(left: BorderSide(color: c.accent, width: 2)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableBlock(
                  order: widget.rowIndex * 1000,
                  sourceBuilder: () =>
                      plainTextSource(_visibleText(text, collapsible)),
                  child: Text(
                    text,
                    maxLines: collapsible && !_expanded
                        ? _kUserCollapseLines
                        : null,
                    overflow: collapsible && !_expanded
                        ? TextOverflow.fade
                        : TextOverflow.visible,
                    style: AbTokens.sansStyle(
                      fontSize: AbTokens.fontMd,
                      color: c.textPrimary,
                    ),
                  ),
                ),
                if (collapsible)
                  // Chrome, not content: keep the toggle label out of any
                  // selection that spans this row (matches tool_call_card's
                  // Show-all buttons).
                  SelectionContainer.disabled(
                    child: GestureDetector(
                      onTap: () => setState(() => _expanded = !_expanded),
                      child: Padding(
                        padding: const EdgeInsets.only(top: AbTokens.space4),
                        child: Text(
                          _expanded ? 'Show less' : 'Show more',
                          style: AbTokens.sansStyle(
                            fontSize: AbTokens.fontSm,
                            color: c.accent,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          _MessageMetaRow(
            when: widget.data.timestamp,
            actions: [
              if (widget.onRevert != null)
                AbIconButton(
                  icon: AbIcons.revert,
                  tone: AbIconButtonTone.muted,
                  tooltip: 'Revert conversation',
                  onTap: widget.onRevert,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Relative-time/usage/action line under a message, refreshing relative time on
/// the minute via [nowMinuteProvider]. Renders nothing until metadata exists.
class _MessageMetaRow extends ConsumerWidget {
  final DateTime? when;
  final AgentTokenUsage? usage;
  final List<Widget> actions;
  const _MessageMetaRow({
    required this.when,
    this.usage,
    this.actions = const [],
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ts = when;
    final hasUsage = usage != null && UsageFooterRow.hasContent(usage!);
    if (ts == null && !hasUsage && actions.isEmpty) {
      return const SizedBox.shrink();
    }
    final c = context.antgrid;
    final now = ref.watch(nowMinuteProvider).value ?? DateTime.now();
    // Chrome metadata: excluded from selection so a transcript copy that spans
    // this row never carries timestamps, token counts, or button labels.
    return SelectionContainer.disabled(
      child: Padding(
        padding: const EdgeInsets.only(top: AbTokens.space4),
        child: Row(
          children: [
            if (ts != null)
              AbTooltip(
                message: absoluteTime(ts),
                child: Text(
                  relativeTime(ts, now: now),
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontSm,
                    color: c.textMuted,
                  ),
                ),
              )
            else
              const SizedBox.shrink(),
            if (hasUsage) ...[
              if (ts != null) const SizedBox(width: AbTokens.space8),
              Expanded(child: UsageFooterRow(usage: usage!)),
            ],
            if (actions.isNotEmpty) ...[
              if (!hasUsage) const Spacer(),
              Row(mainAxisSize: MainAxisSize.min, children: actions),
            ],
          ],
        ),
      ),
    );
  }
}
