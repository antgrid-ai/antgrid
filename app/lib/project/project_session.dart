import 'dart:async';
import 'dart:developer' as developer;

import 'package:antgrid_relay_client/antgrid_relay_client.dart';

import '../analytics/analytics_service.dart';
import '../services/command_service.dart';
import '../services/config_service.dart';
import '../services/file_service.dart';
import '../services/agent_session_service.dart';
import '../services/handler_service.dart';
import '../services/preview_service.dart';
import '../services/search_service.dart';
import '../services/sessions_service.dart';
import '../services/terminal_service.dart';
import '../services/upload_service.dart';
import '../storage/cached_sessions_store.dart';
import '../util/device_id.dart';
import 'fragment_recovery.dart';
import 'message_router.dart';
import 'project_status.dart';

enum ProjectSessionMode { local, relay }

/// Per-project aggregate. Composes the transport, message router, and status
/// notifier. UI consumers will read via the Riverpod family in Task 7.
///
/// Mode-agnostic for everything except [close]: the injected [onClose]
/// callback decides what teardown means (local kills process; relay drops WS).
class ProjectSession {
  /// App-internal identity: for relay this is the compound
  /// `<deviceUuid>.<projectId>` registrationId (the relay focus id, also the
  /// transport routing key); for local it's the bare project id. Used for
  /// cross-provider matching (e.g. sessions.dart gates on this) and cache keys.
  final String projectId;

  /// The bare local project id the BRIDGE keys its file/git/search/command
  /// handlers by. Equal to [projectId] for local sessions; the suffix of the
  /// compound registrationId for relay. Outbound payloads must use this, not the
  /// compound id — see [send].
  final String wireProjectId;

  final AgentTransport transport;
  final ProjectSessionMode mode;
  final CachedSessionsStore cachedSessionsStore;
  final Future<void> Function() _onClose;

  /// Optional analytics sink. Null when telemetry is unavailable (tests, or a
  /// call site that omits it); every `analytics?.track(...)` is null-safe.
  final AnalyticsService? analytics;

  late final MessageRouter _router;
  late final ProjectStatusNotifier status;
  late final FileService fileService;
  late final SessionsService sessionsService;
  late final TerminalService terminalService;
  late final ConfigService configService;
  late final SearchService searchService;
  late final CommandService commandService;
  late final PreviewService previewService;
  late final HandlerService handlerService;
  late final AgentSessionService agentSessionService;
  late final UploadService uploadService;
  StreamSubscription? _fragAbortSub;
  StreamSubscription? _fragSendErrSub;
  bool _closed = false;

  ProjectSession({
    required this.projectId,
    required this.transport,
    required this.mode,
    required this.cachedSessionsStore,
    required Future<void> Function() onClose,
    this.analytics,
  }) : _onClose = onClose,
       wireProjectId = mode == ProjectSessionMode.relay
           ? baseProjectId(projectId)
           : projectId {
    _router = MessageRouter(transport: transport);
    status = ProjectStatusNotifier(_router.status);
    fileService = FileService.fromSession(this);
    sessionsService = SessionsService.fromSession(
      this,
      cache: cachedSessionsStore,
    );
    terminalService = TerminalService.fromSession(this);
    configService = ConfigService.fromSession(this);
    searchService = SearchService.fromSession(this);
    commandService = CommandService.fromSession(this);
    previewService = PreviewService.fromSession(this);
    handlerService = HandlerService.fromSession(this);
    agentSessionService = AgentSessionService.fromSession(this);
    uploadService = UploadService.fromSession(this);
    if (transport is StreamTransport) {
      // Fragmentation is per-machine in v3, so the abort/send-error signals live
      // on the shared MachineSession (every project stream on a machine sees
      // them; the recovery hint carries the file path, so a re-request keyed to
      // the wrong project is a harmless miss).
      final session = (transport as StreamTransport).session;
      final coordinator = FragmentRecoveryCoordinator(
        requestFileContent: fileService.requestFileContent,
        requestDiff: fileService.requestDiff,
        onFailed: fileService.handleFragmentFailure,
      );
      _fragAbortSub = session.fragmentAborts.listen(coordinator.onAbort);
      fileService.onFragmentSuccess = coordinator.onSuccess;
      _fragSendErrSub =
          session.fragmentSendErrors.listen(_onFragmentSendError);
    }
  }

  void _onFragmentSendError(FragSendError err) {
    // An outbound control message exceeded kMaxTransferBytes and was dropped
    // before sealing. Log rather than fail silently — symmetric with the
    // bridge's onError path; no app message realistically reaches the cap.
    developer.log(
      'fragment send dropped: ${err.code} ${err.message}',
      name: 'antgrid.relay',
    );
  }

  /// Heavy-tier inbound stream. Subscribing triggers `client:focus-state
  /// {paused: false}` to the agent; the last cancel triggers `{paused: true}`.
  Stream<Map<String, dynamic>> get heavyStream => _router.heavy;

  /// Status-tier inbound stream. Always-on (no focus gating), used by sessions
  /// and config services which need to react to small state-tier messages
  /// without burdening the agent's heavy pipeline.
  Stream<Map<String, dynamic>> get statusStream => _router.status;

  /// Send an outbound message through the transport.
  ///
  /// Rewrites any `projectId` field to [wireProjectId]: services stamp payloads
  /// with [projectId] (the compound relay registrationId), but the bridge
  /// resolves file/git/search/command verbs by the bare local id and would drop
  /// a compound one as "unknown projectId" (no `file:content` ever returns).
  /// No-op for local sessions and for messages without a `projectId` (e.g. the
  /// high-frequency terminal:input, keyed by terminalId).
  Future<void> send(Map<String, dynamic> message) {
    if (mode == ProjectSessionMode.relay && message.containsKey('projectId')) {
      message = {...message, 'projectId': wireProjectId};
    }
    return transport.send(message);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    // Services own disjoint state; dispose them concurrently so focus-switch
    // teardown latency is bounded by the slowest, not the sum.
    await Future.wait([
      if (_fragAbortSub != null) _fragAbortSub!.cancel(),
      if (_fragSendErrSub != null) _fragSendErrSub!.cancel(),
      terminalService.dispose(),
      sessionsService.dispose(),
      fileService.dispose(),
      configService.dispose(),
      searchService.dispose(),
      commandService.dispose(),
      previewService.dispose(),
      handlerService.dispose(),
      agentSessionService.dispose(),
      uploadService.dispose(),
    ]);
    status.dispose();
    await _router.dispose();
    await _onClose();
  }
}
