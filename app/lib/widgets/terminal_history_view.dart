// The archived-scrollback reader for a frame-mode terminal.
//
// Rendered through a SECOND Ghostty engine rather than a Flutter text list: the
// app has no SGR parser, and archived rows carry their attributes as verbatim
// SGR precisely so nothing downstream has to reconstruct them. Handing them
// back to a terminal engine is what buys OSC 8 hyperlinks, wide characters,
// selection and copy for free -- and pixel parity with the live pane, which is
// the whole point of a surface the user reads as "the same terminal, further
// up".
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/ansi_palette.dart';
import '../design/widgets/ab_empty_state.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_inline_banner.dart';
import '../design/widgets/ab_loading.dart';
import '../models/ab_message.dart';
import '../models/terminal_history_model.dart';

/// The SGR a cell with no attributes at all serializes to (`xterm-adapter.ts`
/// always opens with `0`), and so the only style whose trailing blanks are
/// padding rather than content.
const String _sgrReset = '\x1b[0m';

/// A uri carrying any of these would terminate the OSC 8 it is written into and
/// leave the rest of it parsed as escapes. The agent's own Zod schema rejects
/// them, but this side parses history without that check, so the escape
/// sequence this file builds cannot be the place that trusts it.
final RegExp _uriControlChars = RegExp(r'[\x00-\x1f\x7f-\x9f]');

// Keep native headroom above the rendered window: resizing can briefly reflow
// the old window before the pane replaces it with one sized for the new grid.
const int _historyEngineMaxLines = 8000;
const int _historyRenderMaxLines = 6000;

/// Encodes archived rows as terminal output a VT engine can ingest.
///
/// Rows are re-joined into LOGICAL lines: `wrapped` means "this row continues
/// the one above" (xterm's own sense, mirrored on the wire), so a newline is
/// written only BEFORE a row that starts a line of its own. The engine then
/// re-wraps at the pane's current width, which is what keeps a copied line whole
/// and stops an 80-column archive from breaking mid-word in a 200-column pane.
///
/// Trailing blanks are dropped from every row that ENDS a logical line: the
/// agent pads each archived row out to its full `cols`, and unpadded those
/// blanks re-wrap into empty lines in any narrower pane. Only default-styled
/// blanks go -- a trailing block the TUI painted is content, not padding.
@visibleForTesting
Uint8List encodeTerminalHistoryRows(List<TerminalHistoryRow> rows) {
  final buffer = StringBuffer();
  for (var i = 0; i < rows.length; i++) {
    final row = rows[i];
    if (i > 0 && !row.wrapped) buffer.write('\r\n');
    final endsLine = i == rows.length - 1 || !rows[i + 1].wrapped;
    _writeRow(buffer, row, endsLine: endsLine);
  }
  return Uint8List.fromList(utf8.encode(buffer.toString()));
}

void _writeRow(
  StringBuffer buffer,
  TerminalHistoryRow row, {
  required bool endsLine,
}) {
  final parts = <(String sgr, String? uri, String text)>[
    for (final span in row.spans)
      (
        span.sgr,
        span.uri != null && !_uriControlChars.hasMatch(span.uri!)
            ? span.uri
            : null,
        span.text,
      ),
  ];
  if (endsLine) _trimTrailingBlanks(parts);

  String? openUri;
  for (final (sgr, uri, text) in parts) {
    if (uri != openUri) {
      buffer.write('\x1b]8;;${uri ?? ''}\x1b\\');
      openUri = uri;
    }
    buffer
      ..write(sgr)
      ..write(text);
  }
  // A hyperlink left open would swallow the next row, and the reset stops a
  // trailing background from bleeding to the end of the re-wrapped line.
  if (openUri != null) buffer.write('\x1b]8;;\x1b\\');
  buffer.write(_sgrReset);
}

void _trimTrailingBlanks(List<(String, String?, String)> parts) {
  while (parts.isNotEmpty) {
    final (sgr, uri, text) = parts.last;
    if (uri != null || sgr != _sgrReset) return;
    var end = text.length;
    while (end > 0 && text.codeUnitAt(end - 1) == 0x20) {
      end--;
    }
    if (end == text.length) return;
    parts.removeLast();
    if (end > 0) {
      parts.add((sgr, uri, text.substring(0, end)));
      return;
    }
  }
}

