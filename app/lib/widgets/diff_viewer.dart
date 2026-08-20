import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/ab_colors.dart';
import '../design/widgets/ab_diff_stat.dart';
import '../design/widgets/ab_empty_state.dart';
import '../design/widgets/ab_icon_button.dart';
import 'code_syntax.dart';
import 'git_status_color.dart';

/// Parsed representation of a single diff hunk.
class _DiffHunk {
  final String header;
  final List<_DiffLine> lines;

  const _DiffHunk({required this.header, required this.lines});
}

enum _DiffLineType { context, addition, deletion }

class _DiffLine {
  final _DiffLineType type;
  final String text;
  final int? oldLineNum;
  final int? newLineNum;

  const _DiffLine({
    required this.type,
    required this.text,
    this.oldLineNum,
    this.newLineNum,
  });
}

/// One rendered row: a hunk header, the gap between two hunks, or a line of
/// code. Flattened up front so the body is a single [ListView.builder] — a
/// few-thousand-line diff must build only what is on screen, and a Column of
/// hunks (the shape before) builds every line of every hunk.
sealed class _DiffRow {
  const _DiffRow();
}

class _HunkHeaderRow extends _DiffRow {
  const _HunkHeaderRow(this.text);
  final String text;
}

class _HunkGapRow extends _DiffRow {
  const _HunkGapRow();
}

class _CodeRow extends _DiffRow {
  const _CodeRow(this.line);
  final _DiffLine line;
}

/// Parses raw unified diff output into hunks.
List<_DiffHunk> _parseDiff(String raw) {
  final lines = raw.split('\n');
  final hunks = <_DiffHunk>[];
  String? currentHeader;
  var hunkLines = <_DiffLine>[];
  int oldLine = 0;
  int newLine = 0;

  for (final line in lines) {
    // Skip file headers
    if (line.startsWith('diff --git') ||
        line.startsWith('index ') ||
        line.startsWith('---') ||
        line.startsWith('+++')) {
      continue;
    }

    if (line.startsWith('@@')) {
      // Save previous hunk
      if (currentHeader != null) {
        hunks.add(_DiffHunk(header: currentHeader, lines: hunkLines));
        hunkLines = [];
      }
      currentHeader = line;
      // Parse line numbers from @@ -old,count +new,count @@
      final match = RegExp(r'@@ -(\d+),?\d* \+(\d+),?\d* @@').firstMatch(line);
      if (match != null) {
        oldLine = int.parse(match.group(1)!);
        newLine = int.parse(match.group(2)!);
      }
      continue;
    }

    if (currentHeader == null) continue;

    if (line.startsWith('+')) {
      hunkLines.add(
        _DiffLine(
          type: _DiffLineType.addition,
          text: line.substring(1),
          newLineNum: newLine,
        ),
      );
      newLine++;
    } else if (line.startsWith('-')) {
      hunkLines.add(
        _DiffLine(
          type: _DiffLineType.deletion,
          text: line.substring(1),
          oldLineNum: oldLine,
        ),
      );
      oldLine++;
    } else if (line.startsWith(' ') || line.isEmpty) {
      hunkLines.add(
        _DiffLine(
          type: _DiffLineType.context,
          text: line.isEmpty ? '' : line.substring(1),
          oldLineNum: oldLine,
          newLineNum: newLine,
        ),
      );
      oldLine++;
      newLine++;
    }
  }

  // Save last hunk
  if (currentHeader != null) {
    hunks.add(_DiffHunk(header: currentHeader, lines: hunkLines));
  }

  return hunks;
}

/// Renders a unified diff the way the file viewer renders a file: same mono
/// face, same [kCodeFontSize], same syntax colours, and the same refusal to
/// reflow — a long line scrolls sideways instead of wrapping, at every window
/// size. A diff that re-wraps as the pane narrows stops matching the file it
/// came from exactly when a phone or a split pane needs to read it.
///
/// What it adds over the file viewer is diff-shaped and nothing else: a
/// per-row tint for added/removed.
class DiffViewer extends StatefulWidget {
  final String path;
  final String? gitStatus;
  final String diff;
  final int additions;
  final int deletions;
  final VoidCallback onViewFile;
  final VoidCallback onClose;

