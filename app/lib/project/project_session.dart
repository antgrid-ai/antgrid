import 'dart:async';
import 'dart:developer' as developer;

import 'package:antgrid_relay_client/antgrid_relay_client.dart';

import '../analytics/analytics_service.dart';
import '../providers/seeded_stream.dart';
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
import 'project_message_classification.dart';
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
  late final CheckoutServices _mainCheckoutServices;
  final Map<String, CheckoutServices> _checkoutServices = {};
  Set<String> _pendingCheckoutSweep = const {};
  final StreamController<CheckoutServices> _checkoutBundlesController =
      StreamController<CheckoutServices>.broadcast();
  FileService get fileService => _mainCheckoutServices.fileService;
  late final SessionsService sessionsService;
  TerminalService get terminalService => _mainCheckoutServices.terminalService;
  ConfigService get configService => _mainCheckoutServices.configService;
  SearchService get searchService => _mainCheckoutServices.searchService;
  CommandService get commandService => _mainCheckoutServices.commandService;
  PreviewService get previewService => _mainCheckoutServices.previewService;
  late final HandlerService handlerService;
  late final AgentSessionService agentSessionService;
  UploadService get uploadService => _mainCheckoutServices.uploadService;
  StreamSubscription? _fragAbortSub;
  StreamSubscription? _fragSendErrSub;
  StreamSubscription? _streamReadySub;
  StreamSubscription? _checkoutSessionSub;
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
    _mainCheckoutServices = CheckoutServices(this, 'main');
    _checkoutServices['main'] = _mainCheckoutServices;
    sessionsService = SessionsService.fromSession(
      this,
      cache: cachedSessionsStore,
    );
    // Eager, not lazy-on-focus: the notification aggregators in providers.dart
    // fan in over [checkoutServiceBundles], so an isolated session that has
    // never been focused would produce no notifications at all.
    _checkoutSessionSub = sessionsService.stateStream.listen((state) {
      final live = <String>{'main'};
      for (final entry in state.sessions) {
        live.add(entry.checkoutId);
        if (entry.checkoutId != 'main') servicesForCheckout(entry.checkoutId);
      }
      _sweepCheckouts(live);
    });
    handlerService = HandlerService.fromSession(this);
    agentSessionService = AgentSessionService.fromSession(this);
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
      _fragSendErrSub = session.fragmentSendErrors.listen(_onFragmentSendError);
      // Relay only: the agent resets `appFocusPaused` for each connection, and
      // sends before the handshake are dropped silently — so re-declare focus
      // once this project's stream is ready. Local mode has no handshake and no
      // such window. Deferred transcript hydration is NOT wired here anymore: it
      // rides the transport's hydrator registry, which refreshSnapshot re-drives
      // on every (re)establish (see AgentSessionService.hydrateIfNeeded).
      // Matched on wireProjectId: streamReadyEvents carries the BARE id the
      // bridge advertises in `agent:projects`, not the compound registrationId.
      //
      // BOTH halves of the focus declaration have to be restated, and the
      // lifecycle one alone is worse than neither: the bridge drops this
      // client's focused SESSION when the socket closes but keeps read tracking
      // armed, so re-arming it without re-naming the session is exactly the
      // state in which the next turn-end paints an unread dot on whatever the
      // user is currently looking at.
      _streamReadySub = session.streamReadyEvents
          .where((e) => e.projectId == wireProjectId)
          .listen((_) {
            _router.resyncFocusState();
            sessionsService.resyncFocus();
          });
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

  /// Heavy-tier inbound stream. Subscription presence is one of the two inputs
  /// to the agent's `client:focus-state`; see [setLifecyclePaused].
  Stream<Map<String, dynamic>> get heavyStream => _router.heavy;

  /// Single-subscription — see [_checkoutStream]. Call this per consumer
  /// rather than sharing one returned stream between listeners.
  Stream<Map<String, dynamic>> checkoutHeavyStream(String checkoutId) =>
      _checkoutStream(heavyStream, checkoutId, MessageTier.heavy);

  /// Declares app-level background state to the agent, gating both the heavy
  /// stream and the fallback push. See [MessageRouter.setLifecyclePaused].
  void setLifecyclePaused(bool paused) => _router.setLifecyclePaused(paused);

  /// Status-tier inbound stream. Always-on (no focus gating), used by sessions
  /// and config services which need to react to small state-tier messages
  /// without burdening the agent's heavy pipeline.
  Stream<Map<String, dynamic>> get statusStream => _router.status;

  /// Single-subscription — see [_checkoutStream]. Call this per consumer
  /// rather than sharing one returned stream between listeners.
  Stream<Map<String, dynamic>> checkoutStatusStream(String checkoutId) =>
      _checkoutStream(statusStream, checkoutId, MessageTier.status);

  /// [checkoutId]'s slice of a tier, seeded with the durable frames the router
  /// has already seen for it.
  ///
  /// The seed is what keeps an isolated session's bundle recoverable. Bundles
  /// are built from the session list, which lands a round trip AFTER the
  /// connect-time `state.snapshot` has already replayed that checkout's
  /// `agent:status` / `tree:full` / `git:status` — a plain `.where()` over the
  /// broadcast tier dropped them for want of a subscriber, and nothing re-sends
  /// them, so the session sat on "waiting for agent" until the next reconnect.
  ///
  /// The seed is per-listener, so the returned stream is single-subscription
  /// even though the tier it wraps is broadcast: a broadcast controller runs
  /// `onListen` only for its first listener and would silently hand every later
  /// one an unseeded stream. A duplicate same-value emit is harmless — every
  /// seeded type is a latest-wins snapshot.
  Stream<Map<String, dynamic>> _checkoutStream(
    Stream<Map<String, dynamic>> tier,
    String checkoutId,
    MessageTier tierKind,
  ) => seededStreamAll(
    () => _router.replayFor(checkoutId, tierKind),
    tier.where((json) => checkoutIdForEnvelope(json) == checkoutId),
  );

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

  CheckoutServices servicesForCheckout(String checkoutId) {
    final existing = _checkoutServices[checkoutId];
    if (existing != null) return existing;
    final bundle = CheckoutServices(this, checkoutId);
    _checkoutServices[checkoutId] = bundle;
    _checkoutBundlesController.add(bundle);
    return bundle;
  }

  CheckoutServices? existingServicesForCheckout(String checkoutId) =>
      _checkoutServices[checkoutId];

  /// Releases bundles whose session is gone. Deferred by one emission: the
  /// providers that read a bundle are driven by the SAME session list, so
  /// disposing on the emission that drops the session would tear it down under
  /// a focus that has not moved off it yet. A bundle absent from two successive
  /// listings has no reader left. Every service holds transport hydrators, so
  /// leaving them registered replays requests for a deleted checkout on every
  /// reconnect.
  void _sweepCheckouts(Set<String> live) {
    for (final id in _pendingCheckoutSweep) {
      if (live.contains(id)) continue;
      unawaited(_checkoutServices.remove(id)?.dispose() ?? Future.value());
      // Symmetric with the bridge's own dropCheckoutReplay: a removed worktree
      // must not keep seeding a bundle that a stale id could still recreate.
      _router.dropCheckoutReplay(id);
    }
    // Union, not just the bundle map: a checkout can leave durable frames the
    // router retains without ever getting a bundle (an archived session still
    // in the bridge's replay cache), and nothing else would ever evict them.
    _pendingCheckoutSweep = <String>{
      ..._checkoutServices.keys,
      ..._router.replayCheckoutIds,
    }.where((id) => !live.contains(id)).toSet();
  }

  Iterable<CheckoutServices> get checkoutServiceBundles =>
      _checkoutServices.values;

  Stream<CheckoutServices> get checkoutServiceBundleStream =>
      _checkoutBundlesController.stream;

  Future<void> sendForCheckout(
    String checkoutId,
    Map<String, dynamic> message,
  ) {
    final type = message['type'];
    if (type is String && kCheckoutVariableMessageTypes.contains(type)) {
      message = {...message, 'checkoutId': checkoutId};
    }
    return send(message);
  }

  /// Tier-3 re-drive registration. Registers [run] as the hydrator for [key] on
  /// the transport: it fires now when the session is already established and
  /// re-fires on every future (re)establishment — the receive-side counterpart
  /// of the durable snapshot, so a reconnect re-pulls idempotent view-state
  /// (session list, config, the open file) instead of stranding it stale. A
  /// re-register under [key] supersedes. See [AgentTransport.hydrate].
  Future<void> hydrate(String key, Future<void> Function() run) =>
      transport.hydrate(key, run);

  Future<void> hydrateCheckout(
    String checkoutId,
    String key,
    Future<void> Function() run,
  ) => hydrate('checkout:$checkoutId:$key', run);

  /// Deregister a hydrator registered via [hydrate]. No-op if absent.
  void unhydrate(String key) => transport.unhydrate(key);

  void unhydrateCheckout(String checkoutId, String key) =>
      unhydrate('checkout:$checkoutId:$key');

  /// Tier-2 bounded fail-fast send: runs [run] under [timeout] so the caller's
  /// flag lifecycle always settles even if the reply never arrives. NOT
  /// re-driven on reconnect. See [AgentTransport.action].
  Future<T> action<T>(
    Future<T> Function() run, {
    Duration? timeout = const Duration(seconds: 15),
  }) => transport.action(run, timeout: timeout);

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    // Services own disjoint state; dispose them concurrently so focus-switch
    // teardown latency is bounded by the slowest, not the sum.
    await Future.wait([
      if (_fragAbortSub != null) _fragAbortSub!.cancel(),
      if (_fragSendErrSub != null) _fragSendErrSub!.cancel(),
      if (_streamReadySub != null) _streamReadySub!.cancel(),
      if (_checkoutSessionSub != null) _checkoutSessionSub!.cancel(),
      sessionsService.dispose(),
      handlerService.dispose(),
      agentSessionService.dispose(),
      for (final bundle in _checkoutServices.values) bundle.dispose(),
    ]);
    status.dispose();
    await _checkoutBundlesController.close();
    await _router.dispose();
    await _onClose();
  }
}

class CheckoutServices {
  final String checkoutId;
  late final FileService fileService;
  late final TerminalService terminalService;
  late final ConfigService configService;
  late final SearchService searchService;
  late final CommandService commandService;
  late final PreviewService previewService;
  late final UploadService uploadService;

  CheckoutServices(ProjectSession session, this.checkoutId) {
    fileService = FileService.fromSession(session, checkoutId: checkoutId);
    terminalService = TerminalService.fromSession(
      session,
      checkoutId: checkoutId,
    );
    configService = ConfigService.fromSession(session, checkoutId: checkoutId);
    searchService = SearchService.fromSession(session, checkoutId: checkoutId);
    commandService = CommandService.fromSession(
      session,
      checkoutId: checkoutId,
    );
    previewService = PreviewService.fromSession(
      session,
      checkoutId: checkoutId,
    );
    uploadService = UploadService.fromSession(session, checkoutId: checkoutId);
  }

  Future<void> dispose() => Future.wait([
    terminalService.dispose(),
    fileService.dispose(),
    configService.dispose(),
    searchService.dispose(),
    commandService.dispose(),
    previewService.dispose(),
    uploadService.dispose(),
  ]);
}
