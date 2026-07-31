import 'dart:async';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';

import '../models/ab_message.dart';
import '../models/agent_work_status.dart';
import '../models/session_entry.dart';

export '../models/agent_work_status.dart' show AgentWorkStatus;

/// A project advertised by the agent over the control-plane connection.
///
/// Hand-mirrors the bridge `agent:projects` entry schema
/// (`{ projectId, label?, path?, running, status?, runningSessions? }`) per the
/// package convention that the Dart side mirrors the TS Zod schemas by hand.
class AdvertisedProject {
  final String projectId;
  final String? label;
  final String? path;
  final bool running;

  /// Live work status, present only for warm cores. Null when talking to an
  /// older bridge, or for a cold project — callers fall back to [running].
  final AgentWorkStatus? status;

  /// Live non-archived running-session count, present only for warm cores.
  /// Null on an older bridge or a cold project. A change here means the
  /// project's session list actually changed — the trigger for re-peeking it
  /// (see app_shell's _onControlPlaneState), which `status` alone can't signal.
  final int? runningSessions;
  final String? lastActiveAt;

  const AdvertisedProject({
    required this.projectId,
    this.label,
    this.path,
    required this.running,
    this.status,
    this.runningSessions,
    this.lastActiveAt,
  });

  static AdvertisedProject? fromJson(Map<String, dynamic> json) {
    final projectId = json['projectId'];
    final running = json['running'];
    if (projectId is! String || running is! bool) return null;
    return AdvertisedProject(
      projectId: projectId,
      label: json['label'] as String?,
      path: json['path'] as String?,
      running: running,
      status: AgentWorkStatus.fromWire(json['status']),
      runningSessions: (json['runningSessions'] as num?)?.toInt(),
      lastActiveAt: json['lastActiveAt'] as String?,
    );
  }
}

/// An installed tool advertised by the agent over the control plane. Mirrors the
/// bridge `agent:tools` entry (`{ tool, path, chatCapable?, label? }`). Both
/// optional fields are null when talking to an older bridge that predates them —
/// callers fall back to the app's static tables in that case.
class AdvertisedTool {
  final String tool;
  final String path;
  final bool? chatCapable;
  final String? label;
  const AdvertisedTool({
    required this.tool,
    required this.path,
    this.chatCapable,
    this.label,
  });

  static AdvertisedTool? fromJson(Map<String, dynamic> json) {
    final tool = json['tool'];
    final path = json['path'];
    if (tool is! String || path is! String) return null;
    return AdvertisedTool(
      tool: tool,
      path: path,
      chatCapable: json['chatCapable'] as bool?,
      label: json['label'] as String?,
    );
  }
}

/// A structured error reported by the agent in response to a control-plane
/// verb (e.g. `project:start`). Mirrors the agent's `{ ok:false, error:{ code,
/// message } }` shape — `NOT_ALLOWED` means mobile access is switched off on
/// that machine.
class ControlPlaneError {
  final String code;
  final String message;

  const ControlPlaneError({required this.code, required this.message});
}

/// Observable state for the control-plane client.
class ControlPlaneState {
  final List<AdvertisedProject> projects;
  final List<AdvertisedTool> tools;
  final ControlPlaneError? lastError;

  const ControlPlaneState({
    this.projects = const [],
    this.tools = const [],
    this.lastError,
  });

  ControlPlaneState copyWith({
    List<AdvertisedProject>? projects,
    List<AdvertisedTool>? tools,
    ControlPlaneError? lastError,
    bool clearError = false,
  }) => ControlPlaneState(
    projects: projects ?? this.projects,
    tools: tools ?? this.tools,
    lastError: clearError ? null : (lastError ?? this.lastError),
  );
}

/// Client bound to the CONTROL-PLANE connection (not a per-project
/// data-plane [ProjectSession]). It subscribes to the transport's inbound
/// message stream in its constructor — mirroring the per-project services'
/// stream-subscription pattern (see `ConfigService.fromSession`) — so that a
/// welcome-cached `agent:projects` advertisement is caught immediately.
///
/// Testable without a real relay: the [AgentTransport] is injected, so a test
/// can feed a decrypted `agent:projects` via `FakeAgentTransport.emit` and
/// inspect `FakeAgentTransport.sent` for the outbound `project:start`.
class ControlPlaneClient {
  final AgentTransport transport;

