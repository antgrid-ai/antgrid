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
import '../design/widgets/ab_toolbar.dart';
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

/// How many engine lines one archived row may need.
///
/// Rows are re-wrapped at the pane's current width, so an archive captured wide
/// and read narrow costs several lines each. Four is the budget for reading a
/// 200-column agent transcript on a phone; past that the oldest rows fall out of
/// the engine, which is a worse outcome than a taller buffer and a better one
/// than an unbounded one.
const int _engineLinesPerRow = 4;

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
  });

  final TerminalHistoryModel model;

  /// Asks the host for one more page. Safe to call when there is nothing to
  /// ask for -- the model refuses a second in-flight request itself.
  final VoidCallback onLoadMore;

  final VoidCallback onClose;

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
  State<TerminalHistoryView> createState() => _TerminalHistoryViewState();
}

class _TerminalHistoryViewState extends State<TerminalHistoryView> {
  late final GhosttyTerminalController _controller;
  final ScrollController _scrollController = ScrollController();

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
      maxLines: kTerminalHistoryMaxRows * _engineLinesPerRow,
      maxScrollbackLines: kTerminalHistoryMaxRows * _engineLinesPerRow,
      maxScrollback: 64 << 20,
      // The view resizes its controller to the pane on its first layout, so
      // these are only what the rows are ingested against for the one frame
      // before that lands.
      initialCols: 80,
      initialRows: 24,
    );
    _controller.addListener(_onEngineChanged);
    widget.model.addListener(_onModelChanged);
    _syncEngine(preserveOffset: false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusNode.requestFocus();
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
      model.prepareLatestWindow();
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
    setState(_syncEngine);
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
    final rows = widget.model.rows;
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
    // Armed on every rebuild the guard lets through, null included: a reader
    // sitting at the live bottom when a page lands wants to stay there, and an
    // earlier target left standing would move them off it.
    _armRestore(rowsFromBottom > 0 ? rowsFromBottom : null);

    _controller.clear();
    if (rows.isNotEmpty) {
      _controller.appendOutputBytes(encodeTerminalHistoryRows(rows));
    }
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

  void _armRestore(int? rowsFromBottom) {
    _restoreExpiry?.cancel();
    _pendingRestoreRows = rowsFromBottom;
    _restoreExpiry = rowsFromBottom == null
        ? null
        : Timer(_restoreWindow, () => _armRestore(null));
  }

  void _onEngineChanged() {
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
    // Fires once per clamped scroll step, so it repeats while the reader keeps
    // pushing at the top; the model is what makes that idempotent.
    if (widget.model.canLoadMore) widget.onLoadMore();
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
    if (older && clamped >= max - 0.5) _onScrollPastTop();
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

  String? _statusLabel(TerminalHistoryModel model) {
    if (model.loading) return 'Loading…';
    if (!model.recording) return 'Not recorded';
    if (model.atOldest) return 'Oldest';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.antgrid;
    final model = widget.model;
    final status = _statusLabel(model);
    final failure = model.failure;

    return ColoredBox(
      color: colors.bgDeepest,
      child: Focus(
        focusNode: _focusNode,
        onKeyEvent: _onKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AbToolbar.panel(
              title: 'Scrollback',
              actions: [
                if (status != null)
                  Text(
                    status,
                    style: AbTokens.sansStyle(
                      fontSize: AbTokens.fontXxs,
                      color: colors.textMuted,
                    ),
                  ),
                AbIconButton(
                  icon: AbIcons.close,
                  tooltip: 'Back to live',
                  onTap: widget.onClose,
                ),
              ],
            ),
            if (failure != null)
              AbInlineBanner(
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
            Expanded(child: _buildBody(context)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final model = widget.model;
    if (model.rows.isEmpty) {
      if (model.loading) {
        return const Center(child: AbLoading(message: 'Loading scrollback'));
      }
      return AbEmptyState(
        icon: AbIcons.terminal,
        title: model.recording
            ? 'Nothing has scrolled off yet'
            : 'Scrollback was not recorded for this run',
      );
    }
    return _buildTerminal(context);
  }

  Widget _buildTerminal(BuildContext context) {
    final colors = context.antgrid;
    return GhosttyTerminalView(
      controller: _controller,
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
      // Unlike the live pane, this engine holds far more than one screen, so
      // the scrollbar is a live affordance rather than a permanently empty
      // track.
      showVerticalScrollbar: true,
      scrollbarThickness: AbTokens.space6,
      scrollbarThumbColor: colors.borderStrong,
      scrollbarTrackColor: const Color(0x00000000),
      minimumContrastRatio: widget.minimumContrastRatio,
    );
  }
}
