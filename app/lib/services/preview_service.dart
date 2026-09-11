import 'dart:async';
import 'dart:convert';

import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';

import '../demo/demo_identity.dart';
import '../models/preview_models.dart';
import '../models/ab_message.dart';
import '../project/project_message_classification.dart';
import '../project/project_session.dart';
import '../util/ab_log.dart';
import '../util/detached.dart';
import 'pending_reply.dart';
import 'preview_proxy_server.dart';
import 'tunnel_body.dart';

/// Outcome of [PreviewService.selectPort]. `portInUse` means the exact local
/// port couldn't be bound and the caller should confirm a fallback before
/// retrying via [PreviewService.selectPortWithFallback].
enum SelectPortResult { opened, portInUse }

/// Per-project preview service. Heavy-tier primary (preview:snapshot,
/// preview:url) with a status-tier subscription for `ports:update` and a
/// direct transport subscription for preview-channel tunnel responses
/// (which the MessageRouter doesn't forward because it only routes the
/// control channel).
///
/// Constructed at [ProjectSession] creation time. Lifetime is bound to the
/// session; calling [dispose] cancels all subscriptions and closes the
/// state controller.
class PreviewService {
  final ProjectSession session;
  final String checkoutId;

  StreamSubscription<Map<String, dynamic>>? _heavySub;
  StreamSubscription<Map<String, dynamic>>? _statusSub;
  StreamSubscription<InboundMessage>? _txSub;
  bool _disposed = false;

  final _stateController = StreamController<PreviewState>.broadcast();
  PreviewState _state = const PreviewState();

  /// In-flight tunnel requests, held WITH the request so a frame the relay
  /// dropped can be re-sent. A re-send normally reuses the original
  /// `requestId`, which is what lets the bridge replay a response it already
  /// produced instead of running the upstream request twice (see
  /// TunnelManager's outbox); only a lost head re-keys, and [_onHeadLost] says
  /// why. Keyed by the CURRENT id, so a re-key re-inserts the same entry.
  final Map<String, _InFlightRequest> _pendingRequests = {};
  final Map<String, _WsTunnel> _activeWsTunnels = {};

  /// Ids already answered with one `tunnel:http-cancel` while unknown to us.
  /// A stale run keeps sending for as long as its window holds — up to a whole
  /// body — so the first stray frame buys one cancel and every later one is
  /// free; without the memory a window of stale chunks becomes a window of
  /// cancels. Insertion-ordered, so `first` is the oldest.
  final Set<String> _cancelledIds = <String>{};

  /// FIFO bound on [_cancelledIds]. Overflowing it only costs a repeat cancel,
  /// which the bridge treats as a no-op.
  static const _maxCancelledIds = 64;

  StreamSubscription<void>? _dropSub;
  StreamSubscription<void>? _resumeSub;
  Timer? _retrySweep;

  /// Grace period between learning a frame was dropped and re-sending. It is
  /// also the discriminator: the relay names no frame, so anything still
  /// in-flight after a normal round trip is the plausible casualty, while
  /// healthy requests have already answered and are gone from the map.
  static const _retryGrace = Duration(milliseconds: 600);

  /// Bounds amplification — a re-send costs frames on a link that just proved
  /// it has none to spare. Counted across every re-send path, so a request
  /// cannot be revived alternately by a drop report and a lost head.
  static const _maxRetries = 2;

  /// How long a request may wait for its `tunnel:http-start`. Must stay ABOVE
  /// the bridge's `FETCH_HEAD_TIMEOUT_MS` (localhost-fetch.ts) so a slow dev
  /// server yields the bridge's 502 with the real error, never a phone-side
  /// TimeoutException that names nothing.
  static const kTunnelHeadTimeout = Duration(seconds: 30);

  /// How long a started body may go without a chunk. Re-armed per chunk, so it
  /// bounds silence rather than the body. Above the bridge's
  /// `FETCH_READ_IDLE_MS` so a stalled dev server yields the bridge's
  /// `end{error}` with the cause, and above one liveness tick so a lost credit
  /// heals before a live body is declared dead.
  static const kTunnelChunkIdleTimeout = Duration(seconds: 30);

  /// Relay-mode proxies, one per open tab, keyed by dev-server port. Local
  /// mode never populates this — the webview hits localhost directly.
  final Map<int, PreviewProxyServer> _proxyServers = {};

  /// Ports already weighed for auto-open — via a live [PortDetectedMessage]
  /// or a `ports:update` snapshot — so each port is only ever auto-opened
  /// ONCE per service lifetime. Without this, a port the user deliberately
  /// closed would pop back open on the next `ports:update` resync (reconnect,
  /// another port changing, a scheme flip), since the dev server is still
  /// there to report.
  final Set<int> _autoOpenConsidered = {};

  Stream<PreviewState> get stateStream => _stateController.stream;
  PreviewState get currentState => _state;

  String get projectId => session.projectId;

  PreviewService.fromSession(this.session, {this.checkoutId = 'main'}) {
    _heavySub = session.checkoutHeavyStream(checkoutId).listen(_onHeavyJson);
    _statusSub = session.checkoutStatusStream(checkoutId).listen(_onStatusJson);
    // Every tunneled body in flight across a (re)establishment is dead by
    // construction — the relay client cleared its queues at promotion and the
    // bridge aborted its own runs — so this reaps them at the moment the
    // session comes back rather than at the idle timer 30s later. Kept eager
    // (not gated behind [activate]): it sends nothing for a checkout with no
    // request in flight, so a background checkout costs it nothing — see
    // [ProjectSession.setActiveCheckouts].
    session.hydrateCheckout(
      checkoutId,
      _reestablishHydratorKey,
      _onReestablished,
    );
    _txSub = session.transport.messages.listen(_onTransportMessage);
    _dropSub = session.transport.droppedFrames.listen(
      (_) => _onFramesDropped(),
    );
  }

