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
import '../services/pending_reply.dart';
import '../storage/cached_sessions_store.dart';
import '../util/device_id.dart';
import '../util/detached.dart';
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
  Set<String>? _lastLiveCheckouts;
  final Set<Future<void>> _checkoutDisposals = {};

  /// Checkouts whose bundles carry the heavy hydrators. Remembered rather than
  /// derived from [_checkoutServices]: the session list can build a bundle for
  /// an id already named here, and it has to come up active.
  Set<String> _activeCheckouts = const {};
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
  StreamSubscription? _sessionDownSub;
  StreamSubscription<TransportState>? _transportStateSub;
  StreamSubscription? _checkoutSessionSub;
  StreamSubscription? _checkoutRefusalSub;
  bool _closed = false;

  /// Tracked replies registered via [newPending]. Untyped so one registry can
  /// hold every service's `PendingReply<T>` regardless of `T` — Dart's
  /// generics are covariant, so each still narrows correctly for its owner.
  final _pendingReplies = <PendingReply<dynamic>>{};

  /// Whether the transport carrying this project is currently unusable — a
  /// local socket teardown, or (relay) a dropped machine session between
  /// `sessionDownEvents` and the next `streamReadyEvents` for this project.
  /// Drives [newPending]'s immediate-fail path; see [_markDown]/[_markUp].
  bool _down;

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
           : projectId,
       // Derived, not assumed false: production always builds a session over
       // an already-established transport (see `defaultProjectSessionFactory`
       // and `LocalTransport.connect`), but every test harness constructs one
       // directly, sometimes over a transport that starts down.
       _down = transport is StreamTransport
           ? !transport.isEstablished
           : (transport.currentState == TransportState.disconnected ||
                 transport.currentState == TransportState.error) {
    _router = MessageRouter(transport: transport);
    // Main's SLICE, not the whole tier. This notifier is the PROJECT's
    // status, and an isolated session's worktree runs its own copy of
    // antgrid.yaml — same service names, its own ports, its own config
    // validity. Fed the raw tier, it folded every checkout's frame in as the
    // project's own, last writer wins, and then cached and persisted that.
    // Scoping at the stream rather than inside the notifier keeps it uniform
    // with every other per-checkout consumer, and a frame carrying no
    // checkoutId still lands here — `checkoutIdForEnvelope` answers 'main'
    // for it, which is what keeps `agent:hello` (about the agent, not a tree)
    // flowing.
    status = ProjectStatusNotifier(checkoutStatusStream('main'));
    _mainCheckoutServices = CheckoutServices(this, 'main');
    _checkoutServices['main'] = _mainCheckoutServices;
    sessionsService = SessionsService.fromSession(
      this,
      cache: cachedSessionsStore,
    );
    // Eager construction, not lazy-on-focus: the notification aggregators in
    // providers.dart fan in over [checkoutServiceBundles], so an isolated
    // session that has never been focused would produce no notifications at
    // all. Only the per-checkout PULLS are focus-gated — see
    // [CheckoutServices.activate].
    _checkoutSessionSub = sessionsService.listings.listen((listing) {
      if (_closed) return;
      final live = <String>{'main'};
      for (final entry in listing.sessions) {
        live.add(entry.checkoutId);
      }
      _lastLiveCheckouts = live;
      for (final entry in listing.sessions) {
        if (entry.checkoutId != 'main') servicesForCheckout(entry.checkoutId);
      }
      _sweepCheckouts(live);
    });
    _checkoutRefusalSub = statusStream.listen(_onCheckoutRefusal);
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
            _markUp();
          });
      // The machine session dropping is the relay-side "down": a stream that
      // loses its session cannot answer anything until the next handshake
      // rebinds this project, which is exactly what the streamReadyEvents
      // listener above reports back as "up".
      _sessionDownSub = session.sessionDownEvents.listen((_) => _markDown());
    } else {
      // Local transport (and every test double that is neither this nor a
      // StreamTransport, e.g. FakeAgentTransport/DemoTransport): the socket's
      // own lifecycle IS the down/up signal, with no separate session layer.
      _transportStateSub = transport.stateChanges.listen((s) {
        switch (s) {
          case TransportState.disconnected:
          case TransportState.error:
            _markDown();
          case TransportState.connected:
            _markUp();
          case TransportState.connecting:
            break;
        }
      });
    }
  }

  /// Constructs a [PendingReply] tracked in this session's down/up registry.
  /// Every service that awaits a wire reply should register through here
  /// rather than building a bare [PendingReply] directly: when the transport
  /// carrying this project goes down, every tracked reply is failed with
  /// [SessionDownException] immediately instead of quietly waiting out its own
  /// timer against a channel nothing will ever answer on.
  ///
  /// If the session is ALREADY down when this is called, the reply is still
  /// registered and returned — the caller's own map/field insertion (which
  /// normally follows right after this returns) is what a synchronous fail
  /// here would race ahead of, leaving a dead entry the owner never recorded.
  /// The fail is deferred to a microtask instead, so it reaches the reply only
  /// once the caller has finished registering it — see [_pendingReplies].
  PendingReply<T> newPending<T>({
    required Duration timeout,
    void Function()? onTimeout,
    void Function()? onAbandon,
    Object Function()? timeoutError,
  }) {
    final pending = PendingReply<T>(
      timeout: timeout,
      onTimeout: onTimeout,
      onAbandon: onAbandon,
      timeoutError: timeoutError,
    );
    _pendingReplies.add(pending);
    pending.future.whenComplete(() => _pendingReplies.remove(pending)).ignore();
    if (_down) {
      scheduleMicrotask(() => pending.fail(const SessionDownException()));
    }
    return pending;
  }

  void _markDown() {
    if (_down) return;
    _down = true;
    _failAllPending(const SessionDownException());
  }

  void _markUp() {
    _down = false;
  }

  void _failAllPending(SessionDownException error) {
    final replies = _pendingReplies.toList();
    _pendingReplies.clear();
    for (final p in replies) {
      p.fail(error);
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

  /// Fires once the app has declared it can render again — with the
  /// declaration already on the wire — so a surface that rebuilds from
  /// snapshots can re-pull into a window the agent is no longer suppressing.
  /// See [MessageRouter.focusResumed]; this is a project-level edge, and every
  /// per-checkout bundle whose state the agent SUPPRESSES subscribes to it to
  /// pull its own — terminals, the file tree, the preview. A bundle carried on
  /// the status tier (config) is never suppressed and needs no subscription.
  Stream<void> get focusResumed => _router.focusResumed;

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
    final live = _lastLiveCheckouts;
    if (live != null && !live.contains(checkoutId)) {
      _pendingCheckoutSweep = {..._pendingCheckoutSweep, checkoutId};
    }
    if (_activeCheckouts.contains(checkoutId)) bundle.activate();
    _checkoutBundlesController.add(bundle);
    return bundle;
  }

  CheckoutServices? existingServicesForCheckout(String checkoutId) =>
      _checkoutServices[checkoutId];

  Set<String> get activeCheckouts => Set.unmodifiable(_activeCheckouts);

  /// Activates the bundle for every id in [ids] (building it through
  /// [servicesForCheckout] if it doesn't exist yet) and deactivates every
  /// other bundle this session holds. A project switched away from keeps its
  /// last active set — nothing here reacts to focus leaving the project.
  void setActiveCheckouts(Set<String> ids) {
    _activeCheckouts = Set<String>.from(ids);
    for (final id in _activeCheckouts) {
      servicesForCheckout(id).activate();
    }
    // Snapshot first: `servicesForCheckout` above inserts into the map this
    // iterates.
    for (final entry in _checkoutServices.entries.toList()) {
      if (_activeCheckouts.contains(entry.key)) continue;
      entry.value.deactivate();
    }
  }

  /// Releases bundles whose session is gone. Deferred by one listing: the
  /// providers that read a bundle are driven by the SAME session list, so
  /// disposing on the emission that drops the session would tear it down under
  /// a focus that has not moved off it yet. Unchanged listings still advance
  /// cleanup; state equality says nothing about whether readers moved on.
  /// Every service holds transport hydrators, so
  /// leaving them registered replays requests for a deleted checkout on every
  /// reconnect.
  void _sweepCheckouts(Set<String> live) {
    for (final id in _pendingCheckoutSweep) {
      if (live.contains(id)) continue;
      _releaseCheckout(id);
    }
    // Union, not just the bundle map: a checkout can leave durable frames the
    // router retains without ever getting a bundle (an archived session still
    // in the bridge's replay cache), and nothing else would ever evict them.
    _pendingCheckoutSweep = <String>{
      ..._checkoutServices.keys,
      ..._router.replayCheckoutIds,
    }.where((id) => !live.contains(id)).toSet();
  }

  void _onCheckoutRefusal(Map<String, dynamic> json) {
    if (_closed || json['type'] != 'control:result' || json['ok'] != false) {
      return;
    }
    final error = json['error'];
    if (error is! Map || error['code'] != 'UNKNOWN_CHECKOUT') return;
    final id = json['checkoutId'];
    final live = _lastLiveCheckouts;
    if (id is! String || live == null || live.contains(id)) return;
    if (!_pendingCheckoutSweep.contains(id)) return;
    _releaseCheckout(id);
    _pendingCheckoutSweep = {..._pendingCheckoutSweep}..remove(id);
  }

  void _releaseCheckout(String id) {
    if (id == 'main') return;
    final bundle = _checkoutServices.remove(id);
    _router.dropCheckoutReplay(id);
    _activeCheckouts = {..._activeCheckouts}..remove(id);
    if (bundle == null) return;
    bundle.deactivate();
    final disposal = bundle.dispose();
    _checkoutDisposals.add(disposal);
    detached('project_session', 'dispose deleted checkout', () async {
      try {
        await disposal;
      } finally {
        _checkoutDisposals.remove(disposal);
      }
    });
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

  /// See [AgentTransport.establishmentEpoch] — a service caching a
  /// server-issued revision records this beside it.
  int get establishmentEpoch => transport.establishmentEpoch;

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
    // A `newPending` issued after close (a stray late call from a service
    // mid-teardown) must fail immediately through the down path rather than
    // arming a live timer against a session nothing will ever reconnect.
    _down = true;
    // Services own disjoint state; dispose them concurrently so focus-switch
    // teardown latency is bounded by the slowest, not the sum. Each already
    // fails its own in-flight replies with its own dispose-specific message
    // (e.g. "FileService disposed") — the registry's own fail below runs
    // AFTER, so it only ever catches a reply none of them cleaned up, rather
    // than racing ahead of a more specific message with a generic one.
    await Future.wait([
      if (_fragAbortSub != null) _fragAbortSub!.cancel(),
      if (_fragSendErrSub != null) _fragSendErrSub!.cancel(),
      if (_streamReadySub != null) _streamReadySub!.cancel(),
      if (_sessionDownSub != null) _sessionDownSub!.cancel(),
      if (_transportStateSub != null) _transportStateSub!.cancel(),
      if (_checkoutSessionSub != null) _checkoutSessionSub!.cancel(),
      if (_checkoutRefusalSub != null) _checkoutRefusalSub!.cancel(),
      sessionsService.dispose(),
      handlerService.dispose(),
      agentSessionService.dispose(),
      for (final bundle in _checkoutServices.values) bundle.dispose(),
      ..._checkoutDisposals,
    ]);
    // A session torn down with a reply in flight that outlives every
    // service's own cleanup (a future PendingReply site that forgets to
    // implement dispose) fails it now rather than leaving it to time out
    // against a transport nobody will reconnect.
    _failAllPending(const SessionDownException());
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

  // Plain field, NOT `late final`: checkout_scoped_service_reads_test.dart
  // scrapes every `late final <Type> <name>;` in this class as a
  // checkout-variable SERVICE.
  bool _active = false;
  bool get isActive => _active;

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

  /// Registers the pulls that cost a round trip per checkout — the tree, the
  /// config, the preview and terminal snapshots — and subscribes the
  /// focus-resume re-pulls that drive the same set again on every foreground.
  /// A hydrator fires the moment it is registered on an established transport,
  /// so this is the pull as well as the re-drive. Only the checkout on screen
  /// carries them: a project with nine managed checkouts put nine trees on the
  /// wire at once at every bind, which stalled the relay's window.
  void activate() {
    if (_active) return;
    _active = true;
    fileService.activate();
    terminalService.activate();
    configService.activate();
    previewService.activate();
  }

  /// Leaves every service's state intact — switching back renders the last
  /// tree while [activate]'s re-pull refreshes it.
  void deactivate() {
    if (!_active) return;
    _active = false;
    fileService.deactivate();
    terminalService.deactivate();
    configService.deactivate();
    previewService.deactivate();
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
