import 'dart:async';

import 'package:uuid/uuid.dart';

import '../models/session_entry.dart';
import '../models/ab_message.dart';
import '../project/project_session.dart';
import '../storage/cached_sessions_store.dart';
import 'pending_reply.dart';

/// Reply timeout for any pending `session:*` request. The agent should answer
/// within milliseconds locally and ≤1 RTT over the relay; 15s is comfortably
/// past either case while still bounding the UI hang if a frame is dropped.
const _kPendingReplyTimeout = Duration(seconds: 15);

class SessionsState {
  final String projectId;
  final List<SessionEntry> sessions;
  final bool loading;
  final String? error;

  const SessionsState({
    required this.projectId,
    this.sessions = const [],
    this.loading = false,
    this.error,
  });

  SessionsState copyWith({
    List<SessionEntry>? sessions,
    bool? loading,
    String? error,
    bool clearError = false,
  }) => SessionsState(
    projectId: projectId,
    sessions: sessions ?? this.sessions,
    loading: loading ?? this.loading,
    error: clearError ? null : (error ?? this.error),
  );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! SessionsState) return false;
    if (projectId != other.projectId) return false;
    if (loading != other.loading || error != other.error) return false;
    if (sessions.length != other.sessions.length) return false;
    for (var i = 0; i < sessions.length; i++) {
      if (sessions[i] != other.sessions[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode =>
      Object.hash(projectId, loading, error, Object.hashAll(sessions));
}

class SessionsService {
  final ProjectSession session;
  final CachedSessionsStore cache;

  StreamSubscription<Map<String, dynamic>>? _statusSub;
  final _stateController = StreamController<SessionsState>.broadcast();
  SessionsState _state;
  bool _disposed = false;

  final Map<String, PendingReply<List<SessionEntry>>> _pendingList = {};
  final Map<String, PendingReply<SessionEntry?>> _pendingMutations = {};
  final Map<String, PendingReply<bool>> _pendingDeletes = {};

  Stream<SessionsState> get stateStream => _stateController.stream;
  SessionsState get currentState => _state;
  String get projectId => session.projectId;

  SessionsService.fromSession(this.session, {required this.cache})
    : _state = SessionsState(projectId: session.projectId, sessions: const []) {
    _statusSub = session.statusStream.listen(_onStatusJson);
    final cached = cache.get(session.projectId);
    if (cached.isNotEmpty) {
      _setState(_state.copyWith(sessions: cached));
    }
  }

  void _writeThrough(List<SessionEntry> sessions) {
    cache.put(session.projectId, sessions);
  }

  void _setState(SessionsState s) {
    if (_disposed) return;
    if (s == _state) return;
    _state = s;
    if (!_stateController.isClosed) _stateController.add(s);
  }

  // --- Message dispatch ---

  void _onStatusJson(Map<String, dynamic> json) {
    final type = json['type'] as String?;
    switch (type) {
      case 'session:list:result':
        _handleListResult(json);
        break;
      case 'session:result':
        _handleResult(json);
        break;
      case 'session:updated':
        _handleUpdated(json);
        break;
    }
  }

  void _handleListResult(Map<String, dynamic> j) {
    final requestId = j['requestId'] as String?;
    final sessions = _parseSessions(j['sessions']);
    _setState(
      _state.copyWith(sessions: sessions, loading: false, clearError: true),
    );
    _writeThrough(sessions);

    if (requestId != null) {
      _pendingList.remove(requestId)?.complete(sessions);
    }
  }

  void _handleResult(Map<String, dynamic> j) {
    final requestId = j['requestId'] as String?;
    if (requestId == null) return;

    final ok = j['ok'] as bool? ?? false;
    final error = j['error'] as String?;
    final sessionJson = j['session'];
    final entry = sessionJson is Map<String, dynamic>
        ? SessionEntry.fromJson(sessionJson)
        : null;

    if (!ok && error != null) {
      _setState(_state.copyWith(error: error));
    }

    // Delete uses a bool completer; everything else uses a session-entry completer.
    final deletePending = _pendingDeletes.remove(requestId);
    if (deletePending != null) {
      deletePending.complete(ok);
      return;
    }

    _pendingMutations.remove(requestId)?.complete(ok ? entry : null);
  }

  void _handleUpdated(Map<String, dynamic> j) {
    final sessions = _parseSessions(j['sessions']);
    // Each running-session mutation fires `session:updated` twice on the agent
    // (sync `changed()` and async PTY-exit `noteExited`). The two frames are
    // structurally identical for non-`running` fields; skip the second so
    // every Riverpod consumer doesn't rebuild for a no-op.
    if (_listsEqual(sessions, _state.sessions) && _state.error == null) return;
    _setState(_state.copyWith(sessions: sessions, clearError: true));
    _writeThrough(sessions);
  }

  List<SessionEntry> _parseSessions(Object? raw) =>
      SessionEntry.listFromJson(raw is List ? raw : null);

  bool _listsEqual(List<SessionEntry> a, List<SessionEntry> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  String _newRequestId() => const Uuid().v4();

  PendingReply<T> _newPending<T>(void Function() onTimeout) => PendingReply<T>(
    timeout: _kPendingReplyTimeout,
    onTimeout: onTimeout,
    timeoutError: () => TimeoutException('session reply timed out'),
  );

  Future<void> _send(Map<String, dynamic> msg) async {
    await session.send(msg);
  }

  // --- Public requests ---

  Future<List<SessionEntry>> requestList({bool includeArchived = false}) {
    final requestId = _newRequestId();
    final pending = _newPending<List<SessionEntry>>(
      () => _pendingList.remove(requestId),
    );
    _pendingList[requestId] = pending;
    _setState(_state.copyWith(loading: true, clearError: true));
    unawaited(
      _send(
        createAbMessage('session:list', {
          'requestId': requestId,
          if (includeArchived) 'includeArchived': true,
        }),
      ),
    );
    return pending.future;
  }

  Future<SessionEntry?> create({
    String? name,
    String? tool,
    String? command,
    String? args,
    String? mode,
  }) {
    return _mutate('session:create', {
      'name': ?name,
      'tool': ?tool,
      'command': ?command,
      'args': ?args,
      'mode': ?mode,
    });
  }

  Future<SessionEntry?> start(String id, {String? initialPrompt}) {
    return _mutate('session:start', {
      'sessionId': id,
      'initialPrompt': ?initialPrompt,
    });
  }

  Future<SessionEntry?> stopSession(String id) {
    return _mutate('session:stop', {'sessionId': id});
  }

  Future<SessionEntry?> rename(String id, String name) {
    return _mutate('session:rename', {'sessionId': id, 'name': name});
  }

  Future<SessionEntry?> archive(String id) {
    return _mutate('session:archive', {'sessionId': id});
  }

  Future<SessionEntry?> unarchive(String id) {
    return _mutate('session:unarchive', {'sessionId': id});
  }

  Future<bool> delete(String id) {
    final requestId = _newRequestId();
    final pending = _newPending<bool>(() => _pendingDeletes.remove(requestId));
    _pendingDeletes[requestId] = pending;
    unawaited(
      _send(
        createAbMessage('session:delete', {
          'requestId': requestId,
          'sessionId': id,
        }),
      ),
    );
    return pending.future;
  }

  void focus(String id) {
    // Fire-and-forget; no requestId, no reply.
    _send(createAbMessage('session:focus', {'sessionId': id}));
  }

  Future<SessionEntry?> _mutate(String type, Map<String, dynamic> fields) {
    final requestId = _newRequestId();
    final pending = _newPending<SessionEntry?>(
      () => _pendingMutations.remove(requestId),
    );
    _pendingMutations[requestId] = pending;
    unawaited(
      _send(createAbMessage(type, {'requestId': requestId, ...fields})),
    );
    return pending.future;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _failPending(StateError('SessionsService disposed'));
    await _statusSub?.cancel();
    _statusSub = null;
    await _stateController.close();
  }

  void _failPending(Object error) {
    for (final p in _pendingList.values) {
      p.fail(error);
    }
    _pendingList.clear();
    for (final p in _pendingMutations.values) {
      p.fail(error);
    }
    _pendingMutations.clear();
    for (final p in _pendingDeletes.values) {
      p.fail(error);
    }
    _pendingDeletes.clear();
  }
}