  static const _snapshotHydratorKey = 'preview:snapshot';
  static const _reestablishHydratorKey = 'preview:tunnel-reestablish';

  Future<void> _hydrateSnapshot() => session.sendForCheckout(
    checkoutId,
    createAbMessage('preview:snapshot:request', {}),
  );

  /// Registers the preview picture pull and subscribes the focus-resume
  /// re-drive. `preview:url` and `ports:update` are both change-driven, and a
  /// managed checkout's go out while its runtime is being prepared — BEFORE
  /// the session list that makes the app build this bundle — so an isolated
  /// session's preview and ports stayed empty until a port happened to open or
  /// close. Same reason (and same shape) as FileService's tree pull. As a
  /// hydrator it also re-pulls on every reconnect; the bridge answers with
  /// `preview:snapshot` and re-emits the detected ports alongside it. Only the
  /// checkout on screen carries this — see [ProjectSession.setActiveCheckouts].
  void activate() {
    if (_disposed) return;
    session.hydrateCheckout(checkoutId, _snapshotHydratorKey, _hydrateSnapshot);
    // A hydrator covers re-ESTABLISHMENT; a focus resume re-establishes nothing
    // and is the other window the agent suppresses in. `preview:url` dropped
    // there is remembered as undelivered agent-side, but the only thing that
    // drains that flag is the port re-emit behind this very request — so
    // without this pull a port that opened while the app was backgrounded
    // stays unknown to it for the life of the connection.
    _resumeSub ??= session.focusResumed.listen(
      (_) => detached(
        'PreviewService',
        'preview snapshot re-pull on focus resume',
        _hydrateSnapshot,
      ),
    );
  }

  void deactivate() {
    if (_disposed) return;
    session.unhydrateCheckout(checkoutId, _snapshotHydratorKey);
    unawaited(_resumeSub?.cancel());
    _resumeSub = null;
  }

  void _setState(PreviewState state) {
    if (_disposed) return;
    _state = state;
    _stateController.add(state);
  }

  void _onHeavyJson(Map<String, dynamic> json) {
    final parsed = parseAbMessage(json);
    if (parsed == null) return;
    _handle(parsed);
  }

  void _onStatusJson(Map<String, dynamic> json) {
    final parsed = parseAbMessage(json);
    if (parsed == null) return;
    _handle(parsed);
  }

  /// Direct transport subscription — picks up tunnel HTTP responses on the
  /// `preview` channel. The MessageRouter only forwards `control`-channel
  /// frames into heavy/status streams, so preview-channel frames must be
  /// caught here.
  void _onTransportMessage(InboundMessage msg) {
    if (msg.channel != 'preview') return;
    if (checkoutIdForEnvelope(msg.json) != checkoutId) return;
    final parsed = parseAbMessage(msg.json);
    if (parsed == null) return;
    _handle(parsed);
  }

  void _handle(Object message) {
    if (message is PortsUpdateMessage) {
      _handlePortsUpdate(message);
    } else if (message is PortDetectedMessage) {
      _handlePortDetected(message);
    } else if (message is PreviewSnapshotMessage) {
      _mergePreviewEntries(message.urls);
    } else if (message is PreviewUrlMessage) {
      _mergePreviewEntries([message.entry]);
    } else if (message is TunnelHttpStartMessage) {
      _handleTunnelStart(message);
    } else if (message is TunnelHttpChunkMessage) {
      _handleTunnelChunk(message);
    } else if (message is TunnelHttpEndMessage) {
      _handleTunnelEnd(message);
    } else if (message is TunnelWsDataMessage) {
      _handleWsData(message);
    } else if (message is TunnelWsCloseMessage) {
      _handleWsClose(message);
    }
  }

  // --- Message handlers ---

  void _handlePortsUpdate(PortsUpdateMessage msg) {
    _setState(_state.copyWith(ports: msg.ports));
    _autoOpenFromSnapshot(msg.ports);
  }

  /// A dev server was just detected. Silent ports remain listed without
  /// opening, and an ignored frame is rejected defensively. The FIRST tab of
  /// any kind (manual or detected) keeps focus; every later detection opens
  /// in the background so it never steals focus from what the user is already
  /// looking at.
  void _handlePortDetected(PortDetectedMessage msg) {
    if (isDemoProjectId(projectId)) return;
    _autoOpenConsidered.add(msg.port);
    final onDetect = msg.attributes.onDetect;
    if (onDetect != 'notify' && onDetect != 'openPreview') return;
    unawaited(
      openTab(msg.port, scheme: msg.scheme, focus: _state.tabs.isEmpty),
    );
  }

