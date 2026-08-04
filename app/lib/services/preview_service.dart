import 'dart:async';
import 'dart:convert';

import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';

import '../models/preview_models.dart';
import '../models/ab_message.dart';
import '../project/project_message_classification.dart';
import '../project/project_session.dart';
import 'pending_reply.dart';
import 'preview_proxy_server.dart';

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

  final Map<String, PendingReply<TunnelHttpResponse>> _pendingRequests = {};
  final Map<String, StreamSubscription> _activeWsTunnels = {};

  PreviewProxyServer? _proxyServer;

  Stream<PreviewState> get stateStream => _stateController.stream;
  PreviewState get currentState => _state;

  String get projectId => session.projectId;

  PreviewService.fromSession(this.session, {this.checkoutId = 'main'}) {
    _heavySub = session.checkoutHeavyStream(checkoutId).listen(_onHeavyJson);
    _statusSub = session.checkoutStatusStream(checkoutId).listen(_onStatusJson);
    _txSub = session.transport.messages.listen(_onTransportMessage);
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
    } else if (message is PreviewSnapshotMessage) {
      _mergePreviewEntries(message.urls);
    } else if (message is PreviewUrlMessage) {
      _mergePreviewEntries([message.entry]);
    } else if (message is TunnelHttpResponse) {
      _handleTunnelResponse(message);
    }
  }

  // --- Message handlers ---

  void _handlePortsUpdate(PortsUpdateMessage msg) {
    _setState(_state.copyWith(ports: msg.ports));
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

  void _handleTunnelResponse(TunnelHttpResponse response) {
    _pendingRequests.remove(response.requestId)?.complete(response);
  }

  // --- Public methods ---

  Future<TunnelHttpResponse> proxyRequest(
    TunnelHttpRequest request, {
    // Must stay ABOVE the bridge's FETCH_TIMEOUT_MS (localhost-fetch.ts) so a
    // slow dev server yields the bridge's 502 (with the real error), never a
    // phone-side TimeoutException.
    Duration timeout = const Duration(seconds: 30),
  }) {
    final pending = PendingReply<TunnelHttpResponse>(
      timeout: timeout,
      onTimeout: () => _pendingRequests.remove(request.requestId),
      timeoutError: () => TimeoutException('Request timed out', timeout),
    );
    _pendingRequests[request.requestId] = pending;

    unawaited(
      session.transport.send(
        {...request.toJson(), 'checkoutId': checkoutId},
        channel: 'preview',
      ),
    );

    return pending.future;
  }

  /// Opens [port] in the preview. In relay mode binds the local proxy to the
  /// exact [port]; if that port is taken returns [SelectPortResult.portInUse]
  /// WITHOUT changing state, so the UI can confirm a fallback.
  Future<SelectPortResult> selectPort(int port, {String scheme = 'http'}) {
    return _open(port, scheme: scheme, allowFallback: false);
  }

  /// Confirmed retry after a [SelectPortResult.portInUse]: binds a random
  /// local port and rewrites the forwarded Host to `localhost:<port>`.
  Future<void> selectPortWithFallback(
    int port, {
    String scheme = 'http',
  }) async {
    await _open(port, scheme: scheme, allowFallback: true);
  }

  Future<SelectPortResult> _open(
    int port, {
    required String scheme,
    required bool allowFallback,
  }) async {
    // Local mode: app and dev server share the host, so the WebView can hit
    // localhost:port directly (over the target scheme). Skip the
    // tunnel-fronting proxy entirely.
    if (session.transport.isLocal) {
      await _proxyServer?.stop();
      _proxyServer = null;
      _setState(
        _state.copyWith(
          selectedPort: port,
          localProxyPort: port,
          scheme: scheme,
          currentUrl: '$scheme://localhost:$port',
        ),
      );
      return SelectPortResult.opened;
    }

    final server = PreviewProxyServer(
      targetPort: port,
      targetScheme: scheme,
      onRequest: proxyRequest,
      onWebSocketConnect: _onWsConnect,
    );

    // Free the current local port up-front ONLY when we're about to rebind that
    // exact port — otherwise a same-port re-selection would collide with our
    // own still-open proxy. For a different target, keep the existing proxy
    // alive until the new bind succeeds, so a portInUse failure doesn't tear
    // down the preview the user is currently viewing (they may cancel the
    // fallback and expect the old preview to stay live).
    final rebindingSamePort = _state.localProxyPort == port;
    if (rebindingSamePort) {
      await _proxyServer?.stop();
      _proxyServer = null;
    }

    final int localPort;
    try {
      localPort = await server.start(allowFallback: allowFallback);
    } on PortInUseException {
      await server.stop();
      // A same-port rebind already tore down the proxy that served this port
      // and then lost the race to re-bind it — there's no live preview left, so
      // clear the dead selection rather than leave currentUrl pointing at a
      // closed socket. (A different-target failure kept the old proxy alive
      // above, so its state is still valid — leave it untouched.)
      if (rebindingSamePort) {
        _setState(
          _state.copyWith(
            clearSelectedPort: true,
            clearLocalProxyPort: true,
            clearCurrentUrl: true,
          ),
        );
      }
      return SelectPortResult.portInUse;
    }

    // Swap in the new proxy only now that its bind holds the port — deferring
    // this stop is what keeps a cancelled fallback from tearing down the live
    // preview (see the rebinding-same-port note above).
    await _proxyServer?.stop();
    _proxyServer = server;

    // The proxy fronts the webview over plain HTTP regardless of [scheme];
    // the bridge applies [scheme] when reaching the dev server. So the webview
    // origin is always http://localhost:<localPort>.
    _setState(
      _state.copyWith(
        selectedPort: port,
        localProxyPort: localPort,
        scheme: scheme,
        currentUrl: 'http://localhost:$localPort',
      ),
    );
    return SelectPortResult.opened;
  }

  Future<void> deselectPort() async {
    await _proxyServer?.stop();
    _proxyServer = null;

    _setState(
      _state.copyWith(
        clearSelectedPort: true,
        clearLocalProxyPort: true,
        clearCurrentUrl: true,
      ),
    );
  }

  void refreshPreview() {}

  // --- WebSocket tunnel ---

  void _onWsConnect(WebSocketChannel channel, String path) {
    final tunnelId = const Uuid().v4();

    session.transport.send(
      createAbMessage('tunnel:ws-open', {
        'tunnelId': tunnelId,
        'port': _state.selectedPort,
        'scheme': _state.scheme,
        'path': path,
        'checkoutId': checkoutId,
      }),
      channel: 'preview',
    );

    final sub = channel.stream.listen(
      (data) {
        session.transport.send(
          createAbMessage('tunnel:ws-data', {
            'tunnelId': tunnelId,
            'data': data is String ? data : base64Encode(data as List<int>),
            'checkoutId': checkoutId,
          }),
          channel: 'preview',
        );
      },
      onDone: () {
        _activeWsTunnels.remove(tunnelId);
        session.transport.send(
          createAbMessage('tunnel:ws-close', {
            'tunnelId': tunnelId,
            'checkoutId': checkoutId,
          }),
          channel: 'preview',
        );
      },
    );

    _activeWsTunnels[tunnelId] = sub;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    await _proxyServer?.stop();
    _proxyServer = null;

    for (final pending in _pendingRequests.values) {
      pending.fail(TimeoutException('Service disposed'));
    }
    _pendingRequests.clear();

    for (final sub in _activeWsTunnels.values) {
      await sub.cancel();
    }
    _activeWsTunnels.clear();

    await _heavySub?.cancel();
    _heavySub = null;
    await _statusSub?.cancel();
    _statusSub = null;
    await _txSub?.cancel();
    _txSub = null;

    await _stateController.close();
  }
}
