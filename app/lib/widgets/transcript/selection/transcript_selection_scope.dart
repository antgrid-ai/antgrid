import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'block_source.dart';
import 'copy_resolver.dart';
import 'transcript_clipboard.dart';

/// A live registration for one on-screen [SelectableBlock]. [order] and
/// [sourceBuilder] are mutable so a streaming block can update them per build
/// without re-registering.
class BlockHandle {
  int order;
  BlockSource Function() sourceBuilder;
  final SelectionListenerNotifier notifier;
  // Registration sequence: a deterministic tie-break so two blocks that resolve
  // to the same [order] (e.g. a row overflowing the order stride) never sort in
  // arbitrary set-iteration order.
  final int seq;
  BlockHandle(this.order, this.sourceBuilder, this.notifier, this.seq);
}

/// A touched block: its document [order] plus a thunk to rebuild its source.
/// Captured cheaply on each selection change (no source building) so a copy can
/// still be resolved after the live selection is gone — see
/// [TranscriptSelectionController]. The selected sub-range is not kept: copy
/// output never slices a block (see copy_resolver).
class _TouchedRange {
  final BlockSource Function() sourceBuilder;
  final int order;
  _TouchedRange(this.sourceBuilder, this.order);
}

/// Owns the set of currently-mounted selectable blocks and the latest native
/// plain-text selection, and builds copy output on demand. Not a Listenable —
/// nothing rebuilds on selection; output is pulled only when a copy action fires.
class TranscriptSelectionController {
  TranscriptSelectionController({TranscriptClipboardSink? sink})
      : _sink = sink ?? const SuperClipboardSink();

  final TranscriptClipboardSink _sink;
  final _handles = <BlockHandle>{};
  int _seq = 0;
  String _nativePlain = '';

  // Last non-empty selection. Opening the context menu with a right-click
  // collapses the live SelectableRegion selection (Flutter's secondary-tap
  // behavior, selectable_region.dart) *before* the menu's Copy action runs, so
  // the live ranges would read empty at copy time. We keep the last non-empty
  // snapshot — ranges only, sources built lazily at copy time to keep
  // selection-drag off the source-building path — and fall back to it.
  ({String nativePlain, List<_TouchedRange> ranges}) _lastNonEmpty =
      (nativePlain: '', ranges: const []);

  /// Records the ambient selection on every change: the native plain text, plus
  /// a snapshot of the touched-block ranges whenever the selection is non-empty.
  void onSelectionChanged(String? plainText) {
    _nativePlain = plainText ?? '';
    final ranges = _touchedRanges();
    if (ranges.isNotEmpty || _nativePlain.isNotEmpty) {
      _lastNonEmpty = (nativePlain: _nativePlain, ranges: ranges);
    }
  }

  BlockHandle register({
    required int order,
    required BlockSource Function() sourceBuilder,
    required SelectionListenerNotifier notifier,
  }) {
    final handle = BlockHandle(order, sourceBuilder, notifier, _seq++);
    _handles.add(handle);
    return handle;
  }

  void unregister(BlockHandle handle) => _handles.remove(handle);

  /// Touched blocks (non-empty local range), sorted by document order.
  /// [_TouchedRange.sourceBuilder] is captured but not invoked here.
  List<_TouchedRange> _touchedRanges() {
    // Sort handles before reading ranges: primary by [order] (document order),
    // then by registration [seq] so equal orders are deterministic.
    final live = _handles.where((h) => h.notifier.registered).toList()
      ..sort((a, b) {
        final byOrder = a.order.compareTo(b.order);
        return byOrder != 0 ? byOrder : a.seq.compareTo(b.seq);
      });
    final out = <_TouchedRange>[];
    for (final handle in live) {
      // Reading .selection throws unless the notifier is registered to a live
      // SelectionListener; an off-screen (disposed) block is simply skipped.
      final range = handle.notifier.selection.range;
      if (range == null) continue;
      final start = math.min(range.startOffset, range.endOffset);
      final end = math.max(range.startOffset, range.endOffset);
      if (start == end) continue;
      out.add(_TouchedRange(handle.sourceBuilder, handle.order));
    }
    return out;
  }

  Future<void> copy(CopyKind kind) async {
    // Prefer the live selection; fall back to the last non-empty snapshot when a
    // right-click has collapsed it out from under the context menu. Key the
    // fallback off the snapshot HAVING block ranges, not off `_nativePlain`
    // being empty: the collapse doesn't always refresh `_nativePlain` to empty
    // first, so gating on it would let a rich copy silently degrade to plain. A
    // genuine block-free selection (no snapshot ranges) keeps its live plain.
    var ranges = _touchedRanges();
    var nativePlain = _nativePlain;
    if (ranges.isEmpty && _lastNonEmpty.ranges.isNotEmpty) {
      ranges = _lastNonEmpty.ranges;
      nativePlain = _lastNonEmpty.nativePlain;
    }
    final touched = [
      for (final r in ranges)
        BlockSelection(source: r.sourceBuilder(), order: r.order),
    ];
    final out = resolveCopy(touched, nativePlain);
    if (out.plain.isEmpty && out.markdown.isEmpty) return;
    await _sink.write(kind, out);
  }
}

class TranscriptSelectionScope extends InheritedWidget {
  const TranscriptSelectionScope({
    super.key,
    required this.controller,
    required super.child,
  });

  final TranscriptSelectionController controller;

  static TranscriptSelectionController of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<TranscriptSelectionScope>();
    assert(scope != null, 'No TranscriptSelectionScope found in context');
    return scope!.controller;
  }

  @override
  bool updateShouldNotify(TranscriptSelectionScope oldWidget) =>
      controller != oldWidget.controller;
}

/// Wraps one copyable leaf: owns a [SelectionListener] so its local selected
/// range is recoverable under the ambient [SelectionArea], and registers a
/// [BlockSource] with the [TranscriptSelectionController]. The [child] stays
/// plain (Text/Text.rich/MarkdownBlock) so it composes into the SelectionArea.
class SelectableBlock extends StatefulWidget {
  const SelectableBlock({
    super.key,
    required this.order,
    required this.sourceBuilder,
    required this.child,
  });

  final int order;
  final BlockSource Function() sourceBuilder;
  final Widget child;

  @override
  State<SelectableBlock> createState() => _SelectableBlockState();
}

class _SelectableBlockState extends State<SelectableBlock> {
  final _notifier = SelectionListenerNotifier();
  TranscriptSelectionController? _controller;
  BlockHandle? _handle;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = TranscriptSelectionScope.of(context);
    if (!identical(controller, _controller)) {
      if (_handle != null) _controller?.unregister(_handle!);
      _controller = controller;
      _handle = controller.register(
        order: widget.order,
        sourceBuilder: widget.sourceBuilder,
        notifier: _notifier,
      );
    }
  }

  @override
  void didUpdateWidget(SelectableBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Streaming rows rebuild with fresh text/order — keep the live handle current
    // without churning the registration (and its notifier binding).
    _handle?.order = widget.order;
    _handle?.sourceBuilder = widget.sourceBuilder;
  }

  @override
  void dispose() {
    if (_handle != null) _controller?.unregister(_handle!);
    _notifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      SelectionListener(selectionNotifier: _notifier, child: widget.child);
}