  /// Auto-open ports the bridge already knew about before this checkout's
  /// service subscribed — replayed via the `ports:update`/`preview:snapshot`
  /// hydration (see the constructor) rather than the live one-shot
  /// [PortDetectedMessage]. Without this, a dev server started before the
  /// preview panel was ever opened never fires the live event — the port
  /// would only ever reach [PreviewState.ports], leaving the user to pick it
  /// manually. Each port is weighed exactly once ([_autoOpenConsidered]); a
  /// port with no declared `onDetect` (terminal-detected only) defaults to
  /// 'notify', matching the bridge's own default for a declared one.
  void _autoOpenFromSnapshot(List<PortInfo> ports) {
    if (isDemoProjectId(projectId)) return;
    for (final port in ports) {
      if (!_autoOpenConsidered.add(port.port)) continue;
      final onDetect = port.onDetect ?? 'notify';
      if (onDetect != 'notify' && onDetect != 'openPreview') continue;
      unawaited(
        openTab(
          port.port,
          scheme: port.scheme ?? 'http',
          focus: _state.tabs.isEmpty,
        ),
      );
    }
  }

  /// Folds preview entries — a welcome-replayed `preview:snapshot` or a live
  /// `preview:url` push — into the port list.
  ///
  /// MERGE with the current list, never replace: preview entries only cover
  /// config-declared preview ports, while ports:update carries every detected
  /// port. On rebind both arrive in arbitrary order — a replace here would
  /// wipe detected ports whenever the preview entries land last.
  void _mergePreviewEntries(List<PreviewUrlEntry> entries) {
    final byPort = {for (final p in _state.ports) p.port: p};
    for (final e in entries) {
      final existing = byPort[e.port];
      byPort[e.port] = PortInfo(
        port: e.port,
        label: e.label ?? existing?.label,
        scheme: e.scheme ?? existing?.scheme,
        pid: existing?.pid,
        processName: existing?.processName,
      );
    }
    final ports = byPort.values.toList()
      ..sort((a, b) => a.port.compareTo(b.port));
    _setState(_state.copyWith(ports: ports));
  }

  // --- Tunneled HTTP responses ---

  /// The head, carrying body slice 0. A `last` start is the whole response in
  /// one frame — nearly every page asset — and completes without ever building
  /// a controller.
  void _handleTunnelStart(TunnelHttpStartMessage msg) {
    final entry = _pendingRequests[msg.requestId];
    if (entry == null) {
      _cancelUnknown(msg.requestId);
      return;
    }
    // A second start for a started body is a replay racing the live run; the
    // body it belongs to is already being served.
    if (entry.body != null) return;

    List<int> bytes;
    try {
      bytes = msg.data.isEmpty
          ? const <int>[]
          : decodeTunnelSlice(msg.data, msg.bodyEncoding);
    } catch (e) {
      _failHead(entry, TunnelStreamException(entry.requestId, 'undecodable start: $e'));
      _sendCancel(msg.requestId);
      return;
    }

    if (msg.last) {
      _pendingRequests.remove(entry.requestId);
      entry.head.complete(
        TunnelHttpResponse(
          requestId: msg.requestId,
          status: msg.status,
          headers: msg.headers,
          setCookies: msg.setCookies,
          body: bytes.isEmpty
              ? const Stream<List<int>>.empty()
              : Stream<List<int>>.value(bytes),
        ),
      );
      _statsCompleted++;
      _logIfSettled();
      return;
    }

    final controller = StreamController<List<int>>(
      onCancel: () => _onBodyCancelled(msg.requestId),
    );
    entry.body = _TunnelBody(controller);
    if (bytes.isNotEmpty) controller.add(bytes);
    _armIdle(entry);
    entry.head.complete(
      TunnelHttpResponse(
        requestId: msg.requestId,
        status: msg.status,
        headers: msg.headers,
        setCookies: msg.setCookies,
        body: controller.stream,
      ),
    );
  }

  void _handleTunnelChunk(TunnelHttpChunkMessage msg) {
    final entry = _pendingRequests[msg.requestId];
    if (entry == null) {
      _cancelUnknown(msg.requestId);
      return;
    }
    final body = entry.body;
    if (body == null) {
      _onHeadLost(entry);
      return;
    }
    if (msg.seq != body.nextSeq) {
      _abortBody(
        entry,
        'chunk ${msg.seq} arrived, expected ${body.nextSeq}',
      );
      return;
    }
    List<int> bytes;
    try {
      bytes = decodeTunnelSlice(msg.data, msg.bodyEncoding);
    } catch (e) {
      _abortBody(entry, 'undecodable chunk ${msg.seq}: $e');
      return;
    }
    body.controller.add(bytes);
    body.nextSeq++;
    _armIdle(entry);
  }

  void _handleTunnelEnd(TunnelHttpEndMessage msg) {
    final entry = _pendingRequests[msg.requestId];
    if (entry == null) {
      _cancelUnknown(msg.requestId);
      return;
    }
    final body = entry.body;
    if (body == null) {
      _onHeadLost(entry);
      return;
    }
    if (msg.error != null) {
      // The bridge has already ended its own run; a cancel would be a frame
      // spent telling it what it just told us.
      _abortBody(entry, msg.error!, sendCancel: false);
      return;
    }
    final received = body.nextSeq - 1;
    if (msg.chunks != received) {
      _abortBody(
        entry,
        'end after ${msg.chunks} chunk(s), received $received',
      );
      return;
    }
    body.idle?.cancel();
    _pendingRequests.remove(entry.requestId);
    unawaited(body.controller.close());
    _statsCompleted++;
    _logIfSettled();
  }

