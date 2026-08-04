import 'dart:async';

import 'package:uuid/uuid.dart';

import '../analytics/events.dart';
import '../models/search_models.dart';
import '../models/ab_message.dart';
import '../project/project_session.dart';
import 'idle_action_guard.dart';

/// Per-project file search service.
///
/// Constructed at [ProjectSession] creation time. Subscribes to the session's
/// heavy stream in the constructor — `file:search-result` and
/// `file:search-done` arrive on the heavy tier. The service's lifetime is
/// bound to the session; calling [dispose] cancels the heavy subscription
/// and closes the state controller.
class SearchService {
  final ProjectSession session;
  final String checkoutId;

  StreamSubscription<Map<String, dynamic>>? _heavySub;
  bool _disposed = false;

  /// Idle-timeout for the in-flight search. A search that neither yields a
  /// result nor a `file:search-done` within this window has stranded (dropped
  /// send / session down): the reply that clears [SearchState.isSearching] is
  /// never coming. Not a wall-clock cap — a large repo search resets it on
  /// every result frame.
  final Duration searchIdleTimeout;
  IdleActionGuard? _searchGuard;

  final _stateController = StreamController<SearchState>.broadcast();
  SearchState _state = const SearchState();
  Map<String, int> _resultIndex = {};

  Stream<SearchState> get stateStream => _stateController.stream;
  SearchState get currentState => _state;

  String get projectId => session.projectId;

  SearchService.fromSession(
    this.session, {
    this.checkoutId = 'main',
    this.searchIdleTimeout = const Duration(seconds: 12),
  }) {
    _heavySub = session.checkoutHeavyStream(checkoutId).listen(_onHeavyJson);
  }

  void _setState(SearchState state) {
    if (_disposed) return;
    _state = state;
    _stateController.add(state);
  }

  void _onHeavyJson(Map<String, dynamic> json) {
    final abMsg = parseAbMessage(json);
    if (abMsg == null) return;
    if (abMsg is FileSearchResultMessage) {
      _handleSearchResult(abMsg);
    } else if (abMsg is FileSearchDoneMessage) {
      _handleSearchDone(abMsg);
    }
  }

  // --- Public methods ---

  void search(String query) {
    if (_disposed) return;
    if (query.isEmpty) {
      _cancelCurrent();
      _resultIndex = {};
      _setState(const SearchState());
      return;
    }

    session.analytics?.track(AnalyticsEvents.searchUsed);
    _cancelCurrent();
    _resultIndex = {};

    final requestId = const Uuid().v4();
    _setState(
      _state.copyWith(
        query: query,
        isSearching: true,
        currentRequestId: requestId,
        results: [],
        totalMatches: 0,
        totalFiles: 0,
        clearDuration: true,
        clearEngine: true,
        clearError: true,
      ),
    );

    session.sendForCheckout(checkoutId,
      createAbMessage('file:search', {
        'projectId': projectId,
        'query': query,
        'caseSensitive': _state.caseSensitive,
        'regex': _state.regex,
        'wholeWord': _state.wholeWord,
        'requestId': requestId,
      }),
    );

    // Tier-2 streaming action: bound by inactivity, not wall-clock (`timeout:
    // null` — a large search legitimately streams for a while). If neither a
    // result nor file:search-done lands within the idle window, settle the
    // spinner rather than strand it. Guarded on requestId so a superseding
    // search's timeout can't clear the newer one.
    final guard = _searchGuard = IdleActionGuard(searchIdleTimeout);
    unawaited(
      session.action(() => guard.done, timeout: null).catchError((_) {
        if (_disposed || _state.currentRequestId != requestId) return;
        _setState(
          _state.copyWith(
            isSearching: false,
            clearCurrentRequestId: true,
            error: 'Search stalled — no response from the agent',
          ),
        );
      }),
    );
  }

  void toggleCaseSensitive() {
    _setState(_state.copyWith(caseSensitive: !_state.caseSensitive));
    if (_state.query.isNotEmpty) search(_state.query);
  }

  void toggleRegex() {
    _setState(_state.copyWith(regex: !_state.regex));
    if (_state.query.isNotEmpty) search(_state.query);
  }

  void toggleWholeWord() {
    _setState(_state.copyWith(wholeWord: !_state.wholeWord));
    if (_state.query.isNotEmpty) search(_state.query);
  }

  // --- Message handlers ---

  void _handleSearchResult(FileSearchResultMessage msg) {
    if (msg.requestId != _state.currentRequestId) return;

    final resultsCopy = [..._state.results];

    for (final match in msg.matches) {
      final searchMatch = SearchMatch(
        line: match.line,
        column: match.column,
        lineContent: match.lineContent,
        contextBefore: match.contextBefore,
        contextAfter: match.contextAfter,
      );

      final existingIndex = _resultIndex[match.path];
      if (existingIndex != null) {
        resultsCopy[existingIndex] = resultsCopy[existingIndex].addMatches([
          searchMatch,
        ]);
      } else {
        _resultIndex[match.path] = resultsCopy.length;
        resultsCopy.add(
          SearchFileGroup(path: match.path, matches: [searchMatch]),
        );
      }
    }

    // Activity — the search is alive; reset the idle clock.
    _searchGuard?.poke();
    _setState(_state.copyWith(results: resultsCopy));
  }

  void _handleSearchDone(FileSearchDoneMessage msg) {
    if (msg.requestId != _state.currentRequestId) return;

    _searchGuard?.settle();
    _searchGuard = null;
    _setState(
      _state.copyWith(
        isSearching: false,
        totalMatches: msg.totalMatches,
        totalFiles: msg.totalFiles,
        duration: msg.duration,
        engine: msg.engine,
        error: msg.error,
        clearCurrentRequestId: true,
      ),
    );
  }

  void _cancelCurrent() {
    // Superseded / cleared — a clean end, not a strand.
    _searchGuard?.settle();
    _searchGuard = null;
    final requestId = _state.currentRequestId;
    if (requestId != null && _state.isSearching) {
      session.sendForCheckout(checkoutId,
        createAbMessage('file:search-cancel', {
          'projectId': projectId,
          'requestId': requestId,
        }),
      );
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _searchGuard?.settle();
    _searchGuard = null;
    await _heavySub?.cancel();
    _heavySub = null;
    await _stateController.close();
  }
}
