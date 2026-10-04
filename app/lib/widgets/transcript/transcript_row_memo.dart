import 'package:flutter/widgets.dart';

import '../../design/ab_tokens.dart';
import 'transcript_rows.dart';

/// Whether two rows would build identical widgets, so a widget built for [a]
/// can stand in for [b].
///
/// Items are compared by identity: AgentSessionService replaces an item object
/// whenever it changes and never mutates one it has published, so an unchanged
/// item keeps its instance even while a later item in the same turn streams —
/// which is what lets the rows of a still-open turn be reused. A field added to
/// a row class belongs in this comparison.
bool sameRowInputs(TranscriptRow a, TranscriptRow b) {
  if (identical(a, b)) return true;
  return switch ((a, b)) {
    (MessageRowData a, MessageRowData b) =>
      identical(a.item, b.item) &&
          a.turnId == b.turnId &&
          a.isUser == b.isUser &&
          a.timestamp == b.timestamp &&
          identical(a.usage, b.usage),
    (ReasoningRowData a, ReasoningRowData b) =>
      identical(a.item, b.item) && a.isStreaming == b.isStreaming,
    (ToolCallRowData a, ToolCallRowData b) => identical(a.item, b.item),
    (PlanRowData a, PlanRowData b) => identical(a.item, b.item),
    (SubtaskRowData a, SubtaskRowData b) => identical(a.item, b.item),
    (CompactionRowData a, CompactionRowData b) => identical(a.item, b.item),
    (UnknownRowData a, UnknownRowData b) => identical(a.item, b.item),
    (TurnFoldRowData a, TurnFoldRowData b) =>
      a.turnId == b.turnId &&
          a.hiddenCount == b.hiddenCount &&
          a.hasError == b.hasError &&
          a.cancelled == b.cancelled &&
          a.duration == b.duration,
    (WorkingRowData a, WorkingRowData b) =>
      a.turnId == b.turnId &&
          a.startedAt == b.startedAt &&
          a.waitingOnUser == b.waitingOnUser,
    (ErrorRowData a, ErrorRowData b) =>
      a.turnId == b.turnId && identical(a.error, b.error),
    (PromptMarkerRowData a, PromptMarkerRowData b) =>
      a.id == b.id && a.isPermission == b.isPermission,
    (UsageRowData a, UsageRowData b) =>
      a.anchorKey == b.anchorKey && identical(a.usage, b.usage),
    _ => false,
  };
}

class _Entry {
  _Entry(this.row, this.rowIndex, this.variant, this.weightOffset, this.widget);

  final TranscriptRow row;
  final int rowIndex;
  final int variant;
  final int weightOffset;
  final Widget widget;
}

/// Hands back the identical row widget while nothing it was built from moved.
///
/// SliverChildBuilderDelegate.shouldRebuild is always true, so every rebuild of
/// the list re-runs the item builder for each visible row; returning the same
/// instance lets Element.updateChild skip the row's subtree instead of
/// rebuilding it (and re-parsing a message's markdown) on every streamed delta
/// of some other row. Rows read the theme through their own context
/// dependencies, so a palette switch still restyles a reused widget.
///
/// The builder may close over whatever the first build saw (callbacks resolve
/// rows by id through the State), but anything that changes the built widget
/// and is not in the row itself has to be part of the key: [variant] carries
/// the caller's per-row flags, and the font-weight offset is a static no
/// dependency tracks.
class TranscriptRowWidgetMemo {
  final _entries = <String, _Entry>{};

  /// How many rows have a remembered widget.
  int get length => _entries.length;

  Widget widgetFor(
    TranscriptRow row,
    int rowIndex,
    int variant,
    Widget Function() build,
  ) {
    final weightOffset = AbTokens.activeWeightOffset;
    final hit = _entries[row.rowKey];
    if (hit != null &&
        hit.rowIndex == rowIndex &&
        hit.variant == variant &&
        hit.weightOffset == weightOffset &&
        sameRowInputs(hit.row, row)) {
      return hit.widget;
    }
    final widget = build();
    _entries[row.rowKey] = _Entry(row, rowIndex, variant, weightOffset, widget);
    return widget;
  }

  /// Forgets rows that left the list, so a long session's memo does not pin the
  /// widgets (and their items) of rows that no longer exist.
  void retainOnly(List<TranscriptRow> rows) {
    if (_entries.isEmpty) return;
    final live = {for (final r in rows) r.rowKey};
    _entries.removeWhere((key, _) => !live.contains(key));
  }

  void clear() => _entries.clear();
}