  /// A chunk or an end for an entry that never got its head. FIFO puts a
  /// `start` ahead of its own chunks, so this frame proves the start was
  /// dropped — and the relay reports a drop only to the frame's SENDER, so
  /// nothing else will ever tell us. Acted on with no grace: on a fast link
  /// chunk 1 lands milliseconds after the request.
  ///
  /// The re-send takes a FRESH requestId. The cancelled run still has up to a
  /// window in flight, arriving for longer than any grace on a mobile link; a
  /// fresh id is what makes those frames unknown rather than a second recovery
  /// or a body spliced out of two runs.
  void _onHeadLost(_InFlightRequest entry) {
    final oldId = entry.requestId;
    _pendingRequests.remove(oldId);
    _sendCancel(oldId);

    final method = entry.request.method.toUpperCase();
    if ((method == 'GET' || method == 'HEAD') &&
        entry.attempts < _maxRetries) {
      entry.request = entry.request.copyWith(requestId: _newRequestId());
      entry.attempts++;
      entry.sentAt = DateTime.now();
      _statsRetried++;
      // The same PendingReply, so the caller's head timer keeps running from
      // the original call — a recovery does not buy another 30s.
      _pendingRequests[entry.requestId] = entry;
      _sendTunnelRequest(entry.request);
      return;
    }
    _failHead(entry, TunnelStreamException(oldId, 'response head lost'));
  }

  /// One cancel per id we are not waiting on: a start nobody waits on is a
  /// re-fetch or a replay to stop, and a chunk for an id we re-keyed away or
  /// already finished is a run whose cancel the relay may have dropped.
  /// Answering it once stops that run at its next frame instead of letting it
  /// stream a whole body into the void.
  void _cancelUnknown(String id) {
    if (_cancelledIds.contains(id)) return;
    _sendCancel(id);
  }

  /// A fresh Timer per chunk, NOT a [PendingReply]: that one is non-resettable
  /// by design, which is right for a head that arrives once and wrong for a
  /// clock the next chunk must restart.
  void _armIdle(_InFlightRequest entry) {
    final body = entry.body;
    if (body == null) return;
    body.idle?.cancel();
    body.idle = Timer(entry.chunkIdleTimeout, () {
      _statsTimedOut++;
      _abortBody(entry, 'no chunk within ${entry.chunkIdleTimeout}');
    });
  }

  /// Fails a started body. The id is read off the ENTRY throughout — a re-key
  /// may have moved it since any caller captured a string.
  void _abortBody(
    _InFlightRequest entry,
    String reason, {
    bool sendCancel = true,
  }) {
    final id = entry.requestId;
    final body = entry.body;
    _pendingRequests.remove(id);
    body?.idle?.cancel();
    if (body != null) {
      body.controller.addError(TunnelStreamException(id, reason));
      unawaited(body.controller.close());
    }
    if (sendCancel) _sendCancel(id);
    AbLog.warn(
      'preview',
      'tunnel body aborted',
      fields: {
        'requestId': id,
        'reason': reason,
        if (body != null) 'chunksReceived': body.nextSeq - 1,
      },
    );
    _logIfSettled();
  }

  void _failHead(_InFlightRequest entry, Object error) {
    _pendingRequests.remove(entry.requestId);
    entry.head.fail(error);
    _logIfSettled();
  }

  /// The proxy stopped reading — the browser closed the tab or the connection
  /// died. Removing first is what keeps a COMPLETED body quiet: `onCancel`
  /// also fires after `close()` delivered done, and by then the entry is gone.
  void _onBodyCancelled(String id) {
    final entry = _pendingRequests.remove(id);
    if (entry == null) return;
    entry.body?.idle?.cancel();
    _sendCancel(id);
    _logIfSettled();
  }

  /// Best-effort, idempotent, never awaited — the same shape as
  /// [_sendTunnelRequest]. Deliberately NOT gated on `_disposed`: dispose sets
  /// that flag before its first await, so a gate here would make every cancel
  /// on the dispose path dead code and leave each body in flight still
  /// streaming from the bridge.
  ///
  /// Every call site has just stopped waiting on [id], so this is also where
  /// the id is remembered: whatever the cancelled run still has in flight is
  /// then answered by nothing rather than by a cancel per frame.
  void _sendCancel(String id) {
    _cancelledIds.add(id);
    if (_cancelledIds.length > _maxCancelledIds) {
      _cancelledIds.remove(_cancelledIds.first);
    }
    unawaited(
      session.transport.send({
        'type': 'tunnel:http-cancel',
        'requestId': id,
        'checkoutId': checkoutId,
      }, channel: 'preview'),
    );
  }

  String _newRequestId() => const Uuid().v4();

  // --- Tunnel instrumentation ---
  //
  // The denominator for a drop count: a drop is only meaningful against the
  // number of requests the load actually issued, and nothing else on either
  // side of the tunnel counts them. A "window" is one settling of the in-flight
  // map, which for a preview is one page load and its subresources.

  int _statsIssued = 0;
  int _statsCompleted = 0;
  int _statsRetried = 0;
  int _statsTimedOut = 0;
  DateTime? _statsWindowStart;

  void _logIfSettled() {
    if (_pendingRequests.isNotEmpty) return;
    final start = _statsWindowStart;
    if (start == null) return;
    AbLog.info(
      'preview',
      'tunnel window settled',
      fields: {
        'requests': _statsIssued,
        'completed': _statsCompleted,
        'retried': _statsRetried,
        'timedOut': _statsTimedOut,
        'elapsedMs': DateTime.now().difference(start).inMilliseconds,
      },
    );
    _statsWindowStart = null;
    _statsIssued = 0;
    _statsCompleted = 0;
    _statsRetried = 0;
    _statsTimedOut = 0;
  }

