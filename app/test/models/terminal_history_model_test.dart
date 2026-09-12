// The paging contract for a frame-mode terminal's archived scrollback, tested
// without a transport: `TerminalHistoryModel` never sends anything, so every
// case here is "the agent said X, what does the pane now hold".
//
// The cursor is the whole of it. It is DERIVED from the oldest loaded row
// rather than stored, and the bridge answers `rowId < beforeRowId` — so a page
// inserted in the wrong place, or twice, silently changes what the next
// request asks for.
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/models/ab_message.dart';
import 'package:antgrid/models/terminal_history_model.dart';

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

TerminalHistoryRow _row(int rowId) => TerminalHistoryRow(
  rowId: rowId,
  cols: 80,
  wrapped: false,
  spans: <TerminalHistorySpan>[
    TerminalHistorySpan(text: 'row $rowId', cells: 8, sgr: '\x1b[0m'),
  ],
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
    // Mirrors the bridge: the reply's own cursor is the oldest row it carries,
    // or the clamped request cursor when it carries none.
    beforeRowId:
        beforeRowId ?? (rows.isEmpty ? boundary.firstRowId : rows.first.rowId),
    rows: rows,
  );
}

/// One full page's worth, ending just below [exclusiveEnd].
List<TerminalHistoryRow> _rowsBelow(int exclusiveEnd, {int count = 200}) =>
    List<TerminalHistoryRow>.generate(
      count,
      (i) => _row(exclusiveEnd - count + i),
    );

