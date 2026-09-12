import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'ab_message.dart';

/// Hard bounds for one terminal's window onto its persistent archive.
const int kTerminalHistoryMaxRows = 2000;
const int kTerminalHistoryMaxBytes = 16 * 1024 * 1024;

/// One frame-mode terminal's paged scrollback: the rows that left the live
/// screen, which in frame mode the engine no longer keeps.
///
/// Pure state. It never touches the wire -- `TerminalService` owns sending
/// `terminal:history:request` and feeds the replies back in -- so the paging
/// contract can be tested without a transport.
///
/// A [ChangeNotifier] rather than a field on `TerminalState`, for the reason
/// `TerminalTab.replaceEpoch` is one: this is updated from the frame path, up
/// to `TERMINAL_FRAME_INTERVAL_MS` times a second, and routing that through
/// `TerminalService._setState` would rebuild the whole workspace per frame.
/// [applyBoundary] is therefore silent unless something a reader can SEE
/// changed -- `nextRowId` alone moves on almost every frame of a busy
/// terminal and means nothing to anyone who is not paging.
///
/// Deliberately never disposed, for the reason `TerminalTab.replaceEpoch` is
/// not (see `TerminalService.deleteTerminal`): it holds no native resource and
/// becomes garbage with the tab that holds it, while `addListener` on a
/// disposed notifier THROWS where `removeListener` is allowed -- so disposing
/// it would turn a widget still holding a removed tab from a no-op into a
/// fault, and buy nothing back.
class TerminalHistoryModel extends ChangeNotifier {
  TerminalHistoryModel({
    this.maxRows = kTerminalHistoryMaxRows,
    this.maxBytes = kTerminalHistoryMaxBytes,
  });

  final int maxRows;
  final int maxBytes;
  int _bytes = 0;
  int get cachedBytes => _bytes;

  static int _rowBytes(TerminalHistoryRow row) =>
      128 +
      row.spans.fold<int>(
        0,
        (bytes, span) =>
            bytes +
            128 +
            2 * (span.text.length + span.sgr.length + (span.uri?.length ?? 0)),
      );

  TerminalHistoryBoundary? _boundary;
  final List<TerminalHistoryRow> _rows = <TerminalHistoryRow>[];
  String? _outstandingRequestId;
  bool _atOldest = false;
  String? _failure;
  bool _refused = false;

  /// What the agent last said about this run's archive. Null until the first
  /// frame carries one -- every `terminal:frame` and every
  /// `terminal:history:page` restates it.
  TerminalHistoryBoundary? get boundary => _boundary;

  /// Loaded rows, oldest first. Contiguous by construction: paging only ever
  /// walks backwards from [cursor], so there is never a hole in the middle.
  List<TerminalHistoryRow> get rows => UnmodifiableListView(_rows);

  /// Whether a request is outstanding.
  bool get loading => _outstandingRequestId != null;

  /// Whether the oldest row this run still retains is loaded.
  bool get atOldest => _atOldest;

  /// Why scrollback could not be shown, or null.
  String? get failure => _failure;

  /// Whether the agent sent `HISTORY_DISABLED` for this RUN.
  ///
  /// A latent path: the code is in the wire enum (`bridge/src/protocol.ts`)
  /// and nothing in `bridge/src` emits it. A run whose archive is off is
  /// reported on the boundary instead (`status: "disabled"`, which
  /// [recording] reads), so a reader gates on [canLoadMore] -- which both
  /// shapes close -- and never on this alone.
  ///
  /// Scoped to the run and cleared only by [reset] -- a fresh run archives
  /// afresh.
  bool get refused => _refused;

  /// Whether the agent is archiving rows for this run at all. An unrecognized
  /// status is a newer agent and must read as NOT recording -- promising
  /// scrollback that never arrives is worse than admitting there is none.
  bool get recording => _boundary?.status == 'recording';

  /// Whether this run has archived anything, loaded or not.
  bool get hasHistory {
    final b = _boundary;
    return b != null && b.nextRowId > b.firstRowId;
  }

  /// Whether [cursor] can usefully be asked for another page.
  ///
  /// The gate `TerminalService.requestTerminalHistoryPage` checks before it
  /// sends anything, and so the only sound one for a reader's retry control:
  /// anything narrower -- [refused] alone, say, which a run reported off on
  /// the boundary never sets -- leaves a live control whose tap is dropped.
  bool get canLoadMore =>
      _boundary != null &&
      (recording || _boundary?.status == 'disabled') &&
      hasHistory &&
      !_refused &&
      !_atOldest &&
      !loading;

  /// The exclusive `beforeRowId` the next request must carry.
  ///
  /// Derived rather than stored, because it is exactly "the oldest row already
  /// held" -- the bridge answers `rowId < beforeRowId` -- and a stored copy
  /// could disagree with the list after an expiry reset.
  int? get cursor {
    final b = _boundary;
    if (b == null) return null;
    return _rows.isEmpty ? b.nextRowId : _rows.first.rowId;
  }

  /// The archive boundary carried by every frame.
  void applyBoundary(TerminalHistoryBoundary next) {
    final previous = _boundary;
    _boundary = next;
    if (previous == null) {
      notifyListeners();
      return;
    }
    // A new epoch is the run's archive being emptied and started over (an
    // explicit history clear), so every loaded row names a row that no longer
    // exists and the cursor derived from it would page into nothing.
    if (previous.epoch != next.epoch) {
      _discardRows();
      notifyListeners();
      return;
    }
    final visiblyChanged =
        previous.status != next.status ||
        (previous.nextRowId > previous.firstRowId) !=
            (next.nextRowId > next.firstRowId);
    if (visiblyChanged) notifyListeners();
  }