  // --- Dropped-frame recovery ---

  /// The relay dropped a routed frame. It identifies neither the frame nor the
  /// direction, so a request whose reply never arrives is indistinguishable
  /// from one that is merely slow — hence [_retryGrace] before acting, and
  /// GET/HEAD only. A re-send that is not safe to repeat is worse than the
  /// head timeout it would save.
  ///
  /// A request whose head has landed is never re-sent: bytes may already be in
  /// the browser and nothing can be spliced onto a partly delivered body. A
  /// drop inside a body surfaces through the `seq` check or the idle timer as
  /// a truncated response instead.
  void _onFramesDropped() {
    // A burst of drops arrives as a burst of errors; one sweep covers them all.
    _retrySweep ??= Timer(_retryGrace, () {
      _retrySweep = null;
      _resendStalledRequests();
    });
  }

  void _resendStalledRequests() {
    if (_disposed) return;
    final now = DateTime.now();
    for (final entry in _pendingRequests.values.toList()) {
      final method = entry.request.method.toUpperCase();
      if (method != 'GET' && method != 'HEAD') continue;
      if (entry.body != null) continue;
      if (entry.attempts >= _maxRetries) continue;
      // The sweep is scheduled off the DROP, not off any one request, so
      // without this the map's youngest entries — a page load keeps adding
      // them — are duplicated while still well inside a normal round trip.
      if (now.difference(entry.sentAt) < _retryGrace) continue;
      entry.attempts++;
      entry.sentAt = now;
      _statsRetried++;
      _sendTunnelRequest(entry.request);
    }
  }

  void _sendTunnelRequest(TunnelHttpRequest request) {
    unawaited(
      session.transport.send({
        ...request.toJson(),
        'checkoutId': checkoutId,
      }, channel: 'preview'),
    );
  }

  // --- Public methods ---

  /// Sends [request] and completes as soon as its HEAD lands. The returned
  /// [TunnelHttpResponse.body] then streams the rest, bounded by
  /// [chunkIdleTimeout] per chunk rather than by one clock over the whole body
  /// — a 100 MB download must not be killed for taking longer than a head.
  Future<TunnelHttpResponse> proxyRequest(
    TunnelHttpRequest request, {
    Duration timeout = kTunnelHeadTimeout,
    Duration chunkIdleTimeout = kTunnelChunkIdleTimeout,
  }) {
    // De-registered by the entry's CURRENT id, not the one this call named: a
    // lost-head recovery re-keys the entry under a fresh id while the same
    // head timer runs, and removing the original key would leave the entry in
    // the map forever with nothing left to complete it.
    late final _InFlightRequest entry;
    final pending = session.newPending<TunnelHttpResponse>(
      timeout: timeout,
      onAbandon: () => _pendingRequests.remove(entry.requestId),
      onTimeout: () {
        _statsTimedOut++;
        // The bridge may still be fetching for an id nothing will read.
        _sendCancel(entry.requestId);
        _logIfSettled();
      },
      timeoutError: () => TimeoutException('Request timed out', timeout),
    );
    entry = _InFlightRequest(request, pending, chunkIdleTimeout);
    _pendingRequests[request.requestId] = entry;
    _statsWindowStart ??= DateTime.now();
    _statsIssued++;

    _sendTunnelRequest(request);

    return pending.future;
  }

  /// A fresh E2E session: the relay client cleared its queues and the bridge
  /// aborted every in-flight run, so a started body can never be completed.
  /// A headless request is re-sent under the SAME id — the bridge replays it
  /// from its outbox, fetches it fresh, or joins a run still going, which is
  /// the one place the same-id join is what we want.
  Future<void> _onReestablished() async {
    for (final entry in _pendingRequests.values.toList()) {
      if (entry.body != null) {
        // Cancelling is redundant when the bridge's own peer hook fired, but
        // it is one small frame and the only thing that stops the run if it
        // did not.
        _abortBody(entry, 'session re-established mid-body');
        continue;
      }
      final method = entry.request.method.toUpperCase();
      if (method != 'GET' && method != 'HEAD') continue;
      if (entry.attempts >= _maxRetries) continue;
      entry.attempts++;
      entry.sentAt = DateTime.now();
      _statsRetried++;
      _sendTunnelRequest(entry.request);
    }
  }

  PreviewTab? _tabByPort(int port) {
    for (final tab in _state.tabs) {
      if (tab.port == port) return tab;
    }
    return null;
  }

  /// Opens [port] as a tab, or focuses it if already open (a no-op beyond
  /// that — no rebuild, no reload — unless [scheme] actually changed). In
  /// relay mode binds a dedicated local proxy to the exact [port]; if that
  /// port is taken returns [SelectPortResult.portInUse] WITHOUT changing
  /// state, so the UI can confirm a fallback via [selectPortWithFallback].
  /// [focus] false opens the tab in the background (used for auto-open on
  /// detection) without moving [PreviewState.activeTabId]. [path] lands a
  /// FRESHLY opened tab somewhere other than the origin (e.g. a pasted link
  /// to `localhost:3000/dashboard`); it's ignored when [port] is already
  /// open — reusing a live tab must never yank it to a different page.
  Future<SelectPortResult> openTab(
    int port, {
    String scheme = 'http',
    bool focus = true,
    String path = '/',
  }) {
    final existing = _tabByPort(port);
    if (existing != null && existing.scheme == scheme) {
      if (focus) setActiveTab(port);
      return Future.value(SelectPortResult.opened);
    }
    return _open(
      port,
      scheme: scheme,
      allowFallback: false,
      focus: focus,
      path: path,
    );
  }

