// Coverage for the archived-scrollback reader: the row encoder
// (`encodeTerminalHistoryRows`, pure and easy to get silently wrong) and the
// widget built on top of it (`TerminalHistoryView`).
//
// The encoder tests pin every rule its own doc comment claims by asserting on
// the exact escape bytes it produces, plus one round trip through a real
// `GhosttyTerminalController` so the encoding is proved against an engine and
// not only against itself.
//
// The widget tests drive `TerminalHistoryModel` directly (as
// `terminal_history_model_test.dart` does) rather than a transport -- this
// widget never touches the wire, so the model IS the wire for these purposes.
// Nothing here positions focus by hand: the reader has to take the keyboard
// from the live pane it is raised over, and a test that hands it focus proves
// only that the key handler compiles.
import 'dart:convert';

import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/design/widgets/ab_empty_state.dart';
import 'package:antgrid/design/widgets/ab_icon_button.dart';
import 'package:antgrid/design/widgets/ab_inline_banner.dart';
import 'package:antgrid/design/widgets/ab_loading.dart';
import 'package:antgrid/models/ab_message.dart';
import 'package:antgrid/models/terminal_history_model.dart';
import 'package:antgrid/widgets/terminal_history_view.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';

/// True when the native VT is missing, having marked the current test
/// skipped -- same convention as terminal_frame_mode_widget_test.dart.
bool _hasNative() {
  try {
    GhosttyVt.newTerminal(cols: 8, rows: 2).close();
    return true;
  } catch (_) {
    return false;
  }
}

bool _skipWithoutNative() {
  if (_hasNative()) return false;
  markTestSkipped('native VT unavailable');
  return true;
}

// ---------------------------------------------------------------------------
// Shared row/model builders, mirroring terminal_history_model_test.dart's
// idiom.
// ---------------------------------------------------------------------------

TerminalHistorySpan _span(String text, {String sgr = '\x1b[0m', String? uri}) =>
    TerminalHistorySpan(text: text, cells: text.length, sgr: sgr, uri: uri);

TerminalHistoryRow _row({
  required int rowId,
  bool wrapped = false,
  int cols = 80,
  required List<TerminalHistorySpan> spans,
}) => TerminalHistoryRow(
  rowId: rowId,
  cols: cols,
  wrapped: wrapped,
  spans: spans,
);

TerminalHistoryBoundary _boundary({
  int epoch = 1,
  int firstRowId = 0,
  int nextRowId = 1000,
  String status = 'recording',
}) => TerminalHistoryBoundary(
  epoch: epoch,
  firstRowId: firstRowId,
  nextRowId: nextRowId,
  status: status,
);

/// A plain single-span row identified by its own id, for widget tests that
/// only care whether a given row is loaded, not its content.
TerminalHistoryRow _plainRow(int rowId) =>
    _row(rowId: rowId, spans: [_span('row $rowId')]);

/// One full page's worth, ending just below [exclusiveEnd].
List<TerminalHistoryRow> _rowsBelow(int exclusiveEnd, {int count = 200}) =>
    List<TerminalHistoryRow>.generate(
      count,
      (i) => _plainRow(exclusiveEnd - count + i),
    );

TerminalHistoryPageMessage _page({
  required String requestId,
  required List<TerminalHistoryRow> rows,
  TerminalHistoryBoundary? history,
  bool expired = false,
  int? beforeRowId,
}) {
  final boundary = history ?? _boundary();
  return TerminalHistoryPageMessage(
    id: 'm',
    timestamp: 0,
    terminalId: 't1',
    runId: 'run-1',
    attachmentId: 'att-1',
    requestId: requestId,
    history: boundary,
    expired: expired,
    beforeRowId:
        beforeRowId ?? (rows.isEmpty ? boundary.firstRowId : rows.first.rowId),
    rows: rows,
  );
}

/// Spies on subscribe/unsubscribe so the widget's model bookkeeping is
/// observable. [listening] republishes [ChangeNotifier.hasListeners], which is
/// protected: whether the widget is still attached to a model it was supposed
/// to drop is the whole assertion, and no rendered output can stand in for it
/// (the widget renders `widget.model`, so a leaked listener re-reads the NEW
/// model and produces byte-identical frames).
class _SpyHistoryModel extends TerminalHistoryModel {
  int addCount = 0;
  int removeCount = 0;

  bool get listening => hasListeners;

  @override
  void addListener(VoidCallback listener) {
    addCount++;
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    removeCount++;
    super.removeListener(listener);
  }
}

Widget _wrap(Widget child, {double width = 320, double height = 240}) =>
    MaterialApp(
      theme: ThemeData.dark().copyWith(
        extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
      ),
      home: Scaffold(
        body: SizedBox(width: width, height: height, child: child),
      ),
    );

TerminalHistoryView _view({
  required TerminalHistoryModel model,
  VoidCallback? onLoadMore,
  VoidCallback? onClose,
}) => TerminalHistoryView(
  model: model,
  onLoadMore: onLoadMore ?? () {},
  onClose: onClose ?? () {},
  fontSize: 13,
  fontWeight: FontWeight.w400,
  boldFontWeight: FontWeight.w700,
  minimumContrastRatio: 1.0,
);

/// A model holding one answered page, which is what the reader is normally
/// opened onto.
TerminalHistoryModel _loadedModel({int count = 200, int nextRowId = 1000}) {
  final m = TerminalHistoryModel()
    ..applyBoundary(_boundary(nextRowId: nextRowId));
  m.markRequested('seed');
  m.applyPage(
    _page(
      requestId: 'seed',
      rows: _rowsBelow(nextRowId, count: count),
      history: _boundary(nextRowId: nextRowId),
    ),
  );
  return m;
}

/// The reader's own focus node label, for telling "the reader holds the
/// keyboard" apart from "the embedded engine does".
const String _readerFocus = 'TerminalHistoryView';

GhosttyTerminalView _mountedTerminal(WidgetTester tester) =>
    tester.widget<GhosttyTerminalView>(find.byType(GhosttyTerminalView));

