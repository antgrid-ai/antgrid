import 'dart:math' as math;

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart'
    show AdaptiveTextSelectionToolbar, SelectionArea;
import 'package:flutter/rendering.dart' show SelectedContent;
import 'package:flutter/widgets.dart';

import '../util/detached.dart';
import 'carbon_code_style.dart';
import 'carbon_diff_stat.dart';
import 'carbon_empty_state.dart';
import 'git_status_color.dart';
import 'send_to_agent_comment.dart';
import 'wheel_scroll.dart';

/// Row tints are washes over the page background: strong enough to read as
/// added/removed, weak enough that code keeps its contrast on them.
const double _tintAlpha = 0.15;
const double _hunkTintAlpha = 0.08;

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
/// face, same [CarbonCodeStyle], same syntax colours, and the same refusal to
/// reflow — a long line scrolls sideways instead of wrapping, at every window
/// size. A diff that re-wraps as the pane narrows stops matching the file it
/// came from exactly when a phone or a split pane needs to read it.
///
/// What it adds over the file viewer is diff-shaped and nothing else: a
/// per-row tint for added/removed. Only for use inside an `AbCarbonScope`.
class DiffViewer extends StatefulWidget {
  final String path;
  final String? gitStatus;
  final String diff;
  final int additions;
  final int deletions;
  final VoidCallback onViewFile;
  final VoidCallback onClose;

  /// Delivers a composed "Send to Agent" message (comment + source label +
  /// selected code, already put together by [showSendToAgentComment]) to the
  /// focused session. Kept as a plain callback rather than reading Riverpod
  /// here directly — this widget stays a dumb, provider-free presentation
  /// component (matching [onViewFile]/[onClose]) and the one call site
  /// (`git_panel.dart`) supplies the routing.
  final Future<void> Function(BuildContext context, String message)
  onSendToAgent;

  const DiffViewer({
    super.key,
    required this.path,
    this.gitStatus,
    required this.diff,
    required this.additions,
    required this.deletions,
    required this.onViewFile,
    required this.onClose,
    required this.onSendToAgent,
  });

  @override
  State<DiffViewer> createState() => _DiffViewerState();
}

class _DiffViewerState extends State<DiffViewer> {
  /// How many of the widest-ranked lines [_measureWidestLine] lays out exactly.
  static const int _measuredCandidates = 24;

  /// The widest line number the gutter is sized for.
  static const String _gutterSample = '99999';

  /// Row height. The extra over the line height is the breathing room the
  /// editor's own rows get from their padding; without it the tint bands touch.
  ///
  /// Scaled, because [itemExtent] is a promise about how tall the row will
  /// actually be: a fixed extent against text the scaler grew clips descenders
  /// and, past ~1.3x, whole glyphs. [CarbonCodeStyle.lineHeight] applies the
  /// height multiplier to the SCALED size, which is why this is not a scaled
  /// constant — the two agree only for a linear scaler, and the app composes
  /// its own.
  double get _rowHeight =>
      _code.lineHeight(_textScaler) + CarbonSpacing.spacing02;

  /// Below this the header trades its written "View file" link for an icon.
  static const double _compactHeaderWidth = 360;

  final ScrollController _horizontal = ScrollController();
  final ScrollController _vertical = ScrollController();

  /// The last non-empty selection, tracked from [SelectionArea.onSelectionChanged]
  /// — `SelectableRegionState` exposes no public getter for the live content,
  /// only the anchors/button-items the toolbar itself needs, so this is the
  /// only way [_buildContextMenu]'s "Send to Agent" button can read what was
  /// actually selected.
  SelectedContent? _lastSelection;

  late List<_DiffRow> _rows;
  late List<_DiffHunk> _hunks;
  late bool _isBinary;
  CarbonLineHighlighter? _highlighter;

  /// Read in [didChangeDependencies] rather than per build, so the highlighter
  /// sees one identical object between theme changes and keeps its cache.
  CarbonCodeStyle? _style;
  CarbonCodeStyle get _code => _style!;