  /// Resolves an address-bar navigation through the tab's actual origin,
  /// including an ephemeral proxy port when the target is remote.
  Uri? existingTabNavigationUrl(
    int port, {
    required String scheme,
    required String path,
  }) {
    final tab = _tabByPort(port);
    if (tab == null || tab.scheme != scheme || tab.currentUrl == null) {
      return null;
    }
    final origin = Uri.parse(tab.currentUrl!).origin;
    return Uri.parse('$origin$path');
  }

  /// Confirmed retry after a [SelectPortResult.portInUse]: binds a random
  /// local port and rewrites the forwarded Host to `localhost:<port>`.
  Future<void> selectPortWithFallback(
    int port, {
    String scheme = 'http',
    bool focus = true,
    String path = '/',
  }) async {
    await _open(
      port,
      scheme: scheme,
      allowFallback: true,
      focus: focus,
      path: path,
    );
  }

  Future<SelectPortResult> _open(
    int port, {
    required String scheme,
    required bool allowFallback,
    required bool focus,
    required String path,
  }) async {
    // '/' is the implicit default everywhere this is built — keep it out of
    // the URL so an untouched open still reads as the bare origin (matches
    // what every existing caller/test expects).
    final suffix = path == '/' ? '' : path;

    // Local mode: app and dev server share the host, so the WebView can hit
    // localhost:port directly (over the target scheme). Skip the
    // tunnel-fronting proxy entirely.
    if (session.transport.isLocal) {
      _upsertTab(
        PreviewTab(
          port: port,
          scheme: scheme,
          localProxyPort: port,
          currentUrl: '$scheme://localhost:$port$suffix',
        ),
        focus: focus,
      );
      return SelectPortResult.opened;
    }

    // A scheme change on an already-open port rebinds that port's proxy —
    // every other port's proxy is a different map entry and is untouched.
    final previousServer = _proxyServers.remove(port);
    await previousServer?.stop();

    final server = PreviewProxyServer(
      targetPort: port,
      targetScheme: scheme,
      onRequest: proxyRequest,
      onWebSocketConnect: (channel, path, headers) =>
          _onWsConnect(port, scheme, channel, path, headers),
    );

    final int localPort;
    try {
      localPort = await server.start(allowFallback: allowFallback);
    } on PortInUseException {
      await server.stop();
      return SelectPortResult.portInUse;
    }

    _proxyServers[port] = server;

    // The proxy fronts the webview over plain HTTP regardless of [scheme];
    // the bridge applies [scheme] when reaching the dev server. So the webview
    // origin is always http://localhost:<localPort>.
    _upsertTab(
      PreviewTab(
        port: port,
        scheme: scheme,
        localProxyPort: localPort,
        currentUrl: 'http://localhost:$localPort$suffix',
      ),
      focus: focus,
    );
    return SelectPortResult.opened;
  }

  void _upsertTab(PreviewTab tab, {required bool focus}) {
    final tabs = [
      for (final t in _state.tabs)
        if (t.port != tab.port) t,
      tab,
    ];
    _setState(
      _state.copyWith(
        tabs: tabs,
        activeTabId: focus ? tab.port : _state.activeTabId,
      ),
    );
  }

  /// Focuses an already-open tab. Pure state flip — no network/proxy work —
  /// which is what guarantees switching tabs never reloads one.
  void setActiveTab(int port) {
    if (_tabByPort(port) == null) return;
    if (_state.activeTabId == port) return;
    _setState(_state.copyWith(activeTabId: port));
  }

  /// Closes [port]'s tab, releasing its proxy (relay mode; a no-op in local
  /// mode, which never binds one). Reassigns the active tab to the first
  /// remaining one, or clears it if none remain.
  Future<void> closeTab(int port) async {
    final server = _proxyServers.remove(port);
    await server?.stop();

    final tabs = [
      for (final t in _state.tabs)
        if (t.port != port) t,
    ];
    final wasActive = _state.activeTabId == port;
    _setState(
      _state.copyWith(
        tabs: tabs,
        activeTabId: wasActive && tabs.isNotEmpty
            ? tabs.first.port
            : _state.activeTabId,
        clearActiveTabId: wasActive && tabs.isEmpty,
      ),
    );
  }

  void refreshPreview() {}

  // --- WebSocket tunnel ---

