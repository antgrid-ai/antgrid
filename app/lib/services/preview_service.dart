import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';

import '../demo/demo_identity.dart';
import '../models/preview_models.dart';
import '../models/ab_message.dart';
import '../project/project_session.dart';
import '../util/ab_log.dart';
import '../util/detached.dart';
import 'preview_proxy_server.dart';

/// Outcome of [PreviewService.selectPort]. `portInUse` means the exact local
/// port couldn't be bound and the caller should confirm a fallback before
/// retrying via [PreviewService.selectPortWithFallback].
enum SelectPortResult { opened, portInUse }

/// Per-project preview service. Heavy-tier primary (preview:snapshot,
/// preview:url) with a status-tier subscription for `ports:update`. Tunneled
/// HTTP/WS traffic rides its own native stream per request/socket
/// (`AgentTransport.openTunnelHttp`/`openTunnelWs`) and never touches
/// heavy/status/control — see [proxyRequest] and [_onWsConnect].
///
/// Constructed at [ProjectSession] creation time. Lifetime is bound to the
/// session; calling [dispose] cancels all subscriptions and closes the
/// state controller.
class PreviewService {
  final ProjectSession session;
  final String checkoutId;

  StreamSubscription<Map<String, dynamic>>? _heavySub;
  StreamSubscription<Map<String, dynamic>>? _statusSub;
  bool _disposed = false;

  final _stateController = StreamController<PreviewState>.broadcast();
  PreviewState _state = const PreviewState();

  /// Every HTTP exchange currently open, so [dispose] can cancel them and a
  /// settled window can be logged.
  final Set<TunnelHttpExchange> _liveExchanges = {};

  /// Every WS tunnel currently open, keyed by tunnelId, so [dispose] can close
  /// them all with 1001.
  final Map<String, _WsTunnel> _activeWsTunnels = {};

  /// How long a request may wait for its `tunnel:http-head`. Must stay ABOVE
  /// the bridge's `FETCH_HEAD_TIMEOUT_MS` (localhost-fetch.ts) so a slow dev
  /// server yields the bridge's 502 with the real error, never a phone-side
  /// TimeoutException that names nothing.
  static const kTunnelHeadTimeout = Duration(seconds: 30);