  StreamSubscription<InboundMessage>? _sub;
  StreamSubscription<bool>? _presenceSub;
  final _stateController = StreamController<ControlPlaneState>.broadcast();
  ControlPlaneState _state = const ControlPlaneState();
  bool _disposed = false;

  Stream<ControlPlaneState> get stateStream => _stateController.stream;
  ControlPlaneState get currentState => _state;

  /// [peerPresence] emits `true` while the control-plane peer is connected and
  /// `false` when it drops. The relay transport never surfaces a disconnect, so
  /// without this signal a closed machine's last advert would linger as
  /// "online". On a `false` the cached advert is cleared so consumers read
  /// offline reactively (no manual refresh); the live message stream repopulates
  /// it when the agent re-adverts after the peer reconnects.
  ControlPlaneClient({required this.transport, Stream<bool>? peerPresence}) {
    _sub = transport.messages.listen(_onMessage);
    _presenceSub = peerPresence?.listen((present) {
      if (!present) clearAdvert();
    });
  }

  void _setState(ControlPlaneState s) {
    if (_disposed) return;
    _state = s;
    if (!_stateController.isClosed) _stateController.add(s);
  }

  void _onMessage(InboundMessage msg) {
    if (_disposed) return;
    if (msg.channel != 'control') return;
    final json = msg.json;
    final type = json['type'] as String?;

    // Agent error envelope: { ok:false, error:{ code, message } }. Surface
    // as error STATE — never throw (a crash here would take down the picker).
    if (json['ok'] == false) {
      _handleError(json);
      return;
    }

    switch (type) {
      case 'agent:projects':
        _handleProjects(json);
        break;
      case 'agent:tools':
        _handleTools(json);
        break;
    }
  }

  void _handleProjects(Map<String, dynamic> json) {
    final raw = json['projects'];
    final projects = <AdvertisedProject>[];
    if (raw is List) {
      for (final p in raw) {
        if (p is Map<String, dynamic>) {
          final parsed = AdvertisedProject.fromJson(p);
          if (parsed != null) projects.add(parsed);
        }
      }
    }
    _setState(_state.copyWith(projects: projects, clearError: true));
  }

  void _handleTools(Map<String, dynamic> json) {
    final raw = json['tools'];
    final tools = <AdvertisedTool>[];
    if (raw is List) {
      for (final t in raw) {
        if (t is Map<String, dynamic>) {
          final parsed = AdvertisedTool.fromJson(t);
          if (parsed != null) tools.add(parsed);
        }
      }
    }
    _setState(_state.copyWith(tools: tools, clearError: true));
  }

  void _handleError(Map<String, dynamic> json) {
    // Always allocate a fresh ControlPlaneError: awaitProjectRunning
    // (new_session_action.dart) uses identical() to detect a NEW error after
    // project:start. Reusing an instance would hide a repeated error from it.
    final err = json['error'];
    if (err is Map<String, dynamic>) {
      final code = err['code'] as String? ?? 'UNKNOWN';
      final message = err['message'] as String? ?? '';
      _setState(
        _state.copyWith(
          lastError: ControlPlaneError(code: code, message: message),
        ),
      );
    } else {
      _setState(
        _state.copyWith(
          lastError: const ControlPlaneError(code: 'UNKNOWN', message: ''),
        ),
      );
    }
  }