  void _onWsConnect(
    int port,
    String scheme,
    WebSocketChannel channel,
    String path,
    Map<String, String> headers,
  ) {
    final tunnelId = const Uuid().v4();
    final outbound = _WsOutboundQueue(
      session.transport,
      onAbort: (reason) {
        AbLog.warn(
          'preview',
          'ws tunnel aborted',
          fields: {'tunnelId': tunnelId, 'port': port, 'reason': reason},
        );
        // Close the local socket only. The `onDone` below is what removes the
        // tunnel and tells the bridge, and closing here is what triggers it —
        // the previewed page then sees a real close event and reconnects,
        // instead of holding an open socket nothing will ever answer.
        final tunnel = _activeWsTunnels[tunnelId];
        if (tunnel == null) return;
        detached(
          'preview',
          'ws tunnel abort close',
          () => tunnel.channel.sink.close(),
        );
      },
    );

    outbound.send(
      createAbMessage('tunnel:ws-open', {
        'tunnelId': tunnelId,
        'port': port,
        'scheme': scheme,
        'path': path,
        'headers': headers,
        'checkoutId': checkoutId,
      }),
    );

    final sub = channel.stream.listen(
      (data) {
        if (data is String) {
          outbound.send(
            createAbMessage('tunnel:ws-data', {
              'tunnelId': tunnelId,
              'data': data,
              'checkoutId': checkoutId,
            }),
          );
          return;
        }

        outbound.send(
          createAbMessage('tunnel:ws-data', {
            'tunnelId': tunnelId,
            'data': base64Encode(data as List<int>),
            'binary': true,
            'checkoutId': checkoutId,
          }),
        );
      },
      onDone: () {
        // Null when this tunnel was already torn down via _handleWsClose
        // (the bridge/upstream side closed first) — that path already told
        // the bridge, so closing our own sink here must not tell it again.
        if (_activeWsTunnels.remove(tunnelId) == null) return;
        outbound.sendClose(
          createAbMessage('tunnel:ws-close', {
            'tunnelId': tunnelId,
            'checkoutId': checkoutId,
          }),
        );
      },
    );

    _activeWsTunnels[tunnelId] = _WsTunnel(channel, sub);
  }

  /// A frame the upstream dev-server sent, relayed here by the bridge —
  /// forward it into the local socket the previewed page's own WebSocket is
  /// reading from.
  void _handleWsData(TunnelWsDataMessage msg) {
    final tunnel = _activeWsTunnels[msg.tunnelId];
    if (tunnel == null) return;
    tunnel.channel.sink.add(msg.binary ? base64Decode(msg.data) : msg.data);
  }

  /// The bridge's upstream connection closed — mirror it onto the local
  /// socket so the previewed page's WebSocket client sees a real close event
  /// (and can run its own reconnect logic) rather than hanging silently.
  /// Removed from the map BEFORE closing, so the `onDone` callback above
  /// (which this close triggers) sees it already gone and stays quiet.
  void _handleWsClose(TunnelWsCloseMessage msg) {
    final tunnel = _activeWsTunnels.remove(msg.tunnelId);
    if (tunnel == null) return;
    unawaited(tunnel.sub.cancel());
    final code = _forwardableCloseCode(msg.code);
    unawaited(
      tunnel.channel.sink.close(
        code,
        code == null ? null : _forwardableCloseReason(msg.reason),
      ),
    );
  }

  /// The browser-facing socket is a `web_socket_channel` sink, whose
  /// `checkCloseCode` accepts only 1000 and the private 3000-4999 range and
  /// throws an `ArgumentError` for anything else — narrower than the RFC and
  /// narrower than dart:io's own rule. A code it would refuse closes the socket
  /// bare instead: the page still sees a real close event it can reconnect
  /// from, which is the part that matters, and an exception thrown out of this
  /// handler would take the whole transport subscription with it.
  static int? _forwardableCloseCode(int? code) {
    if (code == null) return null;
    return code == 1000 || (code >= 3000 && code <= 4999) ? code : null;
  }

  /// The same sink caps a close reason at 123 UTF-8 bytes, so a longer one is
  /// dropped rather than thrown.
  static String? _forwardableCloseReason(String? reason) {
    if (reason == null) return null;
    return utf8ByteLength(reason) <= 123 ? reason : null;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    // Before the first await, like FileService/ConfigService: the awaits below
    // can throw (and this dispose runs unawaited from _sweepCheckouts), and a
    // hydrator left registered re-requests a snapshot for a dead checkout on
    // every reconnect for the rest of the session.
    session.unhydrateCheckout(checkoutId, _snapshotHydratorKey);
    session.unhydrateCheckout(checkoutId, _reestablishHydratorKey);

    _retrySweep?.cancel();
    _retrySweep = null;

    // Before the proxies stop, and never in place of this loop: a stalled
    // body's subscription only learns the socket died on its next write, so
    // `HttpServer.close(force: true)` alone never reaches its `onCancel` and
    // the bridge would keep streaming a body nobody will read.
    for (final entry in _pendingRequests.values.toList()) {
      if (entry.body != null) {
        _abortBody(entry, 'service disposed');
      } else {
        entry.head.fail(TimeoutException('Service disposed'));
      }
    }
    _pendingRequests.clear();

    for (final server in _proxyServers.values) {
      await server.stop();
    }
    _proxyServers.clear();

    for (final tunnel in _activeWsTunnels.values) {
      await tunnel.sub.cancel();
      await tunnel.channel.sink.close();
    }
    _activeWsTunnels.clear();

    await _heavySub?.cancel();
    _heavySub = null;
    await _statusSub?.cancel();
    _statusSub = null;
    await _txSub?.cancel();
    _txSub = null;
    await _dropSub?.cancel();
    _dropSub = null;
    await _resumeSub?.cancel();
    _resumeSub = null;

    await _stateController.close();
  }
}

class _InFlightRequest {
  /// NOT final: a lost head re-keys the entry under a fresh requestId, and
  /// [requestId] is read off this request everywhere so nothing can hold the
  /// stale one.
  TunnelHttpRequest request;
  final PendingReply<TunnelHttpResponse> head;
  final Duration chunkIdleTimeout;

