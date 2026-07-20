import 'dart:async';

import '../models/ab_config.dart';
import '../models/ab_message.dart';
import '../project/project_session.dart';

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

  StreamSubscription<Map<String, dynamic>>? _statusSub;
  final _stateController = StreamController<ConfigState>.broadcast();
  ConfigState _state = const ConfigState();
  bool _disposed = false;

  Completer<AbConfig?>? _readCompleter;
  Completer<List<String>?>?
  _writeCompleter; // null on success, errors otherwise
  Completer<List<DetectedTool>>? _detectCompleter;

  Stream<ConfigState> get stateStream => _stateController.stream;
  ConfigState get currentState => _state;
  String get projectId => session.projectId;

  ConfigService.fromSession(this.session) {
    _statusSub = session.statusStream.listen(_onStatusJson);
  }

  void _setState(ConfigState s) {
    if (_disposed) return;
    _state = s;
    if (!_stateController.isClosed) _stateController.add(s);
  }

  void _failPending(Object error) {
    if (_readCompleter != null && !_readCompleter!.isCompleted) {
      _readCompleter!.completeError(error);
    }
    if (_writeCompleter != null && !_writeCompleter!.isCompleted) {
      _writeCompleter!.completeError(error);
    }
    if (_detectCompleter != null && !_detectCompleter!.isCompleted) {
      _detectCompleter!.completeError(error);
    }
    _readCompleter = null;
    _writeCompleter = null;
    _detectCompleter = null;
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

  /// Generic request helper. Creates a [Completer<T>], passes it to
  /// [register] (which should store it on the appropriate field, superseding
  /// any in-flight completer), sends the message, and returns the future.
  Future<T> _request<T>(
    String type,
    Map<String, dynamic> payload,
    void Function(Completer<T>) register,
  ) {
    final completer = Completer<T>();
    register(completer);
    _send(createAbMessage(type, payload));
    return completer.future;
  }

  void _setReadCompleter(Completer<AbConfig?> next) {
    if (_readCompleter != null && !_readCompleter!.isCompleted) {
      _readCompleter!.completeError(StateError('superseded by new read'));
    }
    _readCompleter = next;
  }

  void _setWriteCompleter(Completer<List<String>?> next) {
    if (_writeCompleter != null && !_writeCompleter!.isCompleted) {
      _writeCompleter!.completeError(StateError('superseded by new write'));
    }
    _writeCompleter = next;
  }

  void _setDetectCompleter(Completer<List<DetectedTool>> next) {
    if (_detectCompleter != null && !_detectCompleter!.isCompleted) {
      _detectCompleter!.completeError(StateError('superseded by new detect'));
    }
    _detectCompleter = next;
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
      _readCompleter?.complete(cfg);
    } else {
      _setState(
        _state.copyWith(
          loading: false,
          rawOnError: j['raw'] as String?,
          error: j['error'] as String?,
        ),
      );
      _readCompleter?.complete(null);
    }
    _readCompleter = null;
  }

  void _handleWriteResult(Map<String, dynamic> j) {
    final ok = j['ok'] as bool;
    if (ok) {
      _writeCompleter?.complete(null);
    } else {
      final errors = (j['errors'] as List?)?.cast<String>() ?? const <String>[];
      _writeCompleter?.complete(errors);
    }
    _writeCompleter = null;
  }

  void _handleDetectResult(Map<String, dynamic> j) {
    final tools = ((j['tools'] as List?) ?? const [])
        .map((e) => DetectedTool.fromJson(e as Map<String, dynamic>))
        .toList();
    _setState(_state.copyWith(detectedTools: tools));
    _detectCompleter?.complete(tools);
    _detectCompleter = null;
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

  Future<AbConfig?> read() {
    _setState(_state.copyWith(loading: true, clearError: true));
    return _request('config:read', {}, _setReadCompleter);
  }

  /// Returns `null` on success, list of error strings on failure.
  Future<List<String>?> save(AbConfig cfg) {
    return _request('config:write', {
      'config': cfg.toJson(),
    }, _setWriteCompleter);
  }

  Future<List<DetectedTool>> detectTools() {
    return _request('config:detect-tools', {}, _setDetectCompleter);
  }
}