/// One frame-mode terminal's archived scrollback, paged backwards.
///
/// Owns the engine and the paging trigger; owns none of the wire. [onLoadMore]
/// is the host asking the agent for the next page, and [model] is where the
/// answer shows up -- so this widget can be driven end to end by a test that
/// applies pages to the model directly.
class TerminalHistoryView extends StatefulWidget {
  const TerminalHistoryView({
    super.key,
    required this.model,
    required this.onLoadMore,
    required this.onClose,
    required this.fontSize,
    required this.fontWeight,
    required this.boldFontWeight,
    required this.minimumContrastRatio,
    this.onOpenHyperlink,
    this.onHyperlinkHover,
    this.initialRowId,
    this.screenRows = const [],
    this.onPosition,
    this.onInput,
    this.historyEndRow,
    this.softKeyboardController,
  });

  final TerminalHistoryModel model;

  /// Asks the host for one more page. Safe to call when there is nothing to
  /// ask for -- the model refuses a second in-flight request itself.
  final VoidCallback onLoadMore;

  final VoidCallback onClose;
  final int? initialRowId;
  final List<TerminalHistoryRow> screenRows;
  final ValueChanged<int>? onPosition;
  final ValueChanged<String>? onInput;
  final int? historyEndRow;
  final GhosttyTerminalSoftKeyboardController? softKeyboardController;

  /// The live pane's own measured type, passed in rather than re-derived, so
  /// zoom and the UI Size setting land on both surfaces identically. Every
  /// other visual (palette, contrast floor, cell alignment) is taken from the
  /// same helpers the live pane uses; keep the two in step or scrolling up
  /// changes how the terminal looks.
  final double fontSize;
  final FontWeight fontWeight;
  final FontWeight boldFontWeight;
  final double minimumContrastRatio;

  final Future<void> Function(String uri)? onOpenHyperlink;
  final ValueChanged<String?>? onHyperlinkHover;

  @override
  State<TerminalHistoryView> createState() => TerminalHistoryViewState();
}

class TerminalHistoryViewState extends State<TerminalHistoryView> {
  KeyEventResult navigate(KeyEvent event) => _onKey(_focusNode, event);
  late final GhosttyTerminalController _controller;
  final ScrollController _scrollController = ScrollController();
  final _viewKey = GlobalKey();

  /// The reader's own focus, taken on mount -- a click inside the transcript
  /// then moves it on to the engine.
  ///
  /// It has to be TAKEN rather than autofocused: the reader mounts over a live
  /// pane that already holds the focus of the scope they share, and
  /// `Focus.autofocus` applies only while that scope has no focused child --
  /// so without this every key would go on reaching the pane underneath.
  final FocusNode _focusNode = FocusNode(debugLabel: 'TerminalHistoryView');

  /// What the engine currently holds, so a model notification that changed only
  /// the boundary or the loading flag does not rebuild it.
  (int firstRowId, int lastRowId, int count)? _rendered;
  List<TerminalHistoryRow> _renderedRows = const [];

  /// Where to put the viewport back once the re-ingested rows have settled,
  /// in ENGINE rows above the live bottom. See [_restoreScrollOffset] for why
  /// this has to be the engine's own row count and not a Flutter pixel
  /// offset.
  int? _pendingRestoreRows;
  Timer? _restoreExpiry;
  int? _targetRow;
  bool _restoring = false;
  int? _lastPosition;
  List<int> _lineStarts = const [];
  double? _lastScrollPixels;
  int? _prefetchedCursor;
  final _selectionController = GhosttyTerminalSelectionController();
  bool _hasSelection = false;
  int? _measuredCols;
  int _anchorLineOffset = 0;