  /// Non-null once a non-`last` start has arrived. A started request is
  /// streaming and is never re-sent.
  _TunnelBody? body;

  /// Every re-send on any path, so the cap bounds them together.
  int attempts = 0;

  /// When the latest attempt went out — the age the retry sweep judges against.
  DateTime sentAt = DateTime.now();

  String get requestId => request.requestId;

  _InFlightRequest(this.request, this.head, this.chunkIdleTimeout);
}

/// The streaming half of a response: the controller the proxy reads bytes
/// from, the per-chunk idle clock, and the seq the next chunk must carry.
class _TunnelBody {
  final StreamController<List<int>> controller;
  Timer? idle;

  /// The start is slice 0, so chunks begin at 1.
  int nextSeq = 1;

  _TunnelBody(this.controller);
}

/// One active WS tunnel — the local [channel] a previewed page's own
/// WebSocket connects through, and the [sub] forwarding its outbound frames
/// to the bridge. Held together because closing the tunnel (either
/// direction) needs both: cancel the forwarding subscription and close the
/// local socket so the page's WebSocket client sees a real close event.
class _WsTunnel {
  final WebSocketChannel channel;
  final StreamSubscription sub;

  _WsTunnel(this.channel, this.sub);
}

/// One FIFO for every app-to-bridge frame belonging to a browser WebSocket.
///
/// Transport sealing is asynchronous. Independent fire-and-forget sends can
/// otherwise put the browser's first SignalR frame ahead of `tunnel:ws-open`,
/// or reorder later binary frames. WebSocket application protocols require the
/// byte stream to retain its original order.
///
/// Ordering is only half the job: the frames must also arrive. A send with no
/// session keys installed completes SUCCESSFULLY and delivers nothing, so a
/// lost `tunnel:ws-open` would otherwise leave the browser's socket waiting
/// forever on a tunnel the bridge never heard of. [onAbort] fires on any frame
/// this queue cannot vouch for, and the tunnel is closed rather than left open
/// and mute.
class _WsOutboundQueue {
  _WsOutboundQueue(this._transport, {required this.onAbort});

  final AgentTransport _transport;
  final void Function(String reason) onAbort;

  Future<void> _tail = Future<void>.value();
  int _queuedFrames = 0;
  int _queuedBytes = 0;
  bool _aborted = false;

  /// Same ceilings the bridge applies to its own pre-open buffer, measured in
  /// UTF-8 bytes as the bridge measures them. Serializing on the transport
  /// means a slow link builds the backlog HERE, and a browser streaming into a
  /// wedged tunnel would otherwise grow it without limit.
  ///
  /// This cap is also what keeps a browser frame from ever reaching
  /// `kMaxTransferBytes`, where `sendOnStream` drops it with no signal the
  /// caller can see. A frame this queue refuses aborts the tunnel, closes the
  /// browser socket and (via `onDone` → `sendClose`) releases the bridge's
  /// upstream, so both directions end.
  static const _maxQueuedFrames = 64;
  static const _maxQueuedBytes = 1024 * 1024;
  /// A send resolves at hand-off to the socket, so this bounds the wait for
  /// the channel ahead of this frame. Hitting it aborts the tunnel, which is
  /// the right surface for a preview channel that has stopped draining: a WS
  /// tunnel with a hole in it is worse than one the browser can re-open.
  static const _sendTimeout = Duration(seconds: 10);

  /// How long the close frame waits its turn. Ordering matters least here:
  /// a queue that has not drained has already lost the data the close would
  /// follow, and the bridge's upstream dev-server socket stays open until it
  /// arrives.
  static const _closeGrace = Duration(seconds: 2);

  void send(Map<String, dynamic> message) {
    if (_aborted) return;
    final bytes = utf8ByteLength((message['data'] as String?) ?? '');
    if (_queuedFrames >= _maxQueuedFrames ||
        _queuedBytes + bytes > _maxQueuedBytes) {
      _abort('outbound queue limit reached');
      return;
    }
    _queuedFrames++;
    _queuedBytes += bytes;
    _tail = _tail.then((_) => _sendOne(message, bytes));
  }

  /// Enqueue the tunnel's close, bounded by [_closeGrace] rather than by the
  /// backlog ahead of it. Ignores [_aborted]: the bridge is owed this frame
  /// precisely when the tunnel died badly.
  void sendClose(Map<String, dynamic> message) {
    final ahead = _tail;
    detached('preview', 'ws tunnel close', () async {
      await ahead.timeout(_closeGrace, onTimeout: () {}).catchError((_) {});
      await _transport.send(message, channel: 'preview').timeout(_sendTimeout);
    });
  }

  /// Never throws — the chain in [send] carries no error handler of its own,
  /// and one rejection there would strand every frame behind it.
  Future<void> _sendOne(Map<String, dynamic> message, int bytes) async {
    try {
      if (_aborted) return;
      // Not `currentState == connected`: a relay stream stays connected across
      // a session-down window where the send returns normally and drops.
      if (!_transport.isEstablished) {
        _abort('transport not established');
        return;
      }
      await _transport.send(message, channel: 'preview').timeout(_sendTimeout);
    } catch (err) {
      _abort('$err');
    } finally {
      _queuedFrames--;
      _queuedBytes -= bytes;
    }
  }

  void _abort(String reason) {
    if (_aborted) return;
    _aborted = true;
    onAbort(reason);
  }
}