void main() {
  test(
    'reopening replaces a pending first page only when its boundary is stale',
    () {
      final m = TerminalHistoryModel()..applyBoundary(_boundary());
      m.markRequested('first');
      m.prepareLatestWindow();
      expect(m.loading, isTrue);
      m.applyBoundary(_boundary(nextRowId: 1200));
      m.prepareLatestWindow();
      expect(m.loading, isFalse);
      expect(m.cursor, 1200);
      m.markRequested('latest');
      expect(
        m.applyPage(_page(requestId: 'first', rows: _rowsBelow(1000))),
        isFalse,
      );
      expect(m.loading, isTrue);
    },
  );

  test(
    'reopening refreshes a stale newest window and abandons old requests',
    () {
      final m = TerminalHistoryModel()..applyBoundary(_boundary());
      m.markRequested('seed');
      m.applyPage(_page(requestId: 'seed', rows: _rowsBelow(1000)));
      m.applyBoundary(_boundary(nextRowId: 1200));
      expect(m.cursor, 800, reason: 'live output leaves active reading alone');
      m.markRequested('older');
      m.prepareLatestWindow();
      expect(m.rows, isEmpty);
      expect(m.cursor, 1200);
      expect(m.canLoadMore, isTrue);
      m.markRequested('latest');
      expect(
        m.applyPage(_page(requestId: 'older', rows: _rowsBelow(800))),
        isFalse,
      );
      expect(m.noteRequestFailed('late timeout', requestId: 'older'), isFalse);
      m.applyPage(
        _page(
          requestId: 'latest',
          rows: _rowsBelow(1200),
          history: _boundary(nextRowId: 1200),
        ),
      );
      expect(m.rows.last.rowId, 1199);
      m.prepareLatestWindow();
      expect(m.rows, hasLength(200));
    },
  );

  test('reopening leaves an unavailable cached archive readable', () {
    final m = TerminalHistoryModel()..applyBoundary(_boundary());
    m.markRequested('seed');
    m.applyPage(_page(requestId: 'seed', rows: _rowsBelow(1000)));
    m.applyBoundary(_boundary(nextRowId: 1200));
    m.noteHistoryUnavailable('Unavailable');
    m.prepareLatestWindow();
    expect(m.rows, hasLength(200));
    expect(m.failure, 'Unavailable');
  });

  test('an empty model has nothing to ask for until a boundary arrives', () {
    final m = TerminalHistoryModel();
    expect(m.boundary, isNull);
    expect(m.cursor, isNull);
    expect(m.canLoadMore, isFalse);
    expect(m.recording, isFalse);
  });

  test('the first cursor is the boundary nextRowId, exclusive', () {
    final m = TerminalHistoryModel()..applyBoundary(_boundary(nextRowId: 1000));
    expect(m.cursor, 1000);
    expect(m.canLoadMore, isTrue);
  });

  test('a run archiving nothing is not worth a request', () {
    final m = TerminalHistoryModel()
      ..applyBoundary(_boundary(firstRowId: 40, nextRowId: 40));
    expect(m.hasHistory, isFalse);
    expect(m.canLoadMore, isFalse);
  });

  test(
    'disabled recording preserves readable history; an unknown status does not',
    () {
      final disabled = TerminalHistoryModel()
        ..applyBoundary(_boundary(status: 'disabled'));
      expect(disabled.recording, isFalse);
      expect(disabled.canLoadMore, isTrue);

      // A status this build does not know is a newer agent. Promising scrollback
      // that never arrives is worse than admitting there is none.
      final future = TerminalHistoryModel()
        ..applyBoundary(_boundary(status: 'compacting'));
      expect(future.recording, isFalse);
      expect(future.canLoadMore, isFalse);
    },
  );

  test('paging walks backwards, and the cursor follows the oldest row', () {
    final m = TerminalHistoryModel()..applyBoundary(_boundary(nextRowId: 1000));

    expect(m.markRequested('r1'), isTrue);
    expect(m.loading, isTrue);
    // A second request while one is outstanding would be answered against the
    // same cursor and insert the same rows twice.
    expect(m.markRequested('r2'), isFalse);

    m.applyPage(_page(requestId: 'r1', rows: _rowsBelow(1000)));
    expect(m.loading, isFalse);
    expect(m.rows, hasLength(200));
    expect(m.rows.first.rowId, 800);
    expect(m.rows.last.rowId, 999);
    expect(m.cursor, 800);
    expect(m.atOldest, isFalse);

    expect(m.markRequested('r2'), isTrue);
    m.applyPage(_page(requestId: 'r2', rows: _rowsBelow(800)));
    expect(m.rows, hasLength(400));
    expect(m.rows.first.rowId, 600);
    expect(m.rows.last.rowId, 999);
    expect(m.cursor, 600);
  });

  test('a page answering a request this model has moved past is dropped', () {
    final m = TerminalHistoryModel()..applyBoundary(_boundary(nextRowId: 1000));
    m.markRequested('r1');
    m.applyPage(_page(requestId: 'r1', rows: _rowsBelow(1000)));

    // The retried request's late loser. Its rows are real and correctly
    // ordered, which is exactly why nothing but the requestId can reject it.
    m.applyPage(_page(requestId: 'r1', rows: _rowsBelow(1000)));
    expect(m.rows, hasLength(200));
    expect(m.cursor, 800);
  });

  test('a page overlapping rows already held inserts only what is older', () {
    final m = TerminalHistoryModel()..applyBoundary(_boundary(nextRowId: 1000));
    m.markRequested('r1');
    m.applyPage(_page(requestId: 'r1', rows: _rowsBelow(1000)));

    m.markRequested('r2');
    m.applyPage(
      _page(requestId: 'r2', rows: _rowsBelow(900), beforeRowId: 700),
    );
    expect(m.rows.first.rowId, 700);
    expect(m.rows.last.rowId, 999);
    // 100 genuinely older rows, not 200 with a duplicated overlap.
    expect(m.rows, hasLength(300));
    expect(m.rows.map((r) => r.rowId).toSet(), hasLength(300));
  });

  test('an empty page means the top of the archive', () {
    final m = TerminalHistoryModel()..applyBoundary(_boundary(nextRowId: 1000));
    m.markRequested('r1');
    m.applyPage(_page(requestId: 'r1', rows: const <TerminalHistoryRow>[]));
    expect(m.atOldest, isTrue);
    expect(m.canLoadMore, isFalse);
  });

  test(
    'a full page reaching firstRowId means the top too, without a round trip '
    'that could only come back empty',
    () {
      final m = TerminalHistoryModel()
        ..applyBoundary(_boundary(firstRowId: 800, nextRowId: 1000));
      m.markRequested('r1');
      m.applyPage(
        _page(
          requestId: 'r1',
          rows: _rowsBelow(1000),
          history: _boundary(firstRowId: 800, nextRowId: 1000),
        ),
      );
      expect(m.rows, hasLength(200));
      expect(m.rows.first.rowId, 800);
      expect(m.atOldest, isTrue);
      expect(m.canLoadMore, isFalse);
    },
  );

  test('an expired cursor restarts paging from the boundary it carries', () {
    final m = TerminalHistoryModel()..applyBoundary(_boundary(nextRowId: 1000));
    m.markRequested('r1');
    m.applyPage(_page(requestId: 'r1', rows: _rowsBelow(1000)));
    expect(m.rows, hasLength(200));

    // Retention passed the cursor while the request was in flight. Every row
    // held is addressed by an id the agent no longer serves.
    m.markRequested('r2');
    m.applyPage(
      _page(
        requestId: 'r2',
        rows: const <TerminalHistoryRow>[],
        expired: true,
        history: _boundary(firstRowId: 1200, nextRowId: 1400),
      ),
    );
    expect(m.rows, isEmpty);
    expect(m.atOldest, isFalse);
    expect(m.cursor, 1400);
    expect(m.canLoadMore, isTrue);
  });

  test('a new epoch drops every loaded row', () {
    final m = TerminalHistoryModel()..applyBoundary(_boundary(nextRowId: 1000));
    m.markRequested('r1');
    m.applyPage(_page(requestId: 'r1', rows: _rowsBelow(1000)));

    // An explicit history clear: the archive is emptied and counted from zero,
    // so rowId 800 in the old epoch and rowId 800 in the new one are different
    // lines of output.
    m.applyBoundary(_boundary(epoch: 2, firstRowId: 0, nextRowId: 12));
    expect(m.rows, isEmpty);
    expect(m.cursor, 12);
  });

  test('a boundary that changes nothing a reader can see does not notify', () {
    final m = TerminalHistoryModel()..applyBoundary(_boundary(nextRowId: 1000));
    var notifications = 0;
    m.addListener(() => notifications++);

    // What a busy terminal does ~20x a second. Routing this through a rebuild
    // is the exact cost frame mode exists to avoid.
    for (var i = 1; i <= 40; i++) {
      m.applyBoundary(_boundary(nextRowId: 1000 + i));
    }
    expect(notifications, 0);

    // The archive going away IS visible, and must land.
    m.applyBoundary(_boundary(nextRowId: 1040, status: 'disabled'));
    expect(notifications, 1);
  });

  test('paging advances a strict bounded window through older history', () {
    final m = TerminalHistoryModel(maxRows: 400)
      ..applyBoundary(_boundary(nextRowId: 1000));
    for (final r in <String>['r1', 'r2']) {
      expect(m.canLoadMore, isTrue);
      m.markRequested(r);
      m.applyPage(_page(requestId: r, rows: _rowsBelow(m.cursor!)));
    }
    expect(m.rows, hasLength(400));
    expect(m.canLoadMore, isTrue);
    expect(m.rows.first.rowId, 600);
    expect(m.rows.last.rowId, 999);
    m.markRequested('r3');
    m.applyPage(_page(requestId: 'r3', rows: _rowsBelow(600)));
    expect(m.rows, hasLength(400));
    expect(m.rows.first.rowId, 400);
    expect(m.rows.last.rowId, 799);
    expect(m.cursor, 400);
  });

  test('a page crossing the row ceiling is trimmed immediately', () {
    final m = TerminalHistoryModel(maxRows: 250)..applyBoundary(_boundary());
    m.markRequested('r1');
    m.applyPage(_page(requestId: 'r1', rows: _rowsBelow(1000)));
    m.markRequested('r2');
    m.applyPage(_page(requestId: 'r2', rows: _rowsBelow(800)));
    expect(m.rows, hasLength(250));
    expect(m.rows.first.rowId, 600);
    expect(m.rows.last.rowId, 849);
  });

  test('the byte ceiling includes styles and hyperlink targets', () {
    final m = TerminalHistoryModel(maxBytes: 1000)..applyBoundary(_boundary());
    TerminalHistoryRow linked(int id) => TerminalHistoryRow(
      rowId: id,
      cols: 80,
      wrapped: false,
      spans: [
        TerminalHistorySpan(
          text: 'x',
          cells: 1,
          sgr: '\x1b[38;2;1;2;3m',
          uri: 'https://example.com/${'x' * 100}',
        ),
      ],
    );
    m.markRequested('r1');
    m.applyPage(_page(requestId: 'r1', rows: [linked(998), linked(999)]));
    expect(m.cachedBytes, lessThanOrEqualTo(1000));
    expect(m.rows, hasLength(1));
    expect(m.rows.single.rowId, 998);
    m.reset();
    expect(m.cachedBytes, 0);
  });

  test('canceling an attachment request preserves its loaded archive', () {
    final m = TerminalHistoryModel()..applyBoundary(_boundary());
    m.markRequested('r1');
    m.applyPage(_page(requestId: 'r1', rows: _rowsBelow(1000)));
    m.markRequested('r2');
    m.cancelRequest();
    expect(m.loading, isFalse);
    expect(m.rows, hasLength(200));
    expect(m.applyPage(_page(requestId: 'r2', rows: _rowsBelow(800))), isFalse);
  });

  test('a failed request clears loading and is cleared by the next page', () {
    final m = TerminalHistoryModel()..applyBoundary(_boundary(nextRowId: 1000));
    m.markRequested('r1');
    m.noteRequestFailed('The agent did not answer.');
    expect(m.loading, isFalse);
    expect(m.failure, 'The agent did not answer.');
    expect(m.canLoadMore, isTrue);

    m.markRequested('r2');
    m.applyPage(_page(requestId: 'r2', rows: _rowsBelow(1000)));
    expect(m.failure, isNull);
  });

  test('applyPage reports whether it was the answer being waited for', () {
    final m = TerminalHistoryModel()..applyBoundary(_boundary(nextRowId: 1000));
    m.markRequested('r1');

    // The verdict is what a caller holding a bound for the request keys on:
    // it is the only thing that can tell the winner from a late loser, both of
    // which arrive addressed to the same terminal and the same attachment.
    expect(
      m.applyPage(_page(requestId: 'stale', rows: _rowsBelow(1000))),
      isFalse,
    );
    expect(m.applyPage(_page(requestId: 'r1', rows: _rowsBelow(1000))), isTrue);
    expect(m.applyPage(_page(requestId: 'r1', rows: _rowsBelow(800))), isFalse);
  });

  test('a bound that expires after the model moved on writes nothing', () {
    final m = TerminalHistoryModel()..applyBoundary(_boundary(nextRowId: 1000));
    m.markRequested('r1');

    // An explicit history clear withdraws the request: its answer would be
    // addressed by row ids the agent no longer serves.
    m.applyBoundary(_boundary(epoch: 2, firstRowId: 0, nextRowId: 12));
    expect(m.loading, isFalse);

    expect(m.noteRequestFailed('timed out', requestId: 'r1'), isFalse);
    expect(m.failure, isNull);

    // The retry's OWN bound still lands, and so does a refusal addressed at
    // the run rather than at any one request.
    m.markRequested('r2');
    expect(m.noteRequestFailed('timed out', requestId: 'r2'), isTrue);
    expect(m.failure, 'timed out');
    expect(m.noteRequestFailed('archiving is off'), isTrue);
    expect(m.failure, 'archiving is off');
  });

  test('reset forgets the boundary as well as the rows', () {
    final m = TerminalHistoryModel()..applyBoundary(_boundary(nextRowId: 1000));
    m.markRequested('r1');
    m.applyPage(_page(requestId: 'r1', rows: _rowsBelow(1000)));

    // A respawn: the same terminal id, a run this model has never seen.
    m.reset();
    expect(m.rows, isEmpty);
    expect(m.boundary, isNull);
    expect(m.cursor, isNull);
    expect(m.canLoadMore, isFalse);
  });
}