  void _towardLive() {
    if (_hasSelection ||
        widget.model.loading ||
        _targetRow != null ||
        _pendingRestoreRows != null) {
      return;
    }
    final end = widget.historyEndRow ?? widget.model.boundary?.nextRowId;
    if (end == null || widget.model.rows.isEmpty) return;
    if (_renderedRows.isNotEmpty &&
        _renderedRows.last.rowId < widget.model.rows.last.rowId) {
      _recenterWindow();
      return;
    }
    if (widget.model.rows.last.rowId >= end - 1) {
      widget.onClose();
    } else {
      _targetRow = _lastPosition ?? widget.model.rows.last.rowId;
      widget.model.seek(
        math.min(end, widget.model.rows.last.rowId + 101),
        newer: true,
      );
      widget.onLoadMore();
    }
  }

  void _recenterWindow() {
    final anchor = _lastPosition;
    if (anchor == null) return;
    final lineOffset = _anchorLineOffset;
    _targetRow = anchor;
    setState(() => _syncEngine(preserveOffset: false));
    _restoreTarget();
    _restoring = true;
    _controller.scrollViewportByRows(-lineOffset);
    _restoring = false;
    _anchorLineOffset = lineOffset;
  }

  void seekRow(int rowId) {
    if (_hasSelection) _selectionController.clear();
    _targetRow = rowId;
    final rows = widget.model.rows;
    if (rows.isNotEmpty &&
        rowId >= rows.first.rowId &&
        rowId <= rows.last.rowId) {
      widget.model.retainWindow();
      if (_renderedRows.isEmpty ||
          rowId < _renderedRows.first.rowId ||
          rowId > _renderedRows.last.rowId) {
        setState(() => _syncEngine(preserveOffset: false));
      }
      _restoreTarget();
    } else {
      widget.model.seek(
        math.min(
          rowId + 100,
          widget.historyEndRow ?? widget.model.boundary!.nextRowId,
        ),
        newer: rows.isNotEmpty && rowId > rows.last.rowId,
      );
      widget.onLoadMore();
    }
  }

  void _restoreTarget() {
    final target = _targetRow;
    if (target == null || _renderedRows.isEmpty) return;
    if (target < _renderedRows.first.rowId) {
      if (!widget.model.loading) {
        widget.model.seek(target + 1);
        widget.onLoadMore();
      }
      return;
    }
    final index = _renderedRows.indexWhere((r) => r.rowId >= target);
    if (index < 0) return;
    _restoring = true;
    final before = _lineStarts[index];
    final bar = _controller.viewportScrollbar;
    if (bar != null) {
      _armRestore(null);
      _controller.scrollViewportToOffsetFromBottom(
        math.max(0, bar.total - bar.length - before),
      );
      _lastPosition = target;
      _anchorLineOffset = 0;
      _targetRow = null;
    }
    _restoring = false;
  }

  void _onScrollChanged() {
    if (_restoring ||
        _targetRow != null ||
        _pendingRestoreRows != null ||
        _renderedRows.isEmpty) {
      return;
    }
    final pixels = _scrollController.hasClients
        ? _scrollController.offset
        : null;
    final towardLive =
        pixels != null &&
        _lastScrollPixels != null &&
        pixels < _lastScrollPixels!;
    _lastScrollPixels = pixels;
    final bar = _controller.viewportScrollbar;
    if (bar == null) return;
    // The first retained row anchors the loaded window independently of the
    // archive-sized scrollbar. Resolve wrapping only within this bounded window.
    var low = 0;
    var high = _renderedRows.length - 1;
    while (low < high) {
      final mid = (low + high + 1) ~/ 2;
      if (_lineStarts[mid] <= bar.offset) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    final row = _renderedRows[math.min(low, _renderedRows.length - 1)].rowId;
    _anchorLineOffset = bar.offset - _lineStarts[low];
    if (row != _lastPosition) {
      _lastPosition = row;
      widget.onPosition?.call(row);
    }
    if (!towardLive &&
        !_hasSelection &&
        bar.offset <= 20 &&
        widget.model.rows.isNotEmpty &&
        _renderedRows.first.rowId == widget.model.rows.first.rowId &&
        widget.model.canLoadMore &&
        _prefetchedCursor != widget.model.cursor) {
      _prefetchedCursor = widget.model.cursor;
      widget.onLoadMore();
    }
    if (towardLive && bar.total - bar.length - bar.offset <= 1) _towardLive();
  }

  /// How long a pending restore may wait for the engine to grow into it.
  ///
  /// Held by a timer rather than checked inside the retry: the retry runs only
  /// when the engine notifies, so a rebuild that never grows the extent far
  /// enough emits nothing further to check a deadline from -- and a target
  /// left standing is applied to whatever the NEXT page puts on screen.
  static const Duration _restoreWindow = Duration(seconds: 2);

  @override
  void initState() {
    super.initState();
    _controller = GhosttyTerminalController(
      maxLines: _historyEngineMaxLines,
      maxScrollbackLines: _historyEngineMaxLines,
      maxScrollback: 64 << 20,
      // The view resizes its controller to the pane on its first layout, so
      // these are only what the rows are ingested against for the one frame
      // before that lands.
      initialCols: 80,
      initialRows: 24,
    );
    _controller.addListener(_onEngineChanged);
    if (widget.onInput != null) {
      _controller.attachExternalTransport(
        writeBytes: (bytes) {
          if (bytes.isEmpty) return false;
          widget.onInput!(utf8.decode(bytes));
          return true;
        },
        forwardGuestQueryReplies: false,
      );
    }
    _scrollController.addListener(_onScrollChanged);
    widget.model.addListener(_onModelChanged);
    _syncEngine(preserveOffset: false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusNode.requestFocus();
      if (widget.initialRowId case final row?) seekRow(row);
    });
    _scheduleOpeningPage();
  }