  // Measured, not constants: the gutter and marker hold text, so their boxes
  // follow the face's own advance and the scaler — a five-digit line number in
  // a box sized for a narrower face or a smaller scale is clipped.
  double _codeWidth = 0;
  double _gutterWidth = 0;
  double _markerWidth = 0;

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
    // Re-measure when the OS text size, the app's UI Size setting or the theme
    // moves; the measured widths are only correct for the pair they were taken
    // under. Also the first measurement: the style needs a context, which
    // initState does not have.
    final scaler = MediaQuery.textScalerOf(context);
    final style = CarbonCodeStyle.of(context);
    if (_style == null || scaler != _textScaler || style != _style) {
      _textScaler = scaler;
      _style = style;
      _measure();
    }
  }

  @override
  void didUpdateWidget(covariant DiffViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.diff != oldWidget.diff || widget.path != oldWidget.path) {
      _parse();
      _measure();
    }
  }

  @override
  void dispose() {
    _horizontal.dispose();
    _vertical.dispose();
    super.dispose();
  }

  void _parse() {
    // Git prints one line and no content for a binary change, so there is
    // nothing to lay out — and parsing it anyway would run a TextPainter over
    // every line to size a body that is never built.
    _isBinary =
        widget.diff.contains('Binary files') && widget.diff.contains('differ');
    if (_isBinary) {
      _hunks = const [];
      _rows = const [];
      _highlighter = null;
      return;
    }
    final hunks = _parseDiff(widget.diff);
    _hunks = hunks;
    _rows = [
      for (final (i, hunk) in hunks.indexed) ...[
        if (i > 0) const _HunkGapRow(),
        _HunkHeaderRow(hunk.header),
        ...hunk.lines.map(_CodeRow.new),
      ],
    ];
    _highlighter = CarbonLineHighlighter.forPath(widget.path);
  }

  void _measure() {
    _codeWidth = _measureWidestLine(_hunks);
    _gutterWidth = _widthOf(_gutterSample);
    _markerWidth = _widthOf('+');
  }

  double _widthOf(String text) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: _code.text),
      textDirection: TextDirection.ltr,
      textScaler: _textScaler,
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
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
      final width = _widthOf(text);
      if (width > widest) widest = width;
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
    // The header is not part of the diff: it carries the path, the status
    // letter, the way out of the pane, and `View file`, which for a changed
    // image is the one control that shows the change at all. The placeholder
    // repeats that callback because a narrow header collapses the written link
    // to a bare icon.
    final Widget body = _isBinary
        ? CarbonEmptyState(
            icon: CarbonIcons.documentUnknown,
            heading: 'Binary file changed: ${widget.path.split('/').last}',
            action: CarbonButton(
              label: 'View file',
              kind: CarbonButtonKind.tertiary,
              size: CarbonButtonSize.small,
              onPressed: widget.onViewFile,
            ),
          )
        : _rows.isEmpty
        ? const CarbonEmptyState(heading: 'No changes')
        : _buildBody(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(context),
        Expanded(
          child: ColoredBox(
            color: CarbonTheme.of(context).colors.background,
            child: body,
          ),
        ),
      ],
    );
  }

  Widget _buildBody(BuildContext context) {
    // The gutter scrolls with the code rather than staying pinned, so a row's
    // tint runs the full width of the longest line: a band that stops at the
    // viewport edge reads as a smaller change than it is.
    final contentWidth =
        _gutterWidth +
        CarbonSpacing.spacing03 +
        _markerWidth +
        CarbonSpacing.spacing03 +
        _codeWidth +
        CarbonSpacing.spacing04;

    return LayoutBuilder(
      builder: (context, constraints) {
        // Both bars sit ABOVE the horizontal viewport, so neither is dragged
        // off screen by the code it measures. Each reads the notifications of
        // its own axis: the horizontal viewport's at depth 0, the list's one
        // viewport boundary further in at depth 1.
        //
        // SelectionArea makes every line's code text (never the gutter/marker
        // columns — see [_buildGutter]/[_buildMarker]) selectable and
        // copyable, the same as a real editor. [_buildContextMenu] is what
        // turns that into "Send to Agent": Flutter anchors the toolbar it
        // returns to the selection itself (the platform's own copy/paste
        // popup mechanism), so the action appears wherever the user actually
        // selected rather than at a fixed button elsewhere in the panel.
        return SelectionArea(
          contextMenuBuilder: _buildContextMenu,
          onSelectionChanged: (content) => _lastSelection = content,
          child: _DiffScrollbar(
            controller: _vertical,
            notificationPredicate: (n) => n.depth == 1,
            orientation: ScrollbarOrientation.right,
            child: _DiffScrollbar(
              controller: _horizontal,
              notificationPredicate: (n) => n.depth == 0,
              orientation: ScrollbarOrientation.bottom,
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
                    // [claimSidewaysScroll].
                    itemBuilder: (context, index) => Listener(
                      // Opaque, or the row only claims the pixels its text and
                      // gutter actually paint: the gap between them, and every
                      // column past the end of a short line, hit-tests through
                      // to the vertical list, which is exactly where a sideways
                      // scroll starts creeping up and down again.
                      behavior: HitTestBehavior.opaque,
                      onPointerSignal: (e) => claimSidewaysScroll(e, _horizontal),
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
          ),
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context) {
    final colors = CarbonTheme.of(context).colors;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: CarbonSpacing.spacing04,
        vertical: CarbonSpacing.spacing02,
      ),
      decoration: BoxDecoration(
        color: colors.layer01,
        border: Border(bottom: BorderSide(color: colors.borderSubtle01)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // On a phone, or a docked pane, the written link is wider than the
          // path it would leave room for. Only the CHROME collapses — the diff
          // below it renders the same at every width.
          final compact = constraints.maxWidth < _compactHeaderWidth;
          return Row(
            spacing: CarbonSpacing.spacing03,
            children: [
              if (widget.gitStatus != null)
                Text(
                  widget.gitStatus!,
                  style: _code.text.copyWith(
                    fontWeight: FontWeight.w600,
                    color: gitStatusColor(colors, widget.gitStatus!),
                  ),
                ),
              Expanded(
                child: Text(
                  widget.path,
                  style: _code.text.copyWith(color: colors.textPrimary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // Four-digit counts at a large text scale are wider than a docked
              // pane can spare; the Git row beside it already shows them.
              if (!compact && (widget.additions > 0 || widget.deletions > 0))
                CarbonDiffStat(
                  additions: widget.additions,
                  deletions: widget.deletions,
                ),
              if (compact)
                CarbonButton.iconOnly(
                  icon: const CarbonIcon(CarbonIcons.document),
                  semanticLabel: 'View file',
                  onPressed: widget.onViewFile,
                )
              else
                CarbonLink(
                  label: 'View file',
                  size: CarbonLinkSize.small,
                  onPressed: widget.onViewFile,
                ),
              CarbonButton.iconOnly(
                icon: const CarbonIcon(CarbonIcons.close),
                semanticLabel: 'Close diff',
                onPressed: widget.onClose,
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildHunkHeader(BuildContext context, String header) {
    final colors = CarbonTheme.of(context).colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: CarbonSpacing.spacing04),
      alignment: Alignment.centerLeft,
      color: colors.linkPrimary.withValues(alpha: _hunkTintAlpha),
      child: Text(
        header,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.clip,
        style: _code.text.copyWith(color: colors.linkPrimary),
      ),
    );
  }

  Widget _buildHunkGap(BuildContext context) {
    final colors = CarbonTheme.of(context).colors;
    return Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colors.layer01,
        border: Border.symmetric(
          horizontal: BorderSide(color: colors.borderSubtle01),
        ),
      ),
      child: Text(
        '···',
        style: _code.text.copyWith(color: colors.textSecondary),
      ),
    );
  }

  Widget _buildLine(BuildContext context, _DiffLine line) {
    final colors = CarbonTheme.of(context).colors;
    final (Color? bgColor, Color markerColor) = switch (line.type) {
      _DiffLineType.addition => (
        colors.supportSuccess.withValues(alpha: _tintAlpha),
        colors.supportSuccess,
      ),
      _DiffLineType.deletion => (
        colors.supportError.withValues(alpha: _tintAlpha),
        colors.supportError,
      ),
      _DiffLineType.context => (null, colors.textSecondary),
    };

    // Syntax colours come from the file viewer's own theme, so a line reads
    // identically in the diff and in the file. That leaves the row tint as the
    // only thing separating an addition from a deletion, which is colour
    // alone — unreadable to a red/green-blind eye and to a washed-out screen —
    // so the marker [_parseDiff] strips off the front is reinstated in its own
    // column. Plain text when the path has no known language.
    final span =
        _highlighter?.span(line.text, _code) ??
        TextSpan(text: line.text, style: _code.text);

    return Container(
      color: bgColor,
      alignment: Alignment.centerLeft,
      child: Row(
        spacing: CarbonSpacing.spacing03,
        children: [
          // ONE number per row: the line as it stands in the file now, falling
          // back to where a removed line used to be — the only row with no
          // "now" to point at. Two columns spent a second gutter restating a
          // number that is the same on all but the changed rows.
          _buildGutter(line.newLineNum ?? line.oldLineNum, colors.textSecondary),
          _buildMarker(line.type, markerColor),
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

  // Excluded from the SelectionArea (see [_buildBody]): a +/- marker is
  // layout, not content, and copying it in front of every line would corrupt
  // the code it's pasted back into.
  Widget _buildMarker(_DiffLineType type, Color color) {
    return SizedBox(
      width: _markerWidth,
      child: SelectionContainer.disabled(
        child: Text(
          switch (type) {
            _DiffLineType.addition => '+',
            _DiffLineType.deletion => '-',
            _DiffLineType.context => '',
          },
          maxLines: 1,
          style: _code.text.copyWith(color: color),
        ),
      ),
    );
  }

  // Excluded from the SelectionArea for the same reason as the marker: a line
  // number is a reference for reading the diff, not text anyone selecting the
  // code beside it wants in their clipboard.
  Widget _buildGutter(int? lineNum, Color color) {
    return SizedBox(
      width: _gutterWidth,
      child: SelectionContainer.disabled(
        child: Text(
          lineNum?.toString() ?? '',
          textAlign: TextAlign.right,
          maxLines: 1,
          style: _code.text.copyWith(color: color),
        ),
      ),
    );
  }

  /// Adds "Send to Agent" to the platform's own selection toolbar rather than
  /// floating a separate button: [selectableRegionState.contextMenuAnchors]
  /// is the same anchor Copy/Select All render from, so the action shows up
  /// exactly where the user made the selection instead of a fixed spot
  /// elsewhere in the panel — and disappears with the rest of the toolbar
  /// once they tap elsewhere, the same as any other selection action.
  Widget _buildContextMenu(
    BuildContext context,
    SelectableRegionState selectableRegionState,
  ) {
    final buttonItems = <ContextMenuButtonItem>[
      ...selectableRegionState.contextMenuButtonItems,
      ContextMenuButtonItem(
        label: 'Send to Agent',
        onPressed: () {
          final text = _lastSelection?.plainText;
          selectableRegionState.hideToolbar();
          if (text == null || text.trim().isEmpty) return;
          detached(
            'DiffViewer',
            'send selection to agent',
            () => _sendSelectionToAgent(text),
          );
        },
      ),
    ];
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: selectableRegionState.contextMenuAnchors,
      buttonItems: buttonItems,
    );
  }

  Future<void> _sendSelectionToAgent(String selectedText) async {
    final message = await showSendToAgentComment(
      context: context,
      selectedText: selectedText,
      sourceLabel: '[from diff: ${widget.path}]',
    );
    if (message == null || !mounted) return;
    await widget.onSendToAgent(context, message);
  }
}

/// Always visible rather than fading with use: a code line that runs past the
/// viewport gives no other cue that there is more to the side, so the thumb has
/// to say so at a glance. Paints nothing when the content fits.
class _DiffScrollbar extends StatelessWidget {
  const _DiffScrollbar({
    required this.controller,
    required this.notificationPredicate,
    required this.orientation,
    required this.child,
  });

  final ScrollController controller;
  final ScrollNotificationPredicate notificationPredicate;
  final ScrollbarOrientation orientation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return RawScrollbar(
      controller: controller,
      notificationPredicate: notificationPredicate,
      scrollbarOrientation: orientation,
      thumbVisibility: true,
      thickness: CarbonSpacing.spacing03,
      crossAxisMargin: CarbonSpacing.spacing01,
      thumbColor: CarbonTheme.of(context).colors.borderStrong01,
      child: child,
    );
  }
}
