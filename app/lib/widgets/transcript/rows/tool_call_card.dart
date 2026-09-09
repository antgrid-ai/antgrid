import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../design/ab_colors.dart';
import '../../../design/ab_icons.dart';
import '../../../design/ab_tokens.dart';
import '../../../design/widgets/ab_icon.dart';
import '../../../design/widgets/ab_icon_button.dart';
import '../../../design/widgets/ab_list_row.dart';
import '../../../models/agent_event.dart';
import '../diff_view.dart';
import '../selection/block_source.dart';
import '../selection/transcript_selection_scope.dart';
import '../status_glyph.dart';
import '../transcript_rows.dart';

const _kTerminalTailLines = 40;
const _kRawJsonClip = 4096;

class ToolCallCard extends StatefulWidget {
  final ToolCallRowData data;
  final int rowIndex;
  final bool expanded;

  /// Whether this item is one of the session's live background tasks, per the
  /// advertised agent:background-tasks list — the only thing that knows. It is
  /// not readable off the item: codex stamps a pid on every unified-exec
  /// command, foreground ones included, and cannot tell background from
  /// foreground until a turn ends with the process still alive.
  final bool isBackground;
  final VoidCallback onToggle;

  /// Opens a checkout-relative path (a diff block's [ToolContent.path]) in the
  /// context panel's file viewer — any type the viewer supports, images
  /// included, since it routes through the same file-open path as every other
  /// file-explorer selection. Null on a surface with no context panel to open
  /// it in.
  final void Function(String path)? onOpenPath;
  const ToolCallCard({
    super.key,
    required this.data,
    required this.rowIndex,
    required this.expanded,
    required this.isBackground,
    required this.onToggle,
    this.onOpenPath,
  });