  /// Records that [requestId] is in flight. Returns false when one already is
  /// -- the caller must not send, because a second page answered against the
  /// same cursor would be inserted twice.
  bool markRequested(String requestId) {
    if (_outstandingRequestId != null) return false;
    _outstandingRequestId = requestId;
    notifyListeners();
    return true;
  }

  void cancelRequest() {
    if (_outstandingRequestId == null) return;
    _outstandingRequestId = null;
    notifyListeners();
  }

  /// One answered page. Reports whether it was the answer this model was
  /// waiting for: a caller holding bookkeeping for the request -- the bound it
  /// armed -- may retire it only on true, or a late loser would retire the
  /// bound belonging to the request that IS outstanding.
  bool applyPage(TerminalHistoryPageMessage page) {
    // Correlated, not merely addressed: a page fans out to nobody else, but a
    // retried request and a late answer to the one it replaced both name this
    // terminal, and inserting the loser would duplicate rows the winner
    // already placed.
    if (page.requestId != _outstandingRequestId) return false;
    _outstandingRequestId = null;
    final previous = _boundary;
    _boundary = page.history;
    _failure = null;
    // `expired` is the agent's verdict; the epoch is the fact, and it is the
    // fact [applyBoundary] already refuses to splice across. Rows counted in
    // one epoch and rows counted in another share a row-id space only by
    // coincidence, so merging them would derive the next cursor from two
    // archives at once.
    if (page.expired ||
        (previous != null && previous.epoch != page.history.epoch)) {
      // Retention passed the cursor, or the archive was emptied and started
      // over. Everything held is addressed by row ids the agent no longer
      // serves, so paging restarts from the boundary it just sent.
      _discardRows();
      notifyListeners();
      return true;
    }
    // Strictly older than everything held: the cursor is exclusive and the
    // bridge orders by rowId, so this only ever drops a duplicate of a page
    // this model already placed.
    final oldestHeld = _rows.isEmpty ? null : _rows.first.rowId;
    final fresh = oldestHeld == null
        ? page.rows
        : page.rows.where((r) => r.rowId < oldestHeld).toList(growable: false);
    if (fresh.isNotEmpty) {
      _rows.insertAll(0, fresh);
      _bytes += fresh.fold<int>(0, (bytes, row) => bytes + _rowBytes(row));
      // Older-page navigation advances through the archive in a bounded window.
      // Stable row IDs let the view keep its anchor while newer rows leave it.
      while (_rows.isNotEmpty &&
          (_rows.length > maxRows || _bytes > maxBytes)) {
        _bytes -= _rowBytes(_rows.removeLast());
      }
    }
    // Two ways to be at the top, and the second is the one that matters: an
    // empty page proves it, but so does a full page whose oldest row IS the
    // first row retained -- and detecting that here saves one round trip that
    // could only ever come back empty.
    _atOldest =
        fresh.isEmpty ||
        (_rows.isNotEmpty && _rows.first.rowId <= page.history.firstRowId);
    notifyListeners();
    return true;
  }

  /// One request's bound expired.
  ///
  /// [requestId] correlates the write, on the same rule [applyPage] follows: a
  /// bound belongs to ONE request, and by the time it expires this model may
  /// have moved past that request -- a retry replaced it, or [applyBoundary]
  /// abandoned it outright -- so the verdict would describe nothing the reader
  /// is waiting for. Omitting it writes against whatever is in flight, for a
  /// caller with no request to name.
  ///
  /// Paging stays OPEN: one unanswered request says nothing about the next
  /// one, and the banner this fills invites a retry. A run the agent refuses
  /// outright is [noteHistoryUnavailable] instead.
  /// Reports whether the failure was actually recorded.
  bool noteRequestFailed(String message, {String? requestId}) {
    if (requestId != null && requestId != _outstandingRequestId) return false;
    _outstandingRequestId = null;
    _failure = message;
    notifyListeners();
    return true;
  }

  /// The agent refuses this run's archive outright (`HISTORY_DISABLED`).
  ///
  /// A latent path: the code is in the wire enum (`bridge/src/protocol.ts`)
  /// and nothing in `bridge/src` emits it. What a bridge with no archive
  /// sends instead is a boundary carrying `status: "disabled"`, which closes
  /// [canLoadMore] through [recording] without this being called.
  ///
  /// Uncorrelated by design -- addressed at the RUN, so it holds whatever
  /// request is in flight -- and, unlike [noteRequestFailed], it closes
  /// [canLoadMore]. A refused run asked again on the next scroll tick is
  /// refused again, and the bound that second request arms outlives the
  /// refusal: it would overwrite the sentence that explains the problem with
  /// a generic timeout.
  void noteHistoryUnavailable(String message) {
    _refused = true;
    _outstandingRequestId = null;
    _failure = message;
    notifyListeners();
  }

  /// Drops every loaded row, keeping the boundary. Used when the rows held
  /// name ids the agent no longer serves.
  ///
  /// The outstanding request goes with them: its answer is addressed by the
  /// very ids being dropped. Nothing is reported for it -- the client gave up
  /// on the request, and a failure banner would blame the agent for that.
  void _discardRows() {
    _rows.clear();
    _bytes = 0;
    _atOldest = false;
    _outstandingRequestId = null;
  }

  /// Forgets everything, boundary included -- a fresh PTY under the same id
  /// archives into a run this model has never seen.
  void reset() {
    _discardRows();
    _boundary = null;
    _failure = null;
    _refused = false;
    notifyListeners();
  }
}