  const DiffViewer({
    super.key,
    required this.path,
    this.gitStatus,
    required this.diff,
    required this.additions,
    required this.deletions,
    required this.onViewFile,
    required this.onClose,
  });

  @override
  State<DiffViewer> createState() => _DiffViewerState();
}

class _DiffViewerState extends State<DiffViewer> {
  /// The line-number gutter, sized for 5 digits at [AbTokens.fontXs].
  /// Unscaled — read [_gutterWidth], never this.
  static const double _baseGutterWidth = 40;

  /// One monospace character, for the +/- marker beside the gutter.
  /// Unscaled — read [_markerWidth], never this.
  static const double _baseMarkerWidth = 12;

  /// How many of the widest-ranked lines [_measureWidestLine] lays out exactly.
  static const int _measuredCandidates = 24;

  /// Row height. The extra over the line height is the breathing room the
  /// editor's own rows get from their padding; without it the tint bands touch.
  ///
  /// Scaled, because [itemExtent] is a promise about how tall the row will
  /// actually be: a fixed extent against text the scaler grew clips descenders
  /// and, past ~1.3x, whole glyphs. The height multiplier applies to the SCALED
  /// size, which is why this is not `scale(kCodeLineHeight)` — the two agree
  /// only for a linear scaler, and the app composes its own.
  double get _rowHeight => _textScaler.scale(kCodeFontSize) * kCodeFontHeight
      + AbTokens.space4;

  /// The gutter and marker hold text too, so their boxes grow with it — a
  /// five-digit line number in an unscaled 40px box is clipped at 130%.
  double get _gutterWidth => _textScaler.scale(_baseGutterWidth);
  double get _markerWidth => _textScaler.scale(_baseMarkerWidth);

  /// Below this the header trades its written "View file" link for an icon.
  static const double _compactHeaderWidth = 360;

  static final TextStyle _codeStyle = AbTokens.monoStyle(
    fontSize: kCodeFontSize,
    height: kCodeFontHeight,
  );

  /// Scrollbar geometry copied from re_editor's own bar (`_kScrollbarThickness`
  /// and the `_RawScrollbar` it builds in `_code_scroll.dart`), which is what
  /// the file viewer draws. Raw values, not tokens, because the thing they must
  /// stay equal to is a private constant in a package — a token would drift
  /// from it silently. The thumb colour is left at [RawScrollbar]'s default for
  /// the same reason: re_editor never overrides it either.
  static const double _scrollbarThickness = 8;
  static const Radius _scrollbarRadius = Radius.circular(10);
  static const double _scrollbarMargin = 2;

  final ScrollController _horizontal = ScrollController();
  final ScrollController _vertical = ScrollController();

  late List<_DiffRow> _rows;
  late List<_DiffHunk> _hunks;
  late double _codeWidth;
  CodeLineHighlighter? _highlighter;

  /// The scaler the rows will actually be painted with. Rows render through
  /// [Text.rich], which applies [MediaQuery.textScalerOf]; every measurement
  /// here is a hand-rolled [TextPainter] or a hard extent, which the ambient
  /// scaler never reaches — so it is read once and fed to them explicitly.
  TextScaler _textScaler = TextScaler.noScaling;

  @override
  void initState() {
    super.initState();
    _parse();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Re-measure when the OS text size or the app's UI Size setting moves; the
    // measured width is only correct for the scaler it was taken under.
    final scaler = MediaQuery.textScalerOf(context);
    if (scaler != _textScaler) {
      _textScaler = scaler;
      _codeWidth = _measureWidestLine(_hunks);
    }
  }