  @override
  State<ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<ToolCallCard> {
  bool _showAllOutput = false;
  final _expandedJson = <String>{};
  // computeLineDiff is O(n·m) and the list rebuilds on every state emission;
  // cache per content object so an expanded card never re-diffs per frame.
  final _diffCache = <ToolContent, List<DiffLine>>{};

  @override
  Widget build(BuildContext context) {
    final c = context.antgrid;
    final item = widget.data.item;
    final hasBody = _hasBody(item);
    final failed = item.error != null || item.status == 'error';
    final showBody = (widget.expanded && hasBody) || item.error != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AbListRow(
          density: AbRowDensity.sm,
          onTap: hasBody ? widget.onToggle : null,
          leading: AbIcon(
            _kindIcon(item.toolKind),
            size: AbTokens.fontMd,
            color: c.textMuted,
          ),
          title: Text(
            item.title ?? item.toolKind ?? 'tool',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AbTokens.monoStyle(
              fontSize: AbTokens.fontSm,
              color: failed ? c.error : c.textSecondary,
            ),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.isBackground) ...[
                Text(
                  'bg',
                  style: AbTokens.monoStyle(
                    fontSize: AbTokens.fontXs,
                    color: c.accent,
                  ),
                ),
                const SizedBox(width: AbTokens.space4),
              ],
              if (hasBody)
                AbIcon(
                  widget.expanded ? AbIcons.chevronDown : AbIcons.chevronRight,
                  size: AbTokens.fontSm,
                  color: c.textMuted,
                ),
              const SizedBox(width: AbTokens.space4),
              statusGlyph(item.status, c),
            ],
          ),
        ),
        if (showBody) _body(context, item),
      ],
    );
  }

  bool _hasBody(AgentItem item) =>
      (item.content?.isNotEmpty ?? false) ||
      item.rawInput != null ||
      item.rawOutput != null;

  Widget _body(BuildContext context, AgentItem item) {
    final c = context.antgrid;
    final children = <Widget>[];

    // The service replaces ToolContent objects per delta, so cache entries keyed
    // by an old block's identity would never be reused and never freed. Drop any
    // that aren't in the current content list to bound the cache to live blocks.
    final live = item.content ?? const <ToolContent>[];
    _diffCache.removeWhere((block, _) => !live.contains(block));

    var blockIndex = 0;
    SelectableBlock wrap(BlockSource Function() src, Widget child) =>
        SelectableBlock(
          order: widget.rowIndex * 1000 + blockIndex++,
          sourceBuilder: src,
          child: child,
        );

    // Wrapped like every other body block so a cross-block copy carries the
    // error text in Markdown/HTML too, not just the plain-text native path.
    if (item.error != null) {
      final message = item.error!.message;
      children.add(
        wrap(
          () => plainTextSource(message),
          Text(
            message,
            style: AbTokens.monoStyle(
              fontSize: AbTokens.fontSm,
              color: c.error,
            ),
          ),
        ),
      );
    }

    for (final block in item.content ?? const <ToolContent>[]) {
      switch (block.type) {
        case 'terminal':
          final data = block.data ?? '';
          // Source = the visible tail (recomputed at copy time, so expanding
          // "Show all" widens the copy too); the widget renders that same tail.
          children.add(
            wrap(() => codeSource(_terminalVisible(data)), _terminal(data, c)),
          );
        case 'diff':
          children.add(
            wrap(
              () => diffSource(
                _diffCache.putIfAbsent(block, () => diffLinesFor(block)),
              ),
              _diff(block, c),
            ),
          );
        case 'text':
          final txt = block.text ?? '';
          children.add(
            wrap(
              () => codeSource(txt),
              Text(
                txt,
                style: AbTokens.monoStyle(
                  fontSize: AbTokens.fontSm,
                  color: c.textSecondary,
                ),
              ),
            ),
          );
      }
    }
    if (item.rawInput != null) {
      children.add(
        wrap(
          () => codeSource(
            _jsonVisible('input', item.rawInput!),
            language: 'json',
          ),
          _json('input', item.rawInput!, c),
        ),
      );
    }
    if (item.rawOutput != null) {
      children.add(
        wrap(
          () => codeSource(
            _jsonVisible('output', item.rawOutput!),
            language: 'json',
          ),
          _json('output', item.rawOutput!, c),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.only(
        left: AbTokens.space16,
        right: AbTokens.space8,
        bottom: AbTokens.space4,
      ),
      padding: const EdgeInsets.all(AbTokens.space8),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: c.borderDefault, width: 2)),
        color: c.bgElevated,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(height: AbTokens.space6),
            children[i],
          ],
        ],
      ),
    );
  }

  // Visible tail = exactly what the widget renders; drives both the on-screen
  // Text and the copy source so selection copy and the screen stay in lockstep.
  String _terminalVisible(String data) {
    final lines = data.split('\n');
    final truncated = !_showAllOutput && lines.length > _kTerminalTailLines;
    return (truncated
            ? lines.sublist(lines.length - _kTerminalTailLines)
            : lines)
        .join('\n');
  }

  Widget _terminal(String data, AbColors c) {
    final lines = data.split('\n');
    final truncated = !_showAllOutput && lines.length > _kTerminalTailLines;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (truncated)
          SelectionContainer.disabled(
            child: GestureDetector(
              onTap: () => setState(() => _showAllOutput = true),
              child: Text(
                'Show all (${lines.length} lines)',
                style: AbTokens.monoStyle(
                  fontSize: AbTokens.fontXs,
                  color: c.accent,
                ),
              ),
            ),
          ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Text(
            _terminalVisible(data),
            style: AbTokens.monoStyle(
              fontSize: AbTokens.fontSm,
              color: c.textSecondary,
            ),
          ),
        ),
      ],
    );
  }

  Widget _diff(ToolContent block, AbColors c) {
    final lines = _diffCache.putIfAbsent(block, () => diffLinesFor(block));
    var adds = 0, dels = 0;
    for (final l in lines) {
      if (l.op == DiffOp.add) adds++;
      if (l.op == DiffOp.del) dels++;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectionContainer.disabled(
          child: Row(
            children: [
              if (block.path != null) Expanded(child: _diffPathLabel(block.path!, c)),
              Text(
                '+$adds ',
                style: AbTokens.monoStyle(
                  fontSize: AbTokens.fontXs,
                  color: c.success,
                ),
              ),
              Text(
                '−$dels',
                style: AbTokens.monoStyle(
                  fontSize: AbTokens.fontXs,
                  color: c.error,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AbTokens.space4),
        DiffView(lines: lines),
      ],
    );
  }

  // Same affordance as the "Show all" toggles below (accent color, click
  // cursor) — falls back to plain muted text when nothing above wired
  // [ToolCallCard.onOpenPath] (no context panel on this surface).
  Widget _diffPathLabel(String path, AbColors c) {
    final onOpenPath = widget.onOpenPath;
    final text = Text(
      path,
      overflow: TextOverflow.ellipsis,
      style: AbTokens.monoStyle(
        fontSize: AbTokens.fontXs,
        color: onOpenPath == null ? c.textMuted : c.accent,
      ),
    );
    if (onOpenPath == null) return text;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(onTap: () => onOpenPath(path), child: text),
    );
  }

  String _prettyJson(Object value) {
    try {
      return const JsonEncoder.withIndent('  ').convert(value);
    } catch (_) {
      return value.toString();
    }
  }

  // Visible (possibly clipped) JSON = what the widget renders; drives the copy
  // source so selection copy matches the screen. Reads _expandedJson so a
  // "Show all" expansion widens the copy at copy time.
  String _jsonVisible(String label, Object value) =>
      _clipJson(label, _prettyJson(value));

  String _clipJson(String label, String pretty) {
    final clipped =
        pretty.length > _kRawJsonClip && !_expandedJson.contains(label);
    return clipped ? pretty.substring(0, _kRawJsonClip) : pretty;
  }

  Widget _json(String label, Object value, AbColors c) {
    final pretty = _prettyJson(value);
    final visible = _clipJson(label, pretty);
    final clipped = visible.length < pretty.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectionContainer.disabled(
          child: Row(
            children: [
              Text(
                label,
                style: AbTokens.monoStyle(
                  fontSize: AbTokens.fontXs,
                  color: c.textMuted,
                ),
              ),
              const Spacer(),
              AbIconButton(
                icon: AbIcons.copy,
                tone: AbIconButtonTone.muted,
                tooltip: 'Copy',
                onTap: () => Clipboard.setData(ClipboardData(text: pretty)),
              ),
            ],
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Text(
            visible,
            style: AbTokens.monoStyle(
              fontSize: AbTokens.fontSm,
              color: c.textSecondary,
            ),
          ),
        ),
        if (clipped)
          SelectionContainer.disabled(
            child: GestureDetector(
              onTap: () => setState(() => _expandedJson.add(label)),
              child: Text(
                'Show all (${pretty.length} chars)',
                style: AbTokens.monoStyle(
                  fontSize: AbTokens.fontXs,
                  color: c.accent,
                ),
              ),
            ),
          ),
      ],
    );
  }

  String _kindIcon(String? toolKind) => switch (toolKind) {
    'edit' => AbIcons.files,
    'read' => AbIcons.files,
    'mcp' => AbIcons.server,
    'search' => AbIcons.search,
    _ => AbIcons.terminal,
  };
}