  /// How long a started body may go without a record. Re-armed per record, so
  /// it bounds silence rather than the body. Above the bridge's
  /// `FETCH_READ_IDLE_MS` so a stalled dev server yields the bridge's own
  /// failure with the cause, and above one liveness tick so a lost credit
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
  }

  static const _snapshotHydratorKey = 'preview:snapshot';

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

  StreamSubscription<void>? _resumeSub;

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

  void _handle(Object message) {
    if (message is PortsUpdateMessage) {
      _handlePortsUpdate(message);
    } else if (message is PortDetectedMessage) {
      _handlePortDetected(message);
    } else if (message is PreviewSnapshotMessage) {
      _mergePreviewEntries(message.urls);
    } else if (message is PreviewUrlMessage) {
      _mergePreviewEntries([message.entry]);
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

  // --- Tunnel instrumentation ---
  //
  // The denominator for a drop count: a drop is only meaningful against the
  // number of requests the load actually issued, and nothing else on either
  // side of the tunnel counts them. A "window" is one settling of the
  // in-flight set, which for a preview is one page load and its subresources.

  int _statsIssued = 0;
  int _statsCompleted = 0;
  int _statsTimedOut = 0;
  DateTime? _statsWindowStart;

  void _logIfSettled() {
    if (_liveExchanges.isNotEmpty) return;
    final start = _statsWindowStart;
    if (start == null) return;
    AbLog.info(
      'preview',
      'tunnel window settled',
      fields: {
        'requests': _statsIssued,
        'completed': _statsCompleted,
        'timedOut': _statsTimedOut,
        'elapsedMs': DateTime.now().difference(start).inMilliseconds,
      },
    );
    _statsWindowStart = null;
    _statsIssued = 0;
    _statsCompleted = 0;
    _statsTimedOut = 0;
  }

  // --- Public methods ---

  /// Sends [request] on its own tunnel stream and completes as soon as its
  /// head lands. The returned [TunnelHttpResponse.body] then streams the
  /// rest, bounded by [chunkIdleTimeout] per record rather than by one clock
  /// over the whole body — a 100 MB download must not be killed for taking
  /// longer than a head.
  Future<TunnelHttpResponse> proxyRequest(
    TunnelHttpRequest request, {
    Duration timeout = kTunnelHeadTimeout,
    Duration chunkIdleTimeout = kTunnelChunkIdleTimeout,
  }) async {
    _statsWindowStart ??= DateTime.now();
    _statsIssued++;

    final exchange = session.transport.openTunnelHttp(
      requestId: request.requestId,
      checkoutId: checkoutId,
      head: request.toHeadJson(),
      bodyLength: request.bodyLength,
      body: request.body,
    );
    _liveExchanges.add(exchange);

    final TunnelHttpHead head;
    try {
      head = await exchange.head.timeout(timeout);
    } on TimeoutException {
      _statsTimedOut++;
      exchange.cancel();
      _liveExchanges.remove(exchange);
      _logIfSettled();
      rethrow;
    } on TunnelExchangeFailure catch (e) {
      _liveExchanges.remove(exchange);
      _logIfSettled();
      throw TunnelStreamException(request.requestId, e.code);
    }

    final bodyController = StreamController<List<int>>(
      onCancel: exchange.cancel,
    );
    Timer? idle;
    void armIdle() {
      idle?.cancel();
      idle = Timer(chunkIdleTimeout, () {
        _statsTimedOut++;
        exchange.cancel();
      });
    }

    // Guards every terminal path below against firing twice: the upstream's
    // own `onDone`/`onError` and a cancel triggered elsewhere could otherwise
    // both try to settle this same listener.
    var settled = false;
    late final StreamSubscription<Uint8List> bodySub;

    void settle() {
      if (settled) return;
      settled = true;
      idle?.cancel();
      unawaited(bodySub.cancel());
      _liveExchanges.remove(exchange);
      _logIfSettled();
    }

    armIdle();
    bodySub = exchange.body.listen(
      (chunk) {
        armIdle();
        bodyController.add(chunk);
      },
      onDone: () {
        settle();
        _statsCompleted++;
        unawaited(bodyController.close());
      },
      onError: (Object error) {
        settle();
        bodyController.addError(
          TunnelStreamException(
            request.requestId,
            error is TunnelExchangeFailure ? error.code : '$error',
          ),
        );
        unawaited(bodyController.close());
      },
    );

    return TunnelHttpResponse(
      requestId: request.requestId,
      status: head.status,
      headers: head.headers,
      setCookies: head.setCookies,
      body: bodyController.stream,
    );
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
    final tunnel = session.transport.openTunnelWs(
      tunnelId: tunnelId,
      checkoutId: checkoutId,
      open: {
        'type': 'tunnel:ws-open',
        'port': port,
        'scheme': scheme,
        'path': path,
        'headers': headers,
      },
    );

    final outbound = _WsOutboundQueue(
      tunnel,
      onAbort: (reason) {
        AbLog.warn(
          'preview',
          'ws tunnel aborted',
          fields: {'tunnelId': tunnelId, 'port': port, 'reason': reason},
        );
        tunnel.abort();
      },
    );

    final browserSub = channel.stream.listen(
      (data) {
        if (data is String) {
          outbound.send(
            TunnelWsFrame(
              binary: false,
              bytes: Uint8List.fromList(utf8.encode(data)),
            ),
          );
          return;
        }
        outbound.send(
          TunnelWsFrame(binary: true, bytes: Uint8List.fromList(data as List<int>)),
        );
      },
      onDone: outbound.close,
    );

    final framesSub = tunnel.frames.listen((frame) {
      channel.sink.add(frame.binary ? frame.bytes : utf8.decode(frame.bytes));
    });

    _activeWsTunnels[tunnelId] = _WsTunnel(tunnel, channel, browserSub, framesSub);

    unawaited(
      tunnel.done.then((end) {
        // Null when this tunnel was already torn down elsewhere (dispose) —
        // that path already closes the browser socket, so this must not do
        // it a second time.
        if (_activeWsTunnels.remove(tunnelId) == null) return;
        unawaited(browserSub.cancel());
        unawaited(framesSub.cancel());
        int? code;
        String? reason;
        if (end case TunnelWsClosedByPeer(
          code: final peerCode,
          reason: final peerReason,
        )) {
          code = _forwardableCloseCode(peerCode);
          reason = code == null ? null : _forwardableCloseReason(peerReason);
        } else if (end case TunnelWsFailed(:final failure)) {
          AbLog.warn(
            'preview',
            'ws tunnel failed',
            fields: {'tunnelId': tunnelId, 'port': port, 'code': failure.code},
          );
        }
        detached(
          'preview',
          'ws tunnel close forward',
          () => channel.sink.close(code, reason),
        );
      }),
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

    // Cancels rather than awaits: cancel()/close() settle their exchange's own
    // head/body/done asynchronously (see tunnel_stream.dart), and this loop
    // only needs to have asked, not to have watched every one finish.
    for (final exchange in _liveExchanges.toList()) {
      exchange.cancel();
    }
    _liveExchanges.clear();

    // Before the browser channels stop, and never in place of it: closing the
    // TunnelWsChannel alone tells the bridge, but leaves the previewed page's
    // socket open until the proxy server below is force-closed underneath it.
    for (final t in _activeWsTunnels.values) {
      t.tunnel.close(code: 1001, reason: 'preview service disposed');
      unawaited(t.browserSub.cancel());
      unawaited(t.framesSub.cancel());
      unawaited(t.browser.sink.close());
    }
    _activeWsTunnels.clear();

    for (final server in _proxyServers.values) {
      await server.stop();
    }
    _proxyServers.clear();

    await _heavySub?.cancel();
    _heavySub = null;
    await _statusSub?.cancel();
    _statusSub = null;
    await _resumeSub?.cancel();
    _resumeSub = null;

    await _stateController.close();
  }
}

/// One active WS tunnel — the bridge-facing [tunnel] and the local [browser]
/// channel a previewed page's own WebSocket connects through, plus both
/// forwarding subscriptions. Held together so [PreviewService.dispose] can
/// tear down every side of a still-open tunnel without waiting on [tunnel]'s
/// own `done` to cascade there.
class _WsTunnel {
  final TunnelWsChannel tunnel;
  final WebSocketChannel browser;
  final StreamSubscription<dynamic> browserSub;
  final StreamSubscription<TunnelWsFrame> framesSub;

  _WsTunnel(this.tunnel, this.browser, this.browserSub, this.framesSub);
}

/// One FIFO for every browser-to-bridge frame belonging to one WS tunnel.
///
/// [TunnelWsChannel.send] already serializes in call order (tunnel_stream.dart),
/// so this queue's job is purely the ceilings: a browser streaming into a
/// wedged tunnel must not grow its backlog without limit, and a frame over
/// either ceiling — or a `false` from [TunnelWsChannel.send] — aborts the
/// tunnel outright rather than leaving it half-drained.
class _WsOutboundQueue {
  _WsOutboundQueue(this._channel, {required this.onAbort});

  final TunnelWsChannel _channel;
  final void Function(String reason) onAbort;

  Future<void> _tail = Future<void>.value();
  int _queuedFrames = 0;
  int _queuedBytes = 0;
  bool _aborted = false;

  /// Same ceilings this queue has always applied, now measured directly on
  /// the frame's raw bytes (no more JSON/base64 envelope to measure through).
  ///
  /// This cap is also what keeps a browser frame from ever reaching
  /// [kStreamTunnelDataMaxBytes], where the channel resets rather than
  /// signals a refusal the caller can see. A frame this queue refuses aborts
  /// the tunnel, closing the browser socket (via [onAbort] -> `abort()` ->
  /// `done`) so both directions end.
  static const _maxQueuedFrames = 64;
  static const _maxQueuedBytes = 1024 * 1024;

  /// A send resolves once the channel accepts or refuses it, so this bounds
  /// the wait for the channel ahead of this frame. Hitting it aborts the
  /// tunnel, which is the right surface for one that has stopped draining: a
  /// WS tunnel with a hole in it is worse than one the browser can re-open.
  static const _sendTimeout = Duration(seconds: 10);

  /// How long the close waits its turn. Ordering matters least here: a queue
  /// that has not drained has already lost the data the close would follow.
  static const _closeGrace = Duration(seconds: 2);

  void send(TunnelWsFrame frame) {
    if (_aborted) return;
    final bytes = frame.bytes.length;
    if (_queuedFrames >= _maxQueuedFrames ||
        _queuedBytes + bytes > _maxQueuedBytes) {
      _abort('outbound queue limit reached');
      return;
    }
    _queuedFrames++;
    _queuedBytes += bytes;
    _tail = _tail.then((_) => _sendOne(frame, bytes));
  }

  /// Closes the tunnel once every already-queued frame has had its turn (or
  /// [_closeGrace] has passed, whichever comes first). Ignores [_aborted]:
  /// [TunnelWsChannel.close] is idempotent, so a call after an abort is
  /// harmless.
  void close() {
    final ahead = _tail;
    detached('preview', 'ws tunnel close', () async {
      await ahead.timeout(_closeGrace, onTimeout: () {}).catchError((_) {});
      _channel.close();
    });
  }

  /// Never throws — the chain in [send] carries no error handler of its own,
  /// and one rejection there would strand every frame behind it.
  Future<void> _sendOne(TunnelWsFrame frame, int bytes) async {
    try {
      if (_aborted) return;
      final accepted = await _channel.send(frame).timeout(_sendTimeout);
      if (!accepted) _abort('channel refused the frame');
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