/// The engine's own line box, in pixels.
///
/// [GhosttyTerminalView] sizes its extent as `(scrollable rows) * (line
/// pixels)` and reports those rows through `viewportScrollbar`, so this is the
/// height it actually laid out -- and the tolerance a keyboard scroll is worth
/// judging against, since the view snaps every offset to a whole row.
double _lineHeight(WidgetTester tester) {
  final view = _mountedTerminal(tester);
  final bar = view.controller.viewportScrollbar!;
  final scrollable = bar.total - bar.length;
  return view.scrollController!.position.maxScrollExtent / scrollable;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('encodeTerminalHistoryRows', () {
    test('a newline is written only before a row that is not wrapped, never '
        'before the first row or after the last', () {
      final rows = [
        _row(rowId: 0, spans: [_span('a')]),
        _row(rowId: 1, wrapped: true, spans: [_span('b')]),
        _row(rowId: 2, spans: [_span('c')]),
      ];
      final out = utf8.decode(encodeTerminalHistoryRows(rows));
      expect(
        out,
        '\x1b[0ma\x1b[0m'
        '\x1b[0mb\x1b[0m'
        '\r\n\x1b[0mc\x1b[0m',
      );
    });

    test(
      'trailing default-styled blanks are stripped only from a row that ends '
      'its logical line',
      () {
        // Row 0 is continued by a wrapped row 1, so row 0 does NOT end the
        // line -- its padding is real width the row was captured at and must
        // survive.
        final continued = [
          _row(rowId: 0, spans: [_span('hi   ')]),
          _row(rowId: 1, wrapped: true, spans: [_span('END')]),
        ];
        expect(
          utf8.decode(encodeTerminalHistoryRows(continued)),
          contains('hi   '),
        );

        // The same padded row alone ends its own line and gets trimmed --
        // the agent pads every archived row out to `cols`.
        final ending = [
          _row(rowId: 0, spans: [_span('hi   ')]),
        ];
        final endingOut = utf8.decode(encodeTerminalHistoryRows(ending));
        expect(endingOut, isNot(contains('hi   ')));
        expect(endingOut, contains('hi\x1b[0m'));
      },
    );

    test('only default-styled blanks are trimmed -- a styled or hyperlinked '
        'trailing run is content and survives', () {
      final styledBlank = [
        _row(
          rowId: 0,
          spans: [
            _span('hi'),
            // Reverse video, not the default SGR: a TUI painted this.
            _span('   ', sgr: '\x1b[7m'),
          ],
        ),
      ];
      expect(
        utf8.decode(encodeTerminalHistoryRows(styledBlank)),
        contains('\x1b[7m   '),
      );

      final linkedBlank = [
        _row(
          rowId: 0,
          spans: [
            _span('hi'),
            _span('   ', uri: 'https://example.test'),
          ],
        ),
      ];
      final linkedOut = utf8.decode(encodeTerminalHistoryRows(linkedBlank));
      expect(linkedOut, contains('\x1b[0m   '));
      expect(linkedOut, contains('https://example.test'));
    });

    test(
      'OSC 8 opens when the uri changes and closes before the next span, and '
      'at the end of a row that leaves one open',
      () {
        final midRowClose = [
          _row(
            rowId: 0,
            spans: [
              _span('a'),
              _span('link', uri: 'https://x.test'),
              _span('after'),
            ],
          ),
        ];
        expect(
          utf8.decode(encodeTerminalHistoryRows(midRowClose)),
          '\x1b[0ma'
          '\x1b]8;;https://x.test\x1b\\\x1b[0mlink'
          '\x1b]8;;\x1b\\\x1b[0mafter'
          '\x1b[0m',
        );

        final endRowOpen = [
          _row(
            rowId: 0,
            spans: [
              _span('a'),
              _span('link', uri: 'https://y.test'),
            ],
          ),
        ];
        expect(
          utf8.decode(encodeTerminalHistoryRows(endRowOpen)),
          '\x1b[0ma'
          '\x1b]8;;https://y.test\x1b\\\x1b[0mlink'
          // Closed even though nothing after it changed the uri back --
          // otherwise this hyperlink would swallow the row below it.
          '\x1b]8;;\x1b\\'
          '\x1b[0m',
        );
      },
    );

    test('a uri containing a control character is dropped rather than written '
        'into the OSC 8, which it would otherwise terminate early', () {
      final rows = [
        _row(rowId: 0, spans: [_span('link', uri: 'https://x.test/\x07evil')]),
      ];
      final out = utf8.decode(encodeTerminalHistoryRows(rows));
      expect(out, isNot(contains('\x1b]8;;')));
      expect(out, isNot(contains('evil')));
      // Only the uri is dropped -- the span's text is still real content.
      expect(out, contains('link'));
    });

    test('a row of only default-styled blanks collapses to an empty line, not '
        'a line of spaces', () {
      final rows = [
        _row(rowId: 0, spans: [_span('    ')]),
      ];
      // Byte-exact: the row's whole span is trimmed away and what remains is
      // the reset every row ends with. Asserting only the absence of a space
      // would pass just as well on an encoder that emitted nothing at all.
      expect(utf8.decode(encodeTerminalHistoryRows(rows)), '\x1b[0m');
    });

    test('feeds the encoder output to a real terminal engine and gets the '
        'joined, trimmed text back', () {
      if (_skipWithoutNative()) return;
      final rows = [
        // Wrapped continuation: joined with row 1 into one logical line
        // and NOT trimmed (it does not end the line).
        _row(rowId: 0, cols: 10, spans: [_span('hello ')]),
        _row(rowId: 1, cols: 10, wrapped: true, spans: [_span('world     ')]),
        // A standalone row after it, proving the newline before a
        // non-wrapped row actually breaks the engine's own line.
        _row(rowId: 2, cols: 10, spans: [_span('bye')]),
      ];
      final controller = GhosttyTerminalController(
        initialCols: 80,
        initialRows: 24,
      );
      addTearDown(controller.dispose);
      controller.appendOutputBytes(encodeTerminalHistoryRows(rows));

      final text = controller.plainText;
      expect(text, contains('hello world'));
      expect(text, isNot(contains('hello world bye')));
      expect(text, contains('bye'));
    });
  });

  // Every test below mounts the widget, and the widget drives a real engine
  // from `initState` -- so all of them need the native VT, not just the ones
  // that assert on rendered rows.
  group('TerminalHistoryView', () {
    testWidgets(
      'wide history stays seekable without native trimming on a narrow pane',
      (tester) async {
        GhosttyVt.newTerminal(cols: 8, rows: 2).close();
        final model = TerminalHistoryModel()
          ..applyBoundary(_boundary(nextRowId: 400));
        model.markRequested('seed');
        model.applyPage(
          _page(
            requestId: 'seed',
            history: _boundary(nextRowId: 400),
            rows: List.generate(
              400,
              (i) => _row(
                rowId: i,
                cols: 1000,
                spans: [_span('${i.toString().padLeft(4, '0')}${'x' * 996}')],
              ),
            ),
          ),
        );
        final key = GlobalKey<TerminalHistoryViewState>();
        Widget pane(double width) => _wrap(
          TerminalHistoryView(
            key: key,
            model: model,
            onLoadMore: () {},
            onClose: () {},
            initialRowId: 200,
            fontSize: 13,
            fontWeight: FontWeight.w400,
            boldFontWeight: FontWeight.w700,
            minimumContrastRatio: 1,
          ),
          width: width,
        );
        String topText() {
          final terminal = _mountedTerminal(tester).controller.terminal;
          return List.generate(
            4,
            (x) => terminal.gridRef(VtPoint.viewport(x, 0)).graphemes,
          ).join();
        }

        await tester.pumpWidget(pane(160));
        await tester.pumpAndSettle();
        expect(
          _mountedTerminal(tester).controller.terminal.totalRows,
          lessThan(8000),
        );
        expect(topText(), '0200');
        await tester.pumpWidget(pane(100));
        await tester.pumpAndSettle();
        expect(
          _mountedTerminal(tester).controller.terminal.totalRows,
          lessThan(8000),
        );
        expect(topText(), '0200');
        key.currentState!.seekRow(20);
        await tester.pumpAndSettle();
        expect(topText(), '0020');
      },
    );
    testWidgets(
      'indexed scrollbar seeks backward and forward beyond cache limits',
      (tester) async {
        GhosttyVt.newTerminal(cols: 8, rows: 2).close();
        final model = TerminalHistoryModel(maxRows: 200)
          ..applyBoundary(_boundary(nextRowId: 10000));
        final key = GlobalKey<TerminalHistoryViewState>();
        var requests = 0;
        void load() {
          if (!model.canLoadMore) return;
          final end = model.cursor!;
          final id = 'page-${requests++}';
          model.markRequested(id);
          model.applyPage(
            _page(
              requestId: id,
              rows: _rowsBelow(end, count: end < 200 ? end : 200),
              history: _boundary(nextRowId: 10000),
            ),
          );
        }

        await tester.pumpWidget(
          _wrap(
            TerminalHistoryView(
              key: key,
              model: model,
              onLoadMore: load,
              onClose: () {},
              initialRowId: 5000,
              fontSize: 13,
              fontWeight: FontWeight.w400,
              boldFontWeight: FontWeight.w700,
              minimumContrastRatio: 1,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          _mountedTerminal(tester).controller.plainText,
          contains('row 5000'),
        );
        key.currentState!.seekRow(1000);
        await tester.pumpAndSettle();
        expect(
          _mountedTerminal(tester).controller.plainText,
          contains('row 1000'),
        );
        key.currentState!.seekRow(9000);
        await tester.pumpAndSettle();
        expect(
          _mountedTerminal(tester).controller.plainText,
          contains('row 9000'),
        );
        expect(model.rows.length, lessThanOrEqualTo(200));
        expect(requests, 3);
      },
    );

    testWidgets(
      'frozen screen joins its exact archive boundary while new output arrives',
      (tester) async {
        GhosttyVt.newTerminal(cols: 8, rows: 2).close();
        final model = _loadedModel(nextRowId: 1000);
        final screen = List.generate(10, (i) => _plainRow(1000 + i));
        await tester.pumpWidget(
          _wrap(
            TerminalHistoryView(
              model: model,
              onLoadMore: () {},
              onClose: () {},
              historyEndRow: 1000,
              screenRows: screen,
              fontSize: 13,
              fontWeight: FontWeight.w400,
              boldFontWeight: FontWeight.w700,
              minimumContrastRatio: 1,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final before = _mountedTerminal(tester).controller.plainText;
        expect(before, contains('row 999\nrow 1000'));
        model.applyBoundary(_boundary(nextRowId: 1400));
        await tester.pumpAndSettle();
        expect(_mountedTerminal(tester).controller.plainText, before);
      },
    );
    testWidgets(
      'reopening fetches newly archived rows even after reaching oldest',
      (tester) async {
        GhosttyVt.newTerminal(cols: 8, rows: 2).close();
        final m = TerminalHistoryModel()
          ..applyBoundary(_boundary(nextRowId: 20));
        var requests = 0;
        void load() {
          final end = m.cursor!;
          final request = 'page-${requests++}';
          m.markRequested(request);
          m.applyPage(
            _page(
              requestId: request,
              rows: _rowsBelow(end, count: 20),
              history: m.boundary,
            ),
          );
        }

        await tester.pumpWidget(_wrap(_view(model: m, onLoadMore: load)));
        await tester.pumpAndSettle();
        expect(m.atOldest, isTrue);
        expect(requests, 1);
        m.applyBoundary(_boundary(nextRowId: 40));
        await tester.pumpAndSettle();
        expect(requests, 1);
        expect(m.rows.last.rowId, 19);
        await tester.pumpWidget(_wrap(const SizedBox.shrink()));
        await tester.pumpWidget(_wrap(_view(model: m, onLoadMore: load)));
        await tester.pumpAndSettle();
        expect(requests, 2);
        expect(
          _mountedTerminal(tester).controller.plainText,
          contains('row 39'),
        );
      },
    );

    for (final byteLimited in [false, true]) {
      testWidgets(
        'paging preserves visible text after ${byteLimited ? 'byte' : 'row'} eviction',
        (tester) async {
          GhosttyVt.newTerminal(cols: 8, rows: 2).close();
          List<TerminalHistoryRow> pageRows(int end) => List.generate(200, (i) {
            final id = end - 200 + i;
            return _row(
              rowId: id,
              wrapped: byteLimited && id.isOdd,
              spans: [
                _span(byteLimited ? 'row $id ${'界e\u0301' * 24}' : 'row $id'),
              ],
            );
          });
          final m = TerminalHistoryModel(maxRows: 400)
            ..applyBoundary(_boundary());
          m.markRequested('seed');
          m.applyPage(_page(requestId: 'seed', rows: pageRows(1000)));
          m.markRequested('older');
          m.applyPage(_page(requestId: 'older', rows: pageRows(800)));
          final model = byteLimited
              ? (TerminalHistoryModel(maxBytes: m.cachedBytes)
                  ..applyBoundary(_boundary()))
              : m;
          if (byteLimited) {
            model.markRequested('seed');
            model.applyPage(_page(requestId: 'seed', rows: m.rows));
          }
          await tester.pumpWidget(_wrap(_view(model: model)));
          await tester.pumpAndSettle();
          final controller = _mountedTerminal(tester).controller;
          String visible() => controller.renderSnapshot!.rowsData
              .map((row) => row.cells.map((cell) => cell.text).join())
              .join('\n');
          for (final end in [600, 400]) {
            controller.scrollViewportToTop();
            await tester.pumpAndSettle();
            final before = visible();
            model.markRequested('page-$end');
            model.applyPage(_page(requestId: 'page-$end', rows: pageRows(end)));
            for (var i = 0; i < 12; i++) {
              await tester.pump(const Duration(milliseconds: 50));
            }
            expect(visible(), before);
            expect(model.cachedBytes, lessThanOrEqualTo(model.maxBytes));
            expect(model.rows.length, lessThanOrEqualTo(model.maxRows));
          }
        },
      );
    }

    testWidgets(
      'an empty model that is still loading shows the loading state',
      (tester) async {
        if (_skipWithoutNative()) return;
        final m = TerminalHistoryModel()..applyBoundary(_boundary());
        m.markRequested('r1');

        await tester.pumpWidget(_wrap(_view(model: m)));
        await tester.pump();

        expect(find.byType(AbLoading), findsOneWidget);
        expect(find.text('Loading scrollback'), findsOneWidget);
        expect(find.byType(GhosttyTerminalView), findsNothing);
      },
    );

    testWidgets(
      'an empty model that is not recording shows the not-recorded empty '
      'state',
      (tester) async {
        if (_skipWithoutNative()) return;
        final m = TerminalHistoryModel()
          ..applyBoundary(_boundary(status: 'disabled'));

        await tester.pumpWidget(_wrap(_view(model: m)));
        await tester.pump();

        expect(
          find.text('Scrollback was not recorded for this run'),
          findsOneWidget,
        );
        expect(find.byType(GhosttyTerminalView), findsNothing);
        expect(find.byType(AbLoading), findsNothing);
      },
    );

    testWidgets('a model with loaded rows shows the terminal', (tester) async {
      if (_skipWithoutNative()) return;
      await tester.pumpWidget(_wrap(_view(model: _loadedModel(count: 20))));
      await tester.pumpAndSettle();

      expect(find.byType(GhosttyTerminalView), findsOneWidget);
      expect(find.byType(AbEmptyState), findsNothing);
      expect(find.byType(AbLoading), findsNothing);
    });

    testWidgets(
      'mounting with an empty, loadable model fires onLoadMore exactly once',
      (tester) async {
        if (_skipWithoutNative()) return;
        final m = TerminalHistoryModel()
          ..applyBoundary(_boundary(nextRowId: 1000));
        var calls = 0;

        await tester.pumpWidget(
          _wrap(_view(model: m, onLoadMore: () => calls++)),
        );
        await tester.pump();
        expect(calls, 1);

        // Nothing about the model changed -- must not keep firing on every
        // later frame.
        await tester.pump(const Duration(milliseconds: 50));
        await tester.pump(const Duration(milliseconds: 50));
        expect(calls, 1);
      },
    );

    testWidgets('mounting with rows already loaded does not fire onLoadMore', (
      tester,
    ) async {
      if (_skipWithoutNative()) return;
      var calls = 0;

      await tester.pumpWidget(
        _wrap(_view(model: _loadedModel(count: 5), onLoadMore: () => calls++)),
      );
      await tester.pump();

      expect(calls, 0);
    });

    testWidgets(
      'an empty model that cannot page is never asked for a first page, on '
      'mount or on a swap',
      (tester) async {
        if (_skipWithoutNative()) return;
        // Nothing was recorded for this run, so the empty state IS the answer.
        // Asking anyway spends a round trip per reader raised on a question
        // the agent has already refused.
        final m1 = TerminalHistoryModel()
          ..applyBoundary(_boundary(status: 'disabled', nextRowId: 0));
        expect(m1.rows, isEmpty);
        expect(m1.canLoadMore, isFalse);
        var calls = 0;

        await tester.pumpWidget(
          _wrap(_view(model: m1, onLoadMore: () => calls++)),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(calls, 0);

        final m2 = TerminalHistoryModel()
          ..applyBoundary(_boundary(status: 'disabled', nextRowId: 0));
        await tester.pumpWidget(
          _wrap(_view(model: m2, onLoadMore: () => calls++)),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(calls, 0);
      },
    );

    testWidgets(
      'onScrollPastTop asks for more only while canLoadMore is true, and '
      'repeated firing does not stack requests',
      (tester) async {
        if (_skipWithoutNative()) return;
        final m = _loadedModel(count: 20);
        var calls = 0;

        await tester.pumpWidget(
          _wrap(_view(model: m, onLoadMore: () => calls++)),
        );
        await tester.pumpAndSettle();

        final pastTop = _mountedTerminal(tester).onScrollPastTop!;

        pastTop();
        expect(calls, 1);

        // The host would mark a request outstanding here, same as the real
        // onLoadMore handler does -- canLoadMore goes false and repeats
        // (the callback fires once per clamped scroll step) must be
        // swallowed rather than queued.
        m.markRequested('r2');
        pastTop();
        pastTop();
        pastTop();
        expect(calls, 1);

        // Once the page lands and loading clears, the next push at the top
        // asks again.
        m.applyPage(_page(requestId: 'r2', rows: _rowsBelow(980, count: 20)));
        pastTop();
        expect(calls, 2);
      },
    );

    testWidgets('onScrollPastTop is a no-op once the model reports atOldest', (
      tester,
    ) async {
      if (_skipWithoutNative()) return;
      // A full page whose oldest row IS the archive's firstRowId: rows are
      // loaded (the terminal renders) but there is nothing older to ask
      // for.
      final m = TerminalHistoryModel()
        ..applyBoundary(_boundary(firstRowId: 800, nextRowId: 1000));
      m.markRequested('r1');
      m.applyPage(
        _page(
          requestId: 'r1',
          rows: _rowsBelow(1000, count: 200),
          history: _boundary(firstRowId: 800, nextRowId: 1000),
        ),
      );
      expect(m.atOldest, isTrue);
      var calls = 0;

      await tester.pumpWidget(
        _wrap(_view(model: m, onLoadMore: () => calls++)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(GhosttyTerminalView), findsOneWidget);

      final pastTop = _mountedTerminal(tester).onScrollPastTop!;
      pastTop();
      pastTop();
      expect(calls, 0);
    });

    testWidgets('a real wheel scroll clamped at the top reaches onLoadMore', (
      tester,
    ) async {
      if (_skipWithoutNative()) return;
      // The two tests above call the callback directly, which proves what it
      // does and nothing about whether it is wired to anything. This drives
      // the pointer instead.
      final m = _loadedModel();
      var calls = 0;

      await tester.pumpWidget(
        _wrap(_view(model: m, onLoadMore: () => calls++)),
      );
      await tester.pumpAndSettle();
      expect(calls, 0);

      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      final center = tester.getCenter(find.byType(GhosttyTerminalView));
      await tester.sendEventToBinding(pointer.hover(center));
      // Far more transcript than is loaded: the scroll clamps at the oldest
      // row, which is what "past top" means.
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, -100000)));
      await tester.pumpAndSettle();

      expect(calls, 1);
    });

    testWidgets(
      'applying a page rebuilds the engine so the older rows appear',
      (tester) async {
        if (_skipWithoutNative()) return;
        final m = _loadedModel(count: 20);

        await tester.pumpWidget(_wrap(_view(model: m)));
        await tester.pumpAndSettle();

        final controller = _mountedTerminal(tester).controller;
        expect(controller.plainText, isNot(contains('row 965')));

        m.markRequested('r2');
        m.applyPage(_page(requestId: 'r2', rows: _rowsBelow(980, count: 20)));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));
        await tester.pumpAndSettle();

        expect(controller.plainText, contains('row 965'));
      },
    );

    testWidgets(
      'applying a page preserves the reader\'s scroll offset instead of '
      'snapping back to the bottom',
      (tester) async {
        if (_skipWithoutNative()) return;
        // Enough rows that the buffer overflows the viewport.
        final m = _loadedModel();

        await tester.pumpWidget(_wrap(_view(model: m)));
        await tester.pumpAndSettle();

        final scroll = _mountedTerminal(tester).scrollController!;
        expect(scroll.hasClients, isTrue);
        expect(scroll.position.maxScrollExtent, greaterThan(0));

        final target = scroll.position.maxScrollExtent / 2;
        scroll.jumpTo(target);
        await tester.pump();
        expect(scroll.offset, closeTo(target, 0.5));

        m.markRequested('r2');
        m.applyPage(_page(requestId: 'r2', rows: _rowsBelow(800, count: 200)));

        // The engine re-parses the whole re-ingested buffer off the widget
        // tree's clock -- give it real time to settle.
        for (var i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        await tester.pumpAndSettle();

        expect(
          scroll.offset,
          closeTo(target, 1.0),
          reason:
              'the reader was reading mid-scrollback; a page landing '
              'must not pull them back to the live bottom',
        );
      },
    );

    testWidgets(
      'a restore target the rebuilt buffer never grew into is abandoned, not '
      'applied to the next page',
      (tester) async {
        if (_skipWithoutNative()) return;
        final m = _loadedModel();

        await tester.pumpWidget(_wrap(_view(model: m)));
        await tester.pumpAndSettle();

        final scroll = _mountedTerminal(tester).scrollController!;
        scroll.jumpTo(scroll.position.maxScrollExtent / 2);
        await tester.pump();
        expect(scroll.offset, greaterThan(0));

        // Retention passed the cursor: every loaded row is dropped, so the
        // rebuilt engine is empty and the offset captured a moment ago names a
        // row that no longer exists anywhere.
        m.markRequested('r2');
        m.applyPage(_page(requestId: 'r2', rows: const [], expired: true));
        await tester.pumpAndSettle();
        expect(find.byType(GhosttyTerminalView), findsNothing);

        // Paging restarts from the boundary, and the reader is looking at the
        // live bottom of an archive they have not scrolled in.
        m.markRequested('r3');
        m.applyPage(_page(requestId: 'r3', rows: _rowsBelow(1000, count: 200)));
        for (var i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        await tester.pumpAndSettle();

        expect(
          _mountedTerminal(tester).scrollController!.offset,
          closeTo(0, 1.0),
          reason:
              'the abandoned target belonged to rows the agent no longer '
              'serves; applying it moves the reader somewhere they never were',
        );
      },
    );

    testWidgets(
      'swapping the model abandons a restore target armed for the old one',
      (tester) async {
        if (_skipWithoutNative()) return;
        final m1 = _loadedModel();

        await tester.pumpWidget(_wrap(_view(model: m1)));
        await tester.pumpAndSettle();

        final scroll = _mountedTerminal(tester).scrollController!;
        scroll.jumpTo(scroll.position.maxScrollExtent / 2);
        await tester.pump();
        expect(scroll.offset, greaterThan(0));

        m1.markRequested('r2');
        m1.applyPage(_page(requestId: 'r2', rows: const [], expired: true));
        await tester.pumpAndSettle();

        await tester.pumpWidget(_wrap(_view(model: _loadedModel())));
        for (var i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        await tester.pumpAndSettle();

        expect(
          _mountedTerminal(tester).scrollController!.offset,
          closeTo(0, 1.0),
          reason:
              'a different terminal\'s archive: the old reader\'s place in '
              'it means nothing',
        );
      },
    );

    testWidgets(
      'swapping to an archive with nothing loaded yet drops the old engine, so '
      'its first page opens at the live bottom',
      (tester) async {
        if (_skipWithoutNative()) return;
        // The swap test above hands over an already-loaded model, so the row
        // signature changes and the engine is rebuilt on the way through. This
        // is the other half: an archive whose page has not landed yet has NO
        // rows, and so the same `null` signature the reader would have had if
        // its own rows had been dropped -- nothing in the signature can tell
        // the two terminals apart.
        final m1 = _loadedModel();

        await tester.pumpWidget(_wrap(_view(model: m1)));
        await tester.pumpAndSettle();

        final scroll = _mountedTerminal(tester).scrollController!;
        scroll.jumpTo(scroll.position.maxScrollExtent / 2);
        await tester.pump();
        final parked = scroll.offset;
        expect(parked, greaterThan(0));

        final m2 = TerminalHistoryModel()
          ..applyBoundary(_boundary(nextRowId: 500));
        await tester.pumpWidget(_wrap(_view(model: m2)));
        await tester.pumpAndSettle();
        expect(find.byType(GhosttyTerminalView), findsNothing);

        // Idle far past the restore window: nothing here expires, because the
        // stale target is the ENGINE's own viewport, which no timer touches.
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 500));
        }

        m2.markRequested('r1');
        m2.applyPage(_page(requestId: 'r1', rows: _rowsBelow(500, count: 200)));
        for (var i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        await tester.pumpAndSettle();

        final after = _mountedTerminal(tester);
        expect(after.controller.plainText, contains('row 499'));
        expect(
          after.scrollController!.offset,
          closeTo(0, 1.0),
          reason:
              'the reader has never scrolled in THIS archive; opening its '
              'first page $parked pixels up puts them somewhere they have '
              'never been, in a terminal they were never reading',
        );
      },
    );

    testWidgets(
      'swapping to an archive with nothing loaded yet asks for its first page',
      (tester) async {
        if (_skipWithoutNative()) return;
        var calls = 0;

        await tester.pumpWidget(
          _wrap(_view(model: _loadedModel(), onLoadMore: () => calls++)),
        );
        await tester.pumpAndSettle();
        expect(calls, 0);

        final m2 = TerminalHistoryModel()
          ..applyBoundary(_boundary(nextRowId: 500));
        await tester.pumpWidget(
          _wrap(_view(model: m2, onLoadMore: () => calls++)),
        );
        await tester.pump();
        expect(
          calls,
          1,
          reason:
              'an empty model renders no terminal, so there is no viewport '
              'and no wheel to page the swapped-in archive with',
        );

        // Nothing about the model changed: must not keep asking frame after
        // frame.
        await tester.pump(const Duration(milliseconds: 50));
        await tester.pump(const Duration(milliseconds: 50));
        expect(calls, 1);

        // Swapping to an archive that already has rows asks for nothing -- the
        // reader can see it and page it themselves.
        await tester.pumpWidget(
          _wrap(_view(model: _loadedModel(), onLoadMore: () => calls++)),
        );
        await tester.pumpAndSettle();
        expect(calls, 1);
      },
    );

    testWidgets(
      'a pending restore leaves no timer behind when the reader is closed',
      (tester) async {
        if (_skipWithoutNative()) return;
        final m = _loadedModel();

        await tester.pumpWidget(_wrap(_view(model: m)));
        await tester.pumpAndSettle();

        final scroll = _mountedTerminal(tester).scrollController!;
        scroll.jumpTo(scroll.position.maxScrollExtent / 2);
        await tester.pump();

        // Arms a restore the empty rebuild can never satisfy, so it is still
        // pending at teardown -- which the framework fails the test for unless
        // dispose cancels it.
        m.markRequested('r2');
        m.applyPage(_page(requestId: 'r2', rows: const [], expired: true));
        await tester.pump();

        await tester.pumpWidget(_wrap(const SizedBox.shrink()));
        await tester.pump();
      },
    );

    testWidgets('Escape closes the reader', (tester) async {
      if (_skipWithoutNative()) return;
      var closed = 0;

      await tester.pumpWidget(
        _wrap(_view(model: _loadedModel(count: 5), onClose: () => closed++)),
      );
      await tester.pumpAndSettle();

      // Deliberately nothing here positions focus. In production the reader is
      // raised over a live pane that holds it and never offers it up, so a
      // reader that has to be clicked before Escape works is one Escape does
      // not close.
      expect(FocusManager.instance.primaryFocus?.debugLabel, _readerFocus);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(closed, 1);
    });

    testWidgets(
      'the reader takes the keyboard from a pane that already holds it',
      (tester) async {
        if (_skipWithoutNative()) return;
        // Production's shape, which the tests above cannot reproduce by
        // mounting the reader alone: it is raised INTO a scope whose focus the
        // live pane already owns. That is precisely the case `Focus.autofocus`
        // does not serve -- it applies only while a scope has no focused child
        // -- so the reader has to TAKE the keyboard or every key goes on
        // reaching the pane underneath it.
        final live = FocusNode(debugLabel: 'LivePane');
        addTearDown(live.dispose);
        var closed = 0;

        Widget stack(Widget? reader) => _wrap(
          Column(
            children: [
              Focus(focusNode: live, child: const SizedBox(height: 8)),
              Expanded(child: reader ?? const SizedBox.shrink()),
            ],
          ),
        );

        await tester.pumpWidget(stack(null));
        live.requestFocus();
        await tester.pumpAndSettle();
        expect(FocusManager.instance.primaryFocus?.debugLabel, 'LivePane');

        await tester.pumpWidget(
          stack(_view(model: _loadedModel(count: 5), onClose: () => closed++)),
        );
        await tester.pumpAndSettle();

        expect(FocusManager.instance.primaryFocus?.debugLabel, _readerFocus);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(
          closed,
          1,
          reason:
              'a reader whose Escape only works once the live pane has '
              'given the keyboard up is a reader Escape does not close',
        );
      },
    );

    testWidgets('the embedded engine is mounted without autofocus', (
      tester,
    ) async {
      if (_skipWithoutNative()) return;
      await tester.pumpWidget(_wrap(_view(model: _loadedModel(count: 5))));
      await tester.pumpAndSettle();

      // Asserted on the property rather than through the keyboard: the
      // reader's own post-frame `requestFocus` runs after the engine's
      // autofocus would have and wins regardless, so no key this harness can
      // send tells the two settings apart.
      expect(_mountedTerminal(tester).autofocus, isFalse);
    });

    testWidgets(
      'Escape still closes the reader after the transcript has been clicked',
      (tester) async {
        if (_skipWithoutNative()) return;
        var closed = 0;

        await tester.pumpWidget(
          _wrap(_view(model: _loadedModel(), onClose: () => closed++)),
        );
        await tester.pumpAndSettle();

        // A click hands focus to the engine, which declines Escape (it has no
        // transport and no selection) and passes it up.
        await tester.tap(find.byType(GhosttyTerminalView));
        await tester.pumpAndSettle();
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          isNot(_readerFocus),
        );

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();

        expect(closed, 1);
      },
    );

    testWidgets('Page Up and Page Down move the reader a screen at a time', (
      tester,
    ) async {
      if (_skipWithoutNative()) return;
      await tester.pumpWidget(_wrap(_view(model: _loadedModel())));
      await tester.pumpAndSettle();

      final scroll = _mountedTerminal(tester).scrollController!;
      final page = scroll.position.viewportDimension;
      final line = _lineHeight(tester);
      expect(scroll.offset, 0);
      expect(scroll.position.maxScrollExtent, greaterThan(page * 2));

      await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
      await tester.pumpAndSettle();
      expect(scroll.offset, closeTo(page, line));

      await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
      await tester.pumpAndSettle();
      expect(scroll.offset, closeTo(page * 2, line * 2));

      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pumpAndSettle();
      expect(scroll.offset, closeTo(page, line * 2));
    });

    testWidgets('Arrow Up and Arrow Down move the reader one row at a time', (
      tester,
    ) async {
      if (_skipWithoutNative()) return;
      await tester.pumpWidget(_wrap(_view(model: _loadedModel())));
      await tester.pumpAndSettle();

      final scroll = _mountedTerminal(tester).scrollController!;
      final line = _lineHeight(tester);
      expect(line, greaterThan(1));

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(scroll.offset, closeTo(line, 1.0));

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(scroll.offset, closeTo(line * 2, 1.0));

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(scroll.offset, closeTo(line, 1.0));
    });

    testWidgets('Home goes to the oldest loaded row and End back to the live '
        'bottom', (tester) async {
      if (_skipWithoutNative()) return;
      await tester.pumpWidget(_wrap(_view(model: _loadedModel())));
      await tester.pumpAndSettle();

      final scroll = _mountedTerminal(tester).scrollController!;
      final line = _lineHeight(tester);
      final oldest = scroll.position.maxScrollExtent;
      expect(oldest, greaterThan(0));

      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pumpAndSettle();
      expect(scroll.offset, closeTo(oldest, line));

      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pumpAndSettle();
      expect(scroll.offset, closeTo(0, 1.0));
    });

    testWidgets(
      'the navigation keys still work after the transcript has been clicked',
      (tester) async {
        if (_skipWithoutNative()) return;
        // The case the engine used to lose: with focus on the embedded view,
        // every key it declined yanked the reader back to the live bottom.
        await tester.pumpWidget(_wrap(_view(model: _loadedModel())));
        await tester.pumpAndSettle();

        final scroll = _mountedTerminal(tester).scrollController!;
        await tester.tap(find.byType(GhosttyTerminalView));
        await tester.pumpAndSettle();
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          isNot(_readerFocus),
        );

        final page = scroll.position.viewportDimension;
        final line = _lineHeight(tester);

        await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
        await tester.pumpAndSettle();
        expect(scroll.offset, closeTo(page, line));

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pumpAndSettle();
        expect(scroll.offset, closeTo(page + line, line));
      },
    );

    testWidgets(
      'a key the reader does not navigate with leaves the viewport alone',
      (tester) async {
        if (_skipWithoutNative()) return;
        await tester.pumpWidget(_wrap(_view(model: _loadedModel())));
        await tester.pumpAndSettle();

        final scroll = _mountedTerminal(tester).scrollController!;
        await tester.sendKeyEvent(LogicalKeyboardKey.home);
        await tester.pumpAndSettle();

        // With focus on the engine every key below reaches IT first. A key it
        // declines earns no viewport move -- pinning the half of this that
        // lives in the fork, since a transcript view has no transport and so
        // declines all of them.
        await tester.tap(find.byType(GhosttyTerminalView));
        await tester.pumpAndSettle();
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          isNot(_readerFocus),
        );
        final parked = scroll.offset;
        expect(parked, greaterThan(0));

        for (final key in [
          LogicalKeyboardKey.f5,
          LogicalKeyboardKey.arrowLeft,
          LogicalKeyboardKey.keyA,
        ]) {
          await tester.sendKeyEvent(key);
          await tester.pumpAndSettle();
          expect(
            scroll.offset,
            closeTo(parked, 1.0),
            reason:
                '$key is not a navigation key and must not move a reader '
                'who is mid-archive',
          );
        }
      },
    );

    testWidgets(
      'a navigation key that lands on the oldest loaded row asks for the page '
      'above it',
      (tester) async {
        if (_skipWithoutNative()) return;
        var calls = 0;
        await tester.pumpWidget(
          _wrap(_view(model: _loadedModel(), onLoadMore: () => calls++)),
        );
        await tester.pumpAndSettle();
        expect(calls, 0);

        await tester.sendKeyEvent(LogicalKeyboardKey.home);
        await tester.pumpAndSettle();
        expect(calls, 1);

        // Moving back toward the live bottom asks for nothing.
        await tester.sendKeyEvent(LogicalKeyboardKey.end);
        await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
        await tester.pumpAndSettle();
        expect(calls, 1);
      },
    );

    testWidgets(
      'the failure banner shows model.failure and retry calls onLoadMore',
      (tester) async {
        if (_skipWithoutNative()) return;
        final m = TerminalHistoryModel()
          ..applyBoundary(_boundary(nextRowId: 1000));
        m.markRequested('r1');
        m.noteRequestFailed('The agent did not answer.');
        var calls = 0;

        await tester.pumpWidget(
          _wrap(_view(model: m, onLoadMore: () => calls++)),
        );
        await tester.pump();

        expect(find.text('The agent did not answer.'), findsOneWidget);
        expect(
          tester.widget<AbInlineBanner>(find.byType(AbInlineBanner)).color,
          kDefaultPalette.warning,
        );

        final before = calls;
        await tester.tap(find.byTooltip('Retry'));
        await tester.pump();
        expect(calls, before + 1);
      },
    );

    testWidgets(
      'a navigation key fetches the first page from the empty state',
      (tester) async {
        if (_skipWithoutNative()) return;
        // The empty state renders no terminal, so the keyboard is the one
        // affordance that still reaches the reader there. It has to answer:
        // a key that does nothing is indistinguishable from a reader that has
        // hung.
        final m = TerminalHistoryModel()
          ..applyBoundary(_boundary(nextRowId: 1000));
        var calls = 0;

        await tester.pumpWidget(
          _wrap(_view(model: m, onLoadMore: () => calls++)),
        );
        await tester.pump();
        expect(find.byType(GhosttyTerminalView), findsNothing);
        expect(calls, 1, reason: 'the opening request, fired on mount');

        await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
        await tester.pump();
        expect(calls, 2);

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump();
        expect(calls, 3);

        // Toward the live bottom there is nothing to fetch, empty state or
        // not.
        await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
        await tester.sendKeyEvent(LogicalKeyboardKey.end);
        await tester.pump();
        expect(calls, 3);
      },
    );

    testWidgets(
      'swapping while parked mid-archive opens the new one at its live bottom',
      (tester) async {
        if (_skipWithoutNative()) return;
        // The swap tests above all pass through a model whose rows were
        // dropped, which zeroes the engine on the way and hides whether the
        // reader's place was carried across. This hands one loaded archive
        // straight to another while the reader is parked well up in the first.
        final m1 = _loadedModel();

        await tester.pumpWidget(_wrap(_view(model: m1)));
        await tester.pumpAndSettle();

        final scroll = _mountedTerminal(tester).scrollController!;
        scroll.jumpTo(scroll.position.maxScrollExtent / 2);
        await tester.pump();
        final parked = scroll.offset;
        expect(parked, greaterThan(0));

        await tester.pumpWidget(
          _wrap(_view(model: _loadedModel(nextRowId: 500))),
        );
        for (var i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        await tester.pumpAndSettle();

        final after = _mountedTerminal(tester);
        final text = after.controller.plainText;
        expect(text, contains('row 499'));
        expect(text, isNot(contains('row 999')));
        expect(
          after.scrollController!.offset,
          closeTo(0, 1.0),
          reason:
              'the reader was $parked pixels up in a DIFFERENT terminal; '
              'that distance addresses nothing in this one',
        );
      },
    );

    testWidgets(
      'swapping to an archive whose row ids match the old one still re-ingests '
      'it',
      (tester) async {
        if (_skipWithoutNative()) return;
        // Two terminals in one run both archive from their own rowId 0, so the
        // (first, last, count) signature the rebuild guard compares is not an
        // identity -- it can collide across terminals while every row differs.
        // The guard only describes whether MORE of the SAME archive arrived.
        TerminalHistoryModel archive(String label) {
          final m = TerminalHistoryModel()
            ..applyBoundary(_boundary(nextRowId: 1000));
          m.markRequested('seed');
          m.applyPage(
            _page(
              requestId: 'seed',
              rows: List<TerminalHistoryRow>.generate(
                20,
                (i) =>
                    _row(rowId: 980 + i, spans: [_span('$label ${980 + i}')]),
              ),
            ),
          );
          return m;
        }

        await tester.pumpWidget(_wrap(_view(model: archive('alpha'))));
        await tester.pumpAndSettle();
        expect(
          _mountedTerminal(tester).controller.plainText,
          contains('alpha'),
        );

        await tester.pumpWidget(_wrap(_view(model: archive('bravo'))));
        await tester.pumpAndSettle();

        final text = _mountedTerminal(tester).controller.plainText;
        expect(text, contains('bravo'));
        expect(
          text,
          isNot(contains('alpha')),
          reason:
              'the reader is showing the terminal it was swapped away '
              'from, under a name that belongs to the new one',
        );
      },
    );

    testWidgets(
      'a refused run withdraws Retry instead of offering a tap that sends '
      'nothing',
      (tester) async {
        if (_skipWithoutNative()) return;
        // HISTORY_DISABLED: the agent has answered for the whole run, so
        // onLoadMore would refuse itself and send nothing. A live-looking
        // button that does that reads as a broken reader.
        final m = TerminalHistoryModel()
          ..applyBoundary(_boundary(nextRowId: 1000));
        m.markRequested('r1');
        m.noteHistoryUnavailable('Scrollback is disabled for this run.');
        expect(m.refused, isTrue);
        expect(m.canLoadMore, isFalse);
        var calls = 0;

        await tester.pumpWidget(
          _wrap(_view(model: m, onLoadMore: () => calls++)),
        );
        await tester.pump();

        expect(
          find.text('Scrollback is disabled for this run.'),
          findsOneWidget,
        );
        final retry = find.descendant(
          of: find.byType(AbInlineBanner),
          matching: find.byType(AbIconButton),
        );
        expect(tester.widget<AbIconButton>(retry).onTap, isNull);
        expect(
          tester.widget<AbInlineBanner>(find.byType(AbInlineBanner)).color,
          kDefaultPalette.textMuted,
          reason:
              'warning yellow is the tone of a request that went wrong; '
              'this is the answer the run has settled on',
        );

        await tester.tap(retry, warnIfMissed: false);
        await tester.pump();
        expect(calls, 0);
      },
    );

    testWidgets('a disabled archive with no retained rows withdraws Retry', (
      tester,
    ) async {
      if (_skipWithoutNative()) return;
      // Disabled recording can still serve retained rows. Only an empty
      // boundary makes retry pointless without an outright refusal.
      final m = TerminalHistoryModel()
        ..applyBoundary(_boundary(nextRowId: 1000));
      m.markRequested('r1');
      m.noteRequestFailed('The agent did not answer.');
      m.applyBoundary(
        _boundary(firstRowId: 1000, nextRowId: 1000, status: 'disabled'),
      );
      expect(m.canLoadMore, isFalse);
      var calls = 0;

      await tester.pumpWidget(
        _wrap(_view(model: m, onLoadMore: () => calls++)),
      );
      await tester.pump();

      final retry = find.descendant(
        of: find.byType(AbInlineBanner),
        matching: find.byType(AbIconButton),
      );
      expect(tester.widget<AbIconButton>(retry).onTap, isNull);
      expect(find.byTooltip('Retry'), findsNothing);
      expect(
        find.byTooltip('Scrollback is unavailable for this run'),
        findsOneWidget,
      );
      expect(
        tester.widget<AbInlineBanner>(find.byType(AbInlineBanner)).color,
        kDefaultPalette.textMuted,
        reason:
            'warning yellow asks the reader to act on something they '
            'cannot act on',
      );

      await tester.tap(retry, warnIfMissed: false);
      await tester.pump();
      expect(calls, 0);
    });

    testWidgets(
      'a retry already in flight disables the control without calling the run '
      'unavailable',
      (tester) async {
        if (_skipWithoutNative()) return;
        // What a tapped Retry leaves behind: the banner still carries the
        // failure it was raised for, and the request now in flight shuts
        // `canLoadMore`. The control has to close, but the run has not
        // settled -- telling the reader their scrollback is unavailable while
        // it is being fetched is the one wrong answer available here.
        final m = TerminalHistoryModel()
          ..applyBoundary(_boundary(nextRowId: 1000));
        m.markRequested('r1');
        m.noteRequestFailed('The agent did not answer.');
        m.markRequested('r2');
        expect(m.loading, isTrue);
        expect(m.canLoadMore, isFalse);

        await tester.pumpWidget(_wrap(_view(model: m)));
        await tester.pump();

        final retry = find.descendant(
          of: find.byType(AbInlineBanner),
          matching: find.byType(AbIconButton),
        );
        expect(tester.widget<AbIconButton>(retry).onTap, isNull);
        expect(
          find.byTooltip('Scrollback is unavailable for this run'),
          findsNothing,
        );
        expect(find.byTooltip('Retrying…'), findsOneWidget);
        expect(
          tester.widget<AbInlineBanner>(find.byType(AbInlineBanner)).color,
          kDefaultPalette.warning,
          reason: 'the failure is still the unresolved thing on screen',
        );
      },
    );

    testWidgets(
      'withdrawing Retry leaves the pane under the banner exactly the size a '
      'retryable failure gives it',
      (tester) async {
        if (_skipWithoutNative()) return;
        // The banner is a sibling of the Expanded that holds the terminal, so
        // anything that changes its height resizes the reader's engine. The
        // refused state must disable the control in place, never drop it.
        Size paneUnder() => tester.getSize(find.byType(GhosttyTerminalView));

        final retryable = _loadedModel(count: 20);
        retryable.markRequested('r2');
        retryable.noteRequestFailed('The agent did not answer.');
        await tester.pumpWidget(_wrap(_view(model: retryable)));
        await tester.pumpAndSettle();
        final withRetry = paneUnder();

        final refused = _loadedModel(count: 20);
        refused.noteHistoryUnavailable('Scrollback is disabled for this run.');
        await tester.pumpWidget(_wrap(_view(model: refused)));
        await tester.pumpAndSettle();

        expect(paneUnder(), withRetry);
      },
    );

    testWidgets('swapping the model re-subscribes and re-renders', (
      tester,
    ) async {
      if (_skipWithoutNative()) return;
      final m1 = _SpyHistoryModel()..applyBoundary(_boundary(nextRowId: 1000));
      m1.markRequested('r1');
      m1.applyPage(_page(requestId: 'r1', rows: _rowsBelow(1000, count: 5)));

      final m2 = _SpyHistoryModel()..applyBoundary(_boundary(nextRowId: 500));
      m2.markRequested('r1');
      m2.applyPage(
        _page(
          requestId: 'r1',
          rows: _rowsBelow(500, count: 5),
          history: _boundary(nextRowId: 500),
        ),
      );

      await tester.pumpWidget(_wrap(_view(model: m1)));
      await tester.pumpAndSettle();
      expect(m1.listening, isTrue);
      expect(m2.listening, isFalse);
      expect(
        _mountedTerminal(tester).controller.plainText,
        contains('row 999'),
      );

      await tester.pumpWidget(_wrap(_view(model: m2)));
      await tester.pumpAndSettle();

      // The listener counts are the assertion, not the rendered output: the
      // widget always renders `widget.model`, so a leaked subscription to m1
      // would rebuild the engine from m2's rows and look identical.
      expect(m1.listening, isFalse);
      expect(m1.addCount, 1);
      expect(m1.removeCount, 1);
      expect(m2.listening, isTrue);
      expect(m2.addCount, 1);
      expect(m2.removeCount, 0);

      final text = _mountedTerminal(tester).controller.plainText;
      expect(text, contains('row 499'));
      expect(text, isNot(contains('row 999')));
    });

    testWidgets('dispose removes the listener it added to the model', (
      tester,
    ) async {
      if (_skipWithoutNative()) return;
      final m = _SpyHistoryModel()
        ..applyBoundary(_boundary(status: 'disabled'));

      await tester.pumpWidget(_wrap(_view(model: m)));
      await tester.pump();
      expect(m.addCount, 1);
      expect(m.removeCount, 0);

      await tester.pumpWidget(_wrap(const SizedBox.shrink()));
      await tester.pump();

      expect(m.removeCount, 1);
      expect(m.listening, isFalse);
    });

    testWidgets(
      'dispose releases its own engine controller and scroll controller',
      (tester) async {
        if (_skipWithoutNative()) return;
        await tester.pumpWidget(_wrap(_view(model: _loadedModel(count: 5))));
        await tester.pumpAndSettle();

        final view = _mountedTerminal(tester);
        final controller = view.controller;
        final scroll = view.scrollController!;

        await tester.pumpWidget(_wrap(const SizedBox.shrink()));
        await tester.pump();

        expect(() => controller.addListener(() {}), throwsFlutterError);
        expect(() => scroll.addListener(() {}), throwsFlutterError);
      },
    );
  });
}