  @override
  void didUpdateWidget(TerminalHistoryView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.model == widget.model) return;
    oldWidget.model.removeListener(_onModelChanged);
    widget.model.addListener(_onModelChanged);
    // A different terminal's archive: where the reader had got to in this one
    // describes nothing in that one.
    _syncEngine(preserveOffset: false);
    // The swapped-in archive gets the same opening request a freshly mounted
    // reader gets -- a reused terminal id handed a new run arrives here rather
    // than through initState, and the reader stays on screen throughout.
    _scheduleOpeningPage();
  }

  void _scheduleOpeningPage() {
    final model = widget.model;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.model != model) return;
      if (widget.initialRowId == null) model.prepareLatestWindow();
      if (model.rows.isEmpty && model.canLoadMore) widget.onLoadMore();
    });
  }

  @override
  void dispose() {
    widget.model.removeListener(_onModelChanged);
    _controller.removeListener(_onEngineChanged);
    _restoreExpiry?.cancel();
    _controller.dispose();
    _scrollController.dispose();
    // Releases the focus taken on mount; the host restores the live pane's.
    _focusNode.dispose();
    super.dispose();
  }

  void _onModelChanged() {
    if (!mounted) return;
    final boundary = widget.model.boundary;
    if (boundary != null &&
        _targetRow != null &&
        _targetRow! < boundary.firstRowId) {
      _targetRow = boundary.firstRowId;
    }
    if (boundary != null &&
        widget.historyEndRow != null &&
        boundary.firstRowId >= widget.historyEndRow!) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onClose();
      });
      return;
    }
    setState(() {
      if (!_hasSelection) _syncEngine();
    });
    if (widget.model.rows.isEmpty &&
        widget.model.canLoadMore &&
        _targetRow != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            _targetRow != null &&
            widget.model.rows.isEmpty &&
            widget.model.canLoadMore) {
          seekRow(_targetRow!);
        }
      });
    }
  }

  /// Rebuilds the engine from the loaded rows.
  ///
  /// A terminal can only be appended to and pages arrive OLDEST-first, so a new
  /// page cannot be written on top of the one before it -- the whole buffer is
  /// re-ingested instead. That is affordable because paging is user-driven and
  /// bounded by [kTerminalHistoryMaxRows]; `clear()` re-pushes the host palette
  /// itself, so the rebuild is colour-safe.
  ///
  /// [preserveOffset] is false wherever the rows about to be ingested are not
  /// a longer version of the ones on screen, and so carry the reader's place
  /// nowhere. It also suppresses the signature guard, which is what makes a
  /// terminal SWAP safe: the signature describes the rows, not which archive
  /// they came from, and two terminals paging back from their own low row ids
  /// collide on it while every row differs -- obeying the guard there would
  /// leave the old terminal's transcript on screen under the new one's name.
  void _syncEngine({bool preserveOffset = true}) {
    final boundary = widget.historyEndRow;
    final candidates = <TerminalHistoryRow>[
      ...widget.model.rows.where((r) => boundary == null || r.rowId < boundary),
      if (boundary != null &&
          (widget.model.rows.isEmpty ||
              widget.model.rows.last.rowId >= boundary - 1))
        ...widget.screenRows,
    ];
    final rows = _renderWindow(candidates);
    final signature = rows.isEmpty
        ? null
        : (rows.first.rowId, rows.last.rowId, rows.length);
    if (preserveOffset && signature == _rendered) return;
    _rendered = signature;

    final bar = preserveOffset ? _controller.viewportScrollbar : null;
    var rowsFromBottom = bar == null
        ? 0
        : math.max(0, bar.total - bar.length - bar.offset);
    if (rowsFromBottom > 0 &&
        rows.isNotEmpty &&
        _renderedRows.isNotEmpty &&
        rows.last.rowId < _renderedRows.last.rowId) {
      final retained = _renderedRows
          .where((row) => row.rowId <= rows.last.rowId)
          .toList(growable: false);
      // Count engine lines, not archive records: one evicted row can wrap over
      // several display lines, including wide and combining characters.
      final removedLines =
          _renderedLineCount(_renderedRows) - _renderedLineCount(retained);
      rowsFromBottom = math.max(0, rowsFromBottom - removedLines);
    }
    _renderedRows = rows.toList(growable: false);
    _lineStarts = _measureRowStarts(rows);
    _measuredCols = _controller.cols;
    // Armed on every rebuild the guard lets through, null included: a reader
    // sitting at the live bottom when a page lands wants to stay there, and an
    // earlier target left standing would move them off it.
    _armRestore(rowsFromBottom > 0 ? rowsFromBottom : null);

    _restoring = true;
    _controller.clear();
    if (rows.isNotEmpty) {
      _controller.appendOutputBytes(encodeTerminalHistoryRows(rows));
    }
    _restoring = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _restoreTarget();
    });
  }

  int _renderedLineCount(List<TerminalHistoryRow> rows) {
    if (rows.isEmpty) return 0;
    final terminal = GhosttyVt.newTerminal(
      cols: _controller.cols,
      rows: 1,
      maxScrollback: 64 << 20,
    );
    try {
      terminal.writeBytes(encodeTerminalHistoryRows(rows));
      return terminal.totalRows;
    } finally {
      terminal.close();
    }
  }

  /// A narrow phone can turn one archived row into hundreds of display lines.
  /// Window the renderer as well as the cache so native trimming never changes
  /// the origin used by row anchors.
  List<TerminalHistoryRow> _renderWindow(List<TerminalHistoryRow> rows) {
    if (rows.isEmpty) return rows;
    final anchor = _targetRow ?? _lastPosition ?? rows.last.rowId;
    var center = rows.indexWhere((row) => row.rowId >= anchor);
    if (center < 0) center = rows.length - 1;
    int cost(int index) =>
        (rows[index].cols / math.max(1, _controller.cols)).ceil() + 1;
    var first = center;
    var last = center;
    var lines = cost(center);
    while (first > 0 &&
        lines + cost(first - 1) <= _historyRenderMaxLines ~/ 2) {
      lines += cost(--first);
    }
    while (last + 1 < rows.length &&
        lines + cost(last + 1) <= _historyRenderMaxLines) {
      lines += cost(++last);
    }
    return rows.sublist(first, last + 1);
  }

  List<int> _measureRowStarts(List<TerminalHistoryRow> rows) {
    final terminal = GhosttyVt.newTerminal(
      cols: _controller.cols,
      rows: 1,
      maxScrollback: 64 << 20,
    );
    try {
      final starts = <int>[];
      for (var i = 0; i < rows.length; i++) {
        if (i > 0 && !rows[i].wrapped) terminal.writeBytes(utf8.encode('\r\n'));
        starts.add(
          terminal.totalRows -
              1 +
              (rows[i].wrapped && terminal.cursorPendingWrap ? 1 : 0),
        );
        final encoded = StringBuffer();
        _writeRow(
          encoded,
          rows[i],
          endsLine: i == rows.length - 1 || !rows[i + 1].wrapped,
        );
        terminal.writeBytes(utf8.encode(encoded.toString()));
      }
      return starts;
    } finally {
      terminal.close();
    }
  }

  void _armRestore(int? rowsFromBottom) {
    _restoreExpiry?.cancel();
    _pendingRestoreRows = rowsFromBottom;
    _restoreExpiry = rowsFromBottom == null
        ? null
        : Timer(_restoreWindow, () => _armRestore(null));
  }

  void _onEngineChanged() {
    if (_measuredCols != null &&
        _measuredCols != _controller.cols &&
        !_restoring) {
      _measuredCols = _controller.cols;
      final anchor = _targetRow ?? _lastPosition;
      final lineOffset = _anchorLineOffset;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _targetRow = anchor;
        setState(() => _syncEngine(preserveOffset: false));
        _restoreTarget();
        if (anchor != null) {
          final index = _renderedRows.indexWhere((r) => r.rowId == anchor);
          final bar = _controller.viewportScrollbar;
          if (index >= 0 && bar != null) {
            _restoring = true;
            _controller.scrollViewportToOffsetFromBottom(
              math.max(
                0,
                bar.total - bar.length - _lineStarts[index] - lineOffset,
              ),
            );
            _restoring = false;
          }
        }
      });
    }
    if (_pendingRestoreRows == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _restoreScrollOffset());
  }

  /// Puts the viewport back where the reader left it.
  ///
  /// Carried in ENGINE rows above the live bottom, not a Flutter pixel
  /// offset: `clear()` resets the engine's own viewport to follow the live
  /// bottom, and [GhosttyTerminalView] re-syncs the Flutter scroll position
  /// from the engine's scrollbar on every notification it gets -- so a raw
  /// pixel `jumpTo` here would win the race only until the next one of those
  /// notifications pulled the pane straight back to the bottom behind it.
  /// Driving [GhosttyTerminalController.scrollViewportToOffsetFromBottom]
  /// instead moves the engine's own idea of where it is, which the view's
  /// existing engine-to-Flutter sync then carries over on its own -- there is
  /// nothing left here to race.
  ///
  /// The target discounts newer lines evicted from the cache. Retried rather
  /// than applied once because the engine parses
  /// the re-ingested rows off the widget tree's clock: the row this is
  /// clamped against may not exist yet in the frame the rebuild was
  /// scheduled from.
  void _restoreScrollOffset() {
    final target = _pendingRestoreRows;
    if (target == null || !mounted) return;
    final bar = _controller.viewportScrollbar;
    if (bar == null) return;
    final maxFromBottom = math.max(0, bar.total - bar.length);
    if (maxFromBottom < target) return;
    _armRestore(null);
    _controller.scrollViewportToOffsetFromBottom(target);
  }

  void _onScrollPastTop() {
    if (!_hasSelection &&
        _renderedRows.isNotEmpty &&
        widget.model.rows.isNotEmpty &&
        _renderedRows.first.rowId > widget.model.rows.first.rowId) {
      _recenterWindow();
      return;
    }
    // Fires once per clamped scroll step, so it repeats while the reader keeps
    // pushing at the top; the model is what makes that idempotent.
    if (!_hasSelection && widget.model.canLoadMore) widget.onLoadMore();
  }

  /// The reader's keyboard map.
  ///
  /// This [Focus] is an ANCESTOR of the embedded engine's, so which of the two
  /// sees a key first depends on where the keyboard is: the reader holds it
  /// from mount and a key arrives here directly, and once a click has moved
  /// focus into the transcript a key arrives only if the engine DECLINED it.
  /// Nothing here may claim a chord the engine answers -- copy, select-all,
  /// clear-selection and paste -- or the clicked case loses it, and those are
  /// the whole reason a reader gets a real terminal instead of a text list.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      // Held Escape would close a reader the first press already closed.
      if (event is KeyDownEvent) widget.onClose();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.end) {
      if (_scrollController.hasClients) _scrollController.jumpTo(0);
      if (_scrollController.hasClients) _scrollController.jumpTo(0);
      widget.onClose();
      return KeyEventResult.handled;
    }
    final older = _movesTowardOlder(key);
    if (older == null) return KeyEventResult.ignored;
    _scrollFor(key, older: older);
    return KeyEventResult.handled;
  }

  /// Whether [key] navigates toward the OLDEST end of the archive, or null for
  /// a key the reader does not navigate with.
  bool? _movesTowardOlder(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.pageUp ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.home) {
      return true;
    }
    if (key == LogicalKeyboardKey.pageDown ||
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.end) {
      return false;
    }
    return null;
  }

  /// Moves the viewport for one navigation key.
  ///
  /// The offset runs BACKWARDS from the live bottom -- zero is the newest row
  /// and `maxScrollExtent` the oldest loaded one -- because
  /// [GhosttyTerminalView] lays its scroll layer out from the engine's own
  /// offset-from-bottom. Toward older is therefore a LARGER pixel offset.
  void _scrollFor(LogicalKeyboardKey key, {required bool older}) {
    if (!_scrollController.hasClients) {
      // No terminal is laid out (an empty model renders none), so the only
      // useful answer to a reader asking for more archive is to fetch it.
      if (older) _onScrollPastTop();
      return;
    }
    final position = _scrollController.position;
    final max = position.maxScrollExtent;
    final double target;
    if (key == LogicalKeyboardKey.home) {
      target = max;
    } else if (key == LogicalKeyboardKey.end) {
      target = 0;
    } else {
      final step =
          key == LogicalKeyboardKey.pageUp || key == LogicalKeyboardKey.pageDown
          ? position.viewportDimension
          : _lineExtent(position);
      target = position.pixels + (older ? step : -step);
    }
    final clamped = target.clamp(0.0, max);
    if ((clamped - position.pixels).abs() >= 0.5) {
      _scrollController.jumpTo(clamped);
    }
    // Landing on the oldest loaded row is the same request a wheel makes when
    // it clamps there: what the reader wanted to read is one page further up,
    // and a keyboard that cannot ask for it sends them back to the mouse.
    if (older &&
        clamped >= max - 0.5 &&
        (clamped - position.pixels).abs() < 0.5) {
      _onScrollPastTop();
    }
  }

  /// Pixels one engine row occupies, measured rather than derived from the
  /// type this widget was handed.
  ///
  /// [GhosttyTerminalView] sizes its scroll extent as
  /// `(scrollable rows) * (line pixels)` and takes those row counts from the
  /// same `viewportScrollbar` read here, so the quotient is the line box it
  /// actually laid out -- which the font size alone does not determine.
  double _lineExtent(ScrollPosition position) {
    final bar = _controller.viewportScrollbar;
    final rows = bar == null ? 0 : bar.total - bar.length;
    if (rows <= 0 || position.maxScrollExtent <= 0) {
      return position.viewportDimension;
    }
    return position.maxScrollExtent / rows;
  }

  /// What the failure banner's one control can say for itself.
  ///
  /// Keyed on [TerminalHistoryModel.canLoadMore]: that is the property
  /// `TerminalService.requestTerminalHistoryPage` checks before it sends
  /// anything, so any narrower gate leaves a live Retry whose tap the service
  /// drops on the floor.
  String _retryTooltip(TerminalHistoryModel model) {
    if (model.canLoadMore) return 'Retry';
    if (model.loading) return 'Retrying…';
    return 'Scrollback is unavailable for this run';
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.antgrid;
    final model = widget.model;
    final failure = model.failure;

    return Listener(
      onPointerSignal: (event) {
        final bar = _controller.viewportScrollbar;
        if (event is PointerScrollEvent &&
            event.scrollDelta.dy > 0 &&
            bar != null &&
            bar.offset >= bar.total - bar.length) {
          _towardLive();
        }
      },
      onPointerMove: (event) {
        final bar = _controller.viewportScrollbar;
        if (event.kind == PointerDeviceKind.touch &&
            event.delta.dy < 0 &&
            bar != null &&
            bar.offset >= bar.total - bar.length) {
          _towardLive();
        }
      },
      child: ColoredBox(
        color: colors.bgDeepest,
        child: Focus(
          focusNode: _focusNode,
          onKeyEvent: _onKey,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(child: _buildBody(context)),
              if (model.rows.isNotEmpty &&
                  (model.loading || !model.recording || model.atOldest))
                Positioned(
                  top: AbTokens.space8,
                  right: AbTokens.space24,
                  child: IgnorePointer(
                    child: Text(
                      model.loading
                          ? 'Loading...'
                          : !model.recording
                          ? 'History recording stopped'
                          : (model.boundary!.firstRowId > 0
                                ? 'Earlier output expired'
                                : 'Oldest output'),
                      style: AbTokens.sansStyle(
                        fontSize: AbTokens.fontXxs,
                        color: colors.textMuted,
                      ),
                    ),
                  ),
                ),
              if (failure != null)
                Positioned(
                  top: 0,
                  left: 0,
                  right: AbTokens.space24,
                  child: AbInlineBanner(
                    text: failure,
                    // Warning yellow asks the reader to act on something. A run
                    // whose archive has settled shut offers nothing to act on; a
                    // retry already in flight is still an open failure.
                    color: model.canLoadMore || model.loading
                        ? colors.warning
                        : colors.textMuted,
                    // Disabled in place rather than dropped from the row: the pane
                    // under this banner is sized by what is left over, so
                    // withdrawing the affordance by removing the widget would
                    // resize the reader's engine.
                    trailing: AbIconButton(
                      icon: AbIcons.refresh,
                      tooltip: _retryTooltip(model),
                      onTap: model.canLoadMore ? widget.onLoadMore : null,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final model = widget.model;
    if (model.rows.isEmpty) {
      final Widget status;
      if (model.loading) {
        status = const Center(child: AbLoading(message: 'Loading scrollback'));
      } else {
        status = AbEmptyState(
          icon: AbIcons.terminal,
          title: model.recording
              ? 'Nothing has scrolled off yet'
              : 'Scrollback was not recorded for this run',
        );
      }
      if (widget.onInput == null) return status;
      // Keep the IME bound even while the first remote history page is pending.
      return Stack(
        children: [
          Positioned.fill(child: _buildTerminal(context)),
          Positioned.fill(child: IgnorePointer(child: status)),
        ],
      );
    }
    return _buildTerminal(context);
  }

  Widget _buildTerminal(BuildContext context) {
    final colors = context.antgrid;
    return GhosttyTerminalView(
      key: _viewKey,
      controller: _controller,
      selectionController: _selectionController,
      onSelectionContentChanged: (content) {
        final hadSelection = _hasSelection;
        _hasSelection = content != null && content.text.isNotEmpty;
        if (hadSelection && !_hasSelection) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(_syncEngine);
          });
        }
      },
      softKeyboardController: widget.softKeyboardController,
      scrollController: _scrollController,
      onScrollPastTop: _onScrollPastTop,
      // [_focusNode] is what takes the keyboard, for the reason on its own
      // declaration. The navigation map still sees the keys the engine
      // declines once a click has moved focus into the transcript: it is an
      // ancestor of this view's own [Focus].
      autofocus: false,
      showKeyboardOnInteraction: false,
      fontSize: widget.fontSize,
      fontFamily: AbTokens.fontMono,
      fontFamilyFallback: AbTokens.fontMonoFallbacks,
      fontWeight: widget.fontWeight,
      boldFontWeight: widget.boldFontWeight,
      cellAlignment: Alignment.center,
      cursorColor: const Color(0x00000000),
      backgroundColor: colors.bgDeepest,
      renderer: GhosttyTerminalRendererMode.renderState,
      foregroundColor: ansiForegroundFor(colors.bgDeepest),
      palette: ansiPaletteFor(colors.bgDeepest),
      selectionColor: colors.accent.withValues(alpha: 0.3),
      hyperlinkColor: colors.accent,
      onOpenHyperlink: widget.onOpenHyperlink,
      onHyperlinkHover: widget.onHyperlinkHover,
      showHeader: false,
      showFocusRing: false,
      showVerticalScrollbar: false,
      scrollbarThickness: AbTokens.space6,
      scrollbarThumbColor: colors.borderStrong,
      scrollbarTrackColor: const Color(0x00000000),
      minimumContrastRatio: widget.minimumContrastRatio,
    );
  }
}