  @override
  void didUpdateWidget(covariant DiffViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.diff != oldWidget.diff || widget.path != oldWidget.path) {
      _parse();
    }
  }

  @override
  void dispose() {
    _horizontal.dispose();
    _vertical.dispose();
    super.dispose();
  }

  void _parse() {
    final hunks = _parseDiff(widget.diff);
    _hunks = hunks;
    _rows = [
      for (final (i, hunk) in hunks.indexed) ...[
        if (i > 0) const _HunkGapRow(),
        _HunkHeaderRow(hunk.header),
        ...hunk.lines.map(_CodeRow.new),
      ],
    ];
    _highlighter = CodeLineHighlighter.forPath(widget.path);
    _codeWidth = _measureWidestLine(hunks);
  }

  /// The width the code column needs to hold its longest line unwrapped.
  ///
  /// Laying out every line of a big diff costs far more than the extent is
  /// worth, so only the widest few are measured for real. `String.length` was
  /// the whole ranking, and it is a width only in a diff of single-width
  /// codepoints: one line of CJK, full-width punctuation or emoji renders
  /// roughly twice the extent of an ASCII line the same length, and
  /// under-measuring clips it with nowhere to scroll (rows are
  /// [TextOverflow.clip] with [softWrap] off). Ranking on that doubling and
  /// then measuring the shortlist exactly costs one pass and a bounded number
  /// of layouts, and is right whichever way the two disagree.
  double _measureWidestLine(List<_DiffHunk> hunks) {
    final ranked = <(int, String)>[];
    for (final hunk in hunks) {
      ranked.add((_estimatedColumns(hunk.header), hunk.header));
      for (final line in hunk.lines) {
        ranked.add((_estimatedColumns(line.text), line.text));
      }
    }
    ranked.sort((a, b) => b.$1.compareTo(a.$1));

    var widest = 0.0;
    for (final (_, text) in ranked.take(_measuredCandidates)) {
      if (text.isEmpty) continue;
      final painter = TextPainter(
        text: TextSpan(text: text, style: _codeStyle),
        textDirection: TextDirection.ltr,
        textScaler: _textScaler,
        maxLines: 1,
      )..layout();
      if (painter.width > widest) widest = painter.width;
    }
    return widest;
  }

  /// Monospace columns [text] is likely to occupy — every non-ASCII rune
  /// counted double, the standard East-Asian-width approximation. Only ever a
  /// ranking key, never a width: [_measureWidestLine] lays the shortlist out
  /// for the real number.
  static int _estimatedColumns(String text) {
    var columns = 0;
    for (final rune in text.runes) {
      columns += rune > 0x7f ? 2 : 1;
    }
    return columns;
  }

  @override
  Widget build(BuildContext context) {
    // Check for binary diff
    if (widget.diff.contains('Binary files') &&
        widget.diff.contains('differ')) {
      return AbEmptyState(
        icon: AbIcons.fileBinary,
        title: 'Binary file changed: ${widget.path.split('/').last}',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(context),
        Expanded(
          child: _rows.isEmpty
              ? const AbEmptyState.compact(title: 'No changes')
              : _buildBody(context),
        ),
      ],
    );
  }

  /// Sends a sideways wheel/trackpad scroll to the horizontal axis ONLY.
  ///
  /// A real trackpad swipe is never perfectly straight, and the vertical list
  /// sits inside the horizontal one: left this to the framework, any sideways
  /// scroll carrying a few pixels of drift is claimed by the innermost
  /// interested Scrollable — the vertical one — and the diff creeps up and down
  /// while refusing to move across. Claiming the dominant axis first is what
  /// makes sideways stay sideways. A vertical-dominant event is left alone, so
  /// the list keeps its own scrolling (and its fling) untouched.
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final delta = event.scrollDelta;
    if (delta.dx.abs() <= delta.dy.abs()) return;
    if (!_horizontal.hasClients) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      final position = _horizontal.position;
      _horizontal.jumpTo(
        (position.pixels + delta.dx).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
    });
  }

  Widget _buildBody(BuildContext context) {
    // The gutter scrolls with the code rather than staying pinned, so a row's
    // tint runs the full width of the longest line: a band that stops at the
    // viewport edge reads as a smaller change than it is.
    final contentWidth =
        _gutterWidth +
        AbTokens.space8 +
        _markerWidth +
        AbTokens.space8 +
        _codeWidth +
        AbTokens.space12;

    return LayoutBuilder(
      builder: (context, constraints) {
        // Both bars sit ABOVE the horizontal viewport, so neither is dragged
        // off screen by the code it measures. Each reads the notifications of
        // its own axis: the horizontal viewport's at depth 0, the list's one
        // viewport boundary further in at depth 1.
        //
        // Vertical stays visible and horizontal fades with use, which is how
        // re_editor builds the file viewer's pair.
        return RawScrollbar(
          controller: _vertical,
          notificationPredicate: (n) => n.depth == 1,
          scrollbarOrientation: ScrollbarOrientation.right,
          thickness: _scrollbarThickness,
          radius: _scrollbarRadius,
          crossAxisMargin: _scrollbarMargin,
          thumbVisibility: true,
          child: RawScrollbar(
            controller: _horizontal,
            notificationPredicate: (n) => n.depth == 0,
            scrollbarOrientation: ScrollbarOrientation.bottom,
            thickness: _scrollbarThickness,
            radius: _scrollbarRadius,
            crossAxisMargin: _scrollbarMargin,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              controller: _horizontal,
              child: SizedBox(
                width: math.max(constraints.maxWidth, contentWidth),
                child: ListView.builder(
                  controller: _vertical,
                  itemCount: _rows.length,
                  itemExtent: _rowHeight,
                  // The listener rides on each ROW, not on the list: a pointer
                  // signal goes to the FIRST registrant in hit-test order,
                  // which runs innermost-first, so only a node below the
                  // vertical Scrollable can take an event away from it. See
                  // [_onPointerSignal].
                  itemBuilder: (context, index) => Listener(
                    // Opaque, or the row only claims the pixels its text and
                    // gutter actually paint: the gap between them, and every
                    // column past the end of a short line, hit-tests through
                    // to the vertical list, which is exactly where a sideways
                    // scroll starts creeping up and down again.
                    behavior: HitTestBehavior.opaque,
                    onPointerSignal: _onPointerSignal,
                    child: switch (_rows[index]) {
                      _HunkHeaderRow(:final text) => _buildHunkHeader(
                        context,
                        text,
                      ),
                      _HunkGapRow() => _buildHunkGap(context),
                      _CodeRow(:final line) => _buildLine(context, line),
                    },
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AbTokens.space12,
        vertical: AbTokens.space8,
      ),
      decoration: BoxDecoration(
        color: context.antgrid.bgDeep,
        border: Border(bottom: BorderSide(color: context.antgrid.borderSubtle)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // On a phone, or a docked pane, the written link is wider than the
          // path it would leave room for. Only the CHROME collapses — the diff
          // below it renders the same at every width.
          final compact = constraints.maxWidth < _compactHeaderWidth;
          return Row(
            children: [
              if (widget.gitStatus != null) ...[
                Text(
                  widget.gitStatus!,
                  style: AbTokens.monoStyle(
                    fontSize: AbTokens.fontXs,
                    fontWeight: FontWeight.w600,
                    color: gitStatusColor(context, widget.gitStatus!),
                  ),
                ),
                const SizedBox(width: AbTokens.space8),
              ],
              Expanded(
                child: Text(
                  widget.path,
                  style: AbTokens.monoStyle(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: AbTokens.space8),
              AbDiffStat(
                additions: widget.additions,
                deletions: widget.deletions,
                fontSize: AbTokens.fontXs,
              ),
              const SizedBox(width: AbTokens.space8),
              if (compact)
                AbIconButton(
                  icon: AbIcons.files,
                  onTap: widget.onViewFile,
                  tooltip: 'View file',
                )
              else
                GestureDetector(
                  onTap: widget.onViewFile,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Text(
                      'View file',
                      style:
                          AbTokens.sansStyle(
                            fontSize: AbTokens.fontXs,
                            color: context.antgrid.accent,
                          ).copyWith(
                            decoration: TextDecoration.underline,
                            decorationColor: context.antgrid.accent,
                          ),
                    ),
                  ),
                ),
              const SizedBox(width: AbTokens.space8),
              AbIconButton(
                icon: AbIcons.close,
                onTap: widget.onClose,
                tooltip: 'Close diff',
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildHunkHeader(BuildContext context, String header) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AbTokens.space12),
      alignment: Alignment.centerLeft,
      color: context.antgrid.accent.withValues(alpha: 0.08),
      child: Text(
        header,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.clip,
        style: AbTokens.monoStyle(
          fontSize: AbTokens.fontXs,
          height: kCodeFontHeight,
          color: context.antgrid.accent.withValues(alpha: 0.7),
        ),
      ),
    );
  }

  Widget _buildHunkGap(BuildContext context) {
    return Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: context.antgrid.bgDeep,
        border: Border.symmetric(
          horizontal: BorderSide(color: context.antgrid.borderSubtle),
        ),
      ),
      child: Text(
        '···',
        style: AbTokens.monoStyle(
          fontSize: AbTokens.fontXs,
          height: kCodeFontHeight,
          color: context.antgrid.textDisabled,
        ),
      ),
    );
  }

  Widget _buildLine(BuildContext context, _DiffLine line) {
    final (Color? bgColor, Color gutterColor) = switch (line.type) {
      _DiffLineType.addition => (
        context.antgrid.success.withValues(alpha: 0.15),
        context.antgrid.success.withValues(alpha: 0.6),
      ),
      _DiffLineType.deletion => (
        context.antgrid.error.withValues(alpha: 0.15),
        context.antgrid.error.withValues(alpha: 0.6),
      ),
      _DiffLineType.context => (null, context.antgrid.textMuted),
    };

    // Syntax colours come from the file viewer's own theme, so a line reads
    // identically in the diff and in the file. That leaves the row tint as the
    // only thing separating an addition from a deletion, which is colour
    // alone — unreadable to a red/green-blind eye and to a washed-out screen —
    // so the marker [_parseDiff] strips off the front is reinstated in its own
    // column. Plain text when the path has no known language.
    final base = _codeStyle.copyWith(color: context.antgrid.textPrimary);
    final span =
        _highlighter?.span(line.text, base) ??
        TextSpan(text: line.text, style: base);

    return Container(
      color: bgColor,
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          // ONE number per row: the line as it stands in the file now, falling
          // back to where a removed line used to be — the only row with no
          // "now" to point at. Two columns spent a second gutter restating a
          // number that is the same on all but the changed rows.
          _buildGutter(line.newLineNum ?? line.oldLineNum, gutterColor),
          const SizedBox(width: AbTokens.space8),
          _buildMarker(line.type, gutterColor),
          const SizedBox(width: AbTokens.space8),
          Expanded(
            child: Text.rich(
              span,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.clip,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMarker(_DiffLineType type, Color color) {
    return SizedBox(
      width: _markerWidth,
      child: Text(
        switch (type) {
          _DiffLineType.addition => '+',
          _DiffLineType.deletion => '-',
          _DiffLineType.context => '',
        },
        maxLines: 1,
        style: AbTokens.monoStyle(
          fontSize: AbTokens.fontXs,
          height: kCodeFontHeight,
          color: color,
        ),
      ),
    );
  }

  Widget _buildGutter(int? lineNum, Color color) {
    return SizedBox(
      width: _gutterWidth,
      child: Text(
        lineNum?.toString() ?? '',
        textAlign: TextAlign.right,
        maxLines: 1,
        style: AbTokens.monoStyle(
          fontSize: AbTokens.fontXs,
          height: kCodeFontHeight,
          color: color,
        ),
      ),
    );
  }
}
