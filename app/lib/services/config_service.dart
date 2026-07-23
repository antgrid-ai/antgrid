import 'dart:async';

import '../models/ab_config.dart';
import '../models/ab_message.dart';
import '../project/project_session.dart';
import 'pending_reply.dart';

class DetectedTool {
  final String tool;
  final String path;
  const DetectedTool({required this.tool, required this.path});

  factory DetectedTool.fromJson(Map<String, dynamic> j) =>
      DetectedTool(tool: j['tool'] as String, path: j['path'] as String);
}

class ConfigState {
  final AbConfig? config;
  final bool loading;
  final String? rawOnError;
  final String? error;
  final List<DetectedTool> detectedTools;

  const ConfigState({
    this.config,
    this.loading = false,
    this.rawOnError,
    this.error,
    this.detectedTools = const [],
  });

  ConfigState copyWith({
    AbConfig? config,
    bool? loading,
    String? rawOnError,
    String? error,
    List<DetectedTool>? detectedTools,
    bool clearError = false,
  }) => ConfigState(
    config: config ?? this.config,
    loading: loading ?? this.loading,
    rawOnError: clearError ? null : (rawOnError ?? this.rawOnError),
    error: clearError ? null : (error ?? this.error),
    detectedTools: detectedTools ?? this.detectedTools,
  );
}

/// Per-project status-tier config service. Subscribes to
/// [ProjectSession.statusStream]; the wire types it consumes
/// (`config:read-result`, `config:write-result`, `config:detect-tools-result`,
/// `config:changed`) are all routed through the status tier.
class ConfigService {
  final ProjectSession session;

  /// Hard ceiling on every request/reply pair. A reply can be lost (silent
  /// transport drop pre-establish, agent gone mid-request), and without a
  /// timer the returned future — and the UI awaiting it — hangs forever.
  final Duration requestTimeout;

  StreamSubscription<Map<String, dynamic>>? _statusSub;
  final _stateController = StreamController<ConfigState>.broadcast();
  ConfigState _state = const ConfigState();
  bool _disposed = false;

  PendingReply<AbConfig?>? _read;
  PendingReply<List<String>?>? _write; // null on success, errors otherwise
  PendingReply<List<DetectedTool>>? _detect;

  Stream<ConfigState> get stateStream => _stateController.stream;
  ConfigState get currentState => _state;
  String get projectId => session.projectId;

  ConfigService.fromSession(
    this.session, {
    this.requestTimeout = const Duration(seconds: 15),
  }) {
    _statusSub = session.statusStream.listen(_onStatusJson);
  }

  void _setState(ConfigState s) {
    if (_disposed) return;
    _state = s;
    if (!_stateController.isClosed) _stateController.add(s);
  }

  void _failPending(Object error) {
    _read?.fail(error);
    _write?.fail(error);
    _detect?.fail(error);
    _read = null;
    _write = null;
    _detect = null;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _failPending(StateError('ConfigService disposed'));
    await _statusSub?.cancel();
    _statusSub = null;
    await _stateController.close();
  }

  Future<void> _send(Map<String, dynamic> msg) async {
    if (_disposed) return;
    await session.send(msg);
  }

  /// Generic request helper. Builds a [PendingReply] bounded by
  /// [requestTimeout], hands it to [register] (which stores it on the
  /// appropriate field, superseding any in-flight one), sends the message and
  /// returns the bounded future. Superseding calls [PendingReply.fail], which
  /// cancels the timer — so [onTimeout] only ever runs for the reply still
  /// owning its field and can clear it unconditionally.
  Future<T> _request<T>(
    String type,
    Map<String, dynamic> payload,
    void Function(PendingReply<T>) register, {
    required void Function() onTimeout,
  }) {
    final pending = PendingReply<T>(
      timeout: requestTimeout,
      onTimeout: onTimeout,
    );
    register(pending);
    unawaited(_send(createAbMessage(type, payload)));
    return pending.future;
  }