  /// Re-pull the durable adverts (projects + tools) on demand — the manual
  /// counterpart to the connect-time `state.snapshot` the transport fires
  /// automatically. Backs the picker/drawer pull-to-refresh.
  ///
  /// Returns `true` when the agent replied (peer reachable), `false` when the
  /// snapshot RPC failed/timed out. A `false` lets the caller clear the cached
  /// advert via [clearAdvert] for a peer that still looks "connected" but no
  /// longer serves RPCs (alive socket, unresponsive agent — before the relay's
  /// ~40s dead-detection closes it). The timeout is deliberately generous: a
  /// false-clear of a slow-but-alive agent only repopulates on its NEXT advert,
  /// so we'd rather wait out a GC/busy pause than flip a healthy machine
  /// offline. Genuine disconnects are handled reactively by `peerPresence`, not
  /// here, so refresh need not be snappy at correctness's expense.
  Future<bool> refresh() async {
    if (_disposed) return false;
    try {
      final snap = await transport.request(
        'state.snapshot',
        params: const {
          'types': ['agent:projects', 'agent:tools'],
        },
        timeout: const Duration(seconds: 10),
      );
      final frames = (snap['frames'] as List?) ?? const [];
      for (final raw in frames) {
        if (raw is Map) {
          _onMessage(InboundMessage('control', raw.cast<String, dynamic>()));
        }
      }
      return true;
    } on RpcException {
      // Pre-RPC agent, offline target, or timeout — the live stream still feeds
      // updates; the caller decides whether to clear the now-stale advert.
      return false;
    }
  }

  /// Drop the cached projects/tools advert — used when the control-plane peer is
  /// found unreachable (the socket went offline but the relay transport keeps
  /// reporting "connected", so the stale advert would otherwise read as online).
  /// The live stream re-populates it when the agent re-adverts after the peer
  /// reconnects, so the connection itself is kept alive.
  void clearAdvert() {
    if (_disposed) return;
    _setState(const ControlPlaneState());
  }

  /// Ask the agent to start (spin up) the project with [projectId]. The
  /// agent re-advertises `agent:projects` with `running:true` once the
  /// project is up, which [awaitProjectRunning] watches for (up to 30s).
  ///
  /// Tier-2 fail-fast, NOT tier-3 re-drive: auto-replaying a start on every
  /// reconnect would spuriously boot stopped projects. project:start has no RPC
  /// reply, so the bound is on DELIVERABILITY. During a keyless (session-down)
  /// window the stream still reads `connected` but the send SILENTLY DROPS
  /// (`sendOnStream` no-ops without keys) — project:start never reaches the host
  /// and `awaitProjectRunning` then burns the full 30s before a generic failure.
  /// Refuse to fire into that window (throw an [RpcException]) so the caller can
  /// surface a retry now instead of waiting it out.
  Future<void> startProject(String projectId) async {
    if (_disposed) return;
    await transport.action(() async {
      if (!transport.isEstablished) {
        throw RpcException(
          'E_NOT_ESTABLISHED',
          'project:start not delivered — the session is reconnecting',
        );
      }
      await transport.send(
        createAbMessage('project:start', {'projectId': projectId}),
      );
    });
  }

  /// Fetch the persisted session list for [projectId] over the control plane —
  /// the drawer's read-only peek. The bridge reads sessions.json directly (no
  /// data-plane socket, no project:start). Lets an `RpcException` (NOT_ALLOWED,
  /// timeout) propagate so the caller can show a retry hint.
  Future<List<SessionEntry>> listSessions(
    String projectId, {
    bool includeArchived = false,
  }) async {
    final res = await transport.request(
      'sessions.list',
      params: {'projectId': projectId, 'includeArchived': includeArchived},
    );
    return SessionEntry.listFromJson(res['sessions'] as List?);
  }

  /// Delete a session over the control plane — the Recent tab's delete path for
  /// a remote project (works whether the project is running or stopped; the
  /// bridge routes warm-core vs disk). Lets an [RpcException] (NOT_ALLOWED,
  /// timeout) propagate so the caller can toast a failure.
  Future<bool> deleteSession(String projectId, String sessionId) async {
    final res = await transport.request(
      'sessions.delete',
      params: {'projectId': projectId, 'sessionId': sessionId},
    );
    return res['deleted'] == true;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _sub?.cancel();
    _sub = null;
    await _presenceSub?.cancel();
    _presenceSub = null;
    await _stateController.close();
  }
}