  void _setRead(PendingReply<AbConfig?> next) {
    _read?.fail(StateError('superseded by new read'));
    _read = next;
  }

  void _setWrite(PendingReply<List<String>?> next) {
    _write?.fail(StateError('superseded by new write'));
    _write = next;
  }

  void _setDetect(PendingReply<List<DetectedTool>> next) {
    _detect?.fail(StateError('superseded by new detect'));
    _detect = next;
  }

  void _onStatusJson(Map<String, dynamic> json) {
    if (_disposed) return;
    final type = json['type'] as String?;
    switch (type) {
      case 'config:read-result':
        _handleReadResult(json);
        break;
      case 'config:write-result':
        _handleWriteResult(json);
        break;
      case 'config:detect-tools-result':
        _handleDetectResult(json);
        break;
      case 'config:changed':
        _handleChanged(json);
        break;
    }
  }

  void _handleReadResult(Map<String, dynamic> j) {
    final ok = j['ok'] as bool;
    if (ok) {
      final cfgJson = j['config'] as Map<String, dynamic>?;
      final cfg = cfgJson == null
          ? const AbConfig()
          : AbConfig.fromJson(cfgJson);
      _setState(_state.copyWith(config: cfg, loading: false, clearError: true));
      _read?.complete(cfg);
    } else {
      _setState(
        _state.copyWith(
          loading: false,
          rawOnError: j['raw'] as String?,
          error: j['error'] as String?,
        ),
      );
      // `null` means the agent answered and there is no usable config — never
      // "we heard nothing". A timed-out read fails instead (see [read]).
      _read?.complete(null);
    }
    _read = null;
  }

  void _handleWriteResult(Map<String, dynamic> j) {
    final ok = j['ok'] as bool;
    if (ok) {
      _write?.complete(null);
    } else {
      final errors = (j['errors'] as List?)?.cast<String>() ?? const <String>[];
      _write?.complete(errors);
    }
    _write = null;
  }

  void _handleDetectResult(Map<String, dynamic> j) {
    final tools = ((j['tools'] as List?) ?? const [])
        .map((e) => DetectedTool.fromJson(e as Map<String, dynamic>))
        .toList();
    _setState(_state.copyWith(detectedTools: tools));
    _detect?.complete(tools);
    _detect = null;
  }

  void _handleChanged(Map<String, dynamic> j) {
    final cfgJson = j['config'] as Map<String, dynamic>?;
    if (cfgJson != null) {
      _setState(
        _state.copyWith(config: AbConfig.fromJson(cfgJson), clearError: true),
      );
    } else {
      _setState(_state.copyWith(error: j['error'] as String?));
    }
  }

  /// Completes with the agent's config, or `null` when the agent answered but
  /// has no usable one. A lost reply throws [TimeoutException] — it must NOT
  /// resolve to `null`, or the settings screen would draft an empty config over
  /// a project whose real `antgrid.yaml` we simply never heard back about.
  Future<AbConfig?> read() {
    _setState(_state.copyWith(loading: true, clearError: true));
    return _request<AbConfig?>('config:read', {}, _setRead, onTimeout: () {
      _read = null;
      _setState(_state.copyWith(
        loading: false,
        error: 'No reply from the agent — config read timed out',
      ));
    });
  }

  /// Returns `null` on success, list of error strings on failure. A lost reply
  /// throws [TimeoutException]: the write may or may not have landed, which is
  /// not the same as "the agent rejected it".
  Future<List<String>?> save(AbConfig cfg) {
    return _request<List<String>?>(
      'config:write',
      {'config': cfg.toJson()},
      _setWrite,
      onTimeout: () => _write = null,
    );
  }

  /// A lost reply throws [TimeoutException] rather than resolving to an empty
  /// list — "no tools installed" and "the agent never answered" drive different
  /// UI, and only one of them should silently blank the agent picker.
  Future<List<DetectedTool>> detectTools() {
    return _request<List<DetectedTool>>(
      'config:detect-tools',
      {},
      _setDetect,
      onTimeout: () => _detect = null,
    );
  }
}
