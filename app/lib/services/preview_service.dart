import 'dart:async';

import 'package:uuid/uuid.dart';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';

import '../demo/demo_identity.dart';
import '../models/preview_models.dart';
import '../models/ab_message.dart';
import '../project/project_session.dart';
import '../util/ab_log.dart';
import '../util/detached.dart';
import 'preview_handoff.dart';
import 'preview_port_forwarder.dart';

/// Per-project preview service. Heavy-tier primary (preview:snapshot,
/// preview:url) with a status-tier subscription for `ports:update`. In relay
/// mode a tab's traffic is raw TCP forwarded over one native stream per
/// accepted connection (`AgentTransport.openTunnelTcp`) and never touches
/// heavy/status/control — see [PreviewPortForwarder].
///
/// Constructed at [ProjectSession] creation time. Lifetime is bound to the
/// session; calling [dispose] cancels all subscriptions and closes the
/// state controller.
class PreviewService {
  final ProjectSession session;
  final String checkoutId;

  /// How long a relay-mode open waits for the bridge's probe reply. The bridge
  /// bounds its own connect, so this only trips when the app's stream slots
  /// are all held by other forwarded connections.
  final Duration probeTimeout;

  final PreviewHandoff _handoff;

  StreamSubscription<Map<String, dynamic>>? _heavySub;
  StreamSubscription<Map<String, dynamic>>? _statusSub;
  bool _disposed = false;

  final _stateController = StreamController<PreviewState>.broadcast();
  PreviewState _state = const PreviewState();

  /// Relay-mode forwarders, one per open tab, keyed by dev-server port. Local
  /// mode never populates this — the webview hits localhost directly.
  final Map<int, PreviewPortForwarder> _forwarders = {};

  /// The open currently running for a port, so a second request for it joins
  /// that one instead of probing and binding again.
  final Map<int, Future<void>> _opening = {};

  /// Bumped on every open and every close of a port. An open that finds the
  /// value changed after an await was superseded (closed, or replaced) and must
  /// release whatever it built instead of publishing it.
  final Map<int, int> _generation = {};

  /// A followed link's load, per tab, until the screen takes it. It is held
  /// here rather than delivered by a state listener because the preview screen
  /// is unmounted whenever another pane is showing, and a listener-only
  /// delivery would be lost with nothing mounted to hear it. The load must be
  /// applied by whichever screen builds the tab's webview next.
  final Map<int, Uri> _pendingNav = {};

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

  PreviewService.fromSession(
    this.session, {
    this.checkoutId = 'main',
    this.probeTimeout = const Duration(seconds: 15),
    PreviewHandoff? handoff,
  }) : _handoff = handoff ?? PreviewHandoff.shared {
    _heavySub = session.checkoutHeavyStream(checkoutId).listen(_onJson);
    _statusSub = session.checkoutStatusStream(checkoutId).listen(_onJson);
    if (!session.transport.isLocal) {
      final parked = _handoff.claim(_handoffKey, _adoptLate);
      if (parked != null) _adoptParked(parked);
    }
  }

  String get _handoffKey => '${session.projectId}#$checkoutId';

  // Held as a field so [PreviewHandoff.withdraw] can match it by identity.
  late final void Function(ParkedPreview) _adoptLate = _adoptParked;

  TunnelTcpOpener _openerFor(int port) =>
      (connId) => session.transport.openTunnelTcp(
        connId: connId,
        port: port,
        checkoutId: checkoutId,
      );

  /// Takes over a predecessor's listeners and tabs. A port this service has
  /// already opened or is opening keeps its own forwarder.
  void _adoptParked(ParkedPreview parked) {
    if (_disposed) {
      unawaited(parked.close());
      return;
    }
    final adopted = <PreviewTab>[];
    for (final tab in parked.tabs) {
      final forwarder = parked.forwarders.remove(tab.port);
      if (forwarder == null) continue;
      if (_tabByPort(tab.port) != null ||
          _forwarders.containsKey(tab.port) ||
          _opening.containsKey(tab.port)) {
        unawaited(forwarder.close());
        continue;
      }
      forwarder.rebind(_openerFor(tab.port));
      _forwarders[tab.port] = forwarder;
      adopted.add(tab);
    }
    unawaited(parked.close());
    _autoOpenConsidered.addAll(parked.autoOpenConsidered);
    if (adopted.isEmpty) return;
    final parkedActive = parked.activeTabId;
    _setState(
      _state.copyWith(
        tabs: [..._state.tabs, ...adopted],
        activeTabId:
            _state.activeTabId ??
            (adopted.any((t) => t.port == parkedActive)
                ? parkedActive
                : adopted.first.port),
      ),
    );
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

  // One set serves both tiers: classifyAbMessage moves any error-bearing frame
  // to status whatever its type.
  static const Set<String> _handledTypes = {
    'ports:update',
    'port:detected',
    'preview:snapshot',
    'preview:url',
  };

  void _onJson(Map<String, dynamic> json) {
    final parsed = parseAbMessageOfType(json, _handledTypes);
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
      openTab(
        msg.port,
        scheme: msg.scheme,
        focus: _state.tabs.isEmpty,
        reportErrors: false,
      ),
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
          reportErrors: false,
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

  // --- Public methods ---

  PreviewTab? _tabByPort(int port) {
    for (final tab in _state.tabs) {
      if (tab.port == port) return tab;
    }
    return null;
  }

  /// Opens [port] as a tab, or focuses it if already open (a no-op beyond
  /// that — no rebuild, no reload — unless [scheme] actually changed). In
  /// relay mode probes the dev server through the bridge, then forwards a
  /// loopback port to it; that port is the requested one unless it is taken
  /// locally. [focus] false opens the tab in the background (used for
  /// auto-open on detection) without moving [PreviewState.activeTabId].
  /// [path] lands a FRESHLY opened tab somewhere other than the origin (e.g. a
  /// pasted link to `localhost:3000/dashboard`); it's ignored when [port] is
  /// already open — reusing a live tab must never yank it to a different page.
  ///
  /// In relay mode the tab's scheme is what the bridge's probe found, so a
  /// caller's [scheme] is only a hint and never a reason to reopen a live tab.
  /// [reportErrors] false is for background auto-opens: a failure is logged,
  /// leaves [PreviewState.error] alone and lets the port be auto-opened again
  /// later.
  ///
  /// [navigateExisting] is for a link the user explicitly followed: a reused
  /// tab is then sent to [path] on its own origin instead of staying on
  /// whatever page it had wandered to. The load is queued for
  /// [takeNavRequest]; a tab whose scheme cannot be reused is reopened instead.
  Future<void> openTab(
    int port, {
    String scheme = 'http',
    bool focus = true,
    String path = '/',
    bool navigateExisting = false,
    bool reportErrors = true,
  }) {
    final existing = _tabByPort(port);
    if (existing != null &&
        (!session.transport.isLocal || existing.scheme == scheme)) {
      final target = navigateExisting
          ? existingTabNavigationUrl(port, scheme: scheme, path: path)
          : null;
      if (target != null) {
        _pendingNav[port] = target;
        // Emitted even when nothing visible changed: every emission is a new
        // state, and that is what makes a mounted screen rebuild and take the
        // load.
        _setState(_state.copyWith(activeTabId: focus ? port : null));
      } else if (focus) {
        setActiveTab(port);
      }
      return Future.value();
    }
    final pending = _opening[port];
    if (pending != null) {
      return pending.then((_) {
        if (focus) setActiveTab(port);
      });
    }
    late final Future<void> tracked;
    tracked = _open(
      port,
      scheme: scheme,
      focus: focus,
      path: path,
      reportErrors: reportErrors,
    ).whenComplete(() {
      if (identical(_opening[port], tracked)) _opening.remove(port);
    });
    _opening[port] = tracked;
    return tracked;
  }

  /// Hands over, once, the load a followed link asked of [port]'s tab, or null
  /// when none is waiting. Deliberately emits no state: the caller is the
  /// screen's build, where publishing would modify a provider mid-build.
  Uri? takeNavRequest(int port) => _pendingNav.remove(port);

  /// Resolves an address-bar navigation through the tab's actual origin,
  /// including an ephemeral forwarder port when the local one was taken.
  Uri? existingTabNavigationUrl(
    int port, {
    required String scheme,
    required String path,
  }) {
    final tab = _tabByPort(port);
    if (tab == null || tab.currentUrl == null) return null;
    // Relay tabs carry the probed scheme, which the typed one may not match.
    if (session.transport.isLocal && tab.scheme != scheme) return null;
    final origin = Uri.parse(tab.currentUrl!).origin;
    return Uri.parse('$origin$path');
  }

  Future<void> _open(
    int port, {
    required String scheme,
    required bool focus,
    required String path,
    required bool reportErrors,
  }) async {
    // '/' is the implicit default everywhere this is built — keep it out of
    // the URL so an untouched open still reads as the bare origin (matches
    // what every existing caller/test expects).
    final suffix = path == '/' ? '' : path;

    // Local mode: app and dev server share the host, so the WebView can hit
    // localhost:port directly (over the target scheme).
    if (session.transport.isLocal) {
      _upsertTab(
        PreviewTab(
          port: port,
          scheme: scheme,
          localPort: port,
          currentUrl: '$scheme://localhost:$port$suffix',
        ),
        focus: focus,
      );
      return;
    }

    // The bridge, not the caller, knows whether the dev server speaks TLS, so
    // the WebView's scheme comes from a probe instead of the detected hint.
    final generation = _generation.update(port, (g) => g + 1, ifAbsent: () => 1);
    bool superseded() => _disposed || _generation[port] != generation;

    final probe = session.transport.openTunnelTcp(
      connId: const Uuid().v4(),
      port: port,
      checkoutId: checkoutId,
      probe: true,
    );
    final bool tls;
    try {
      tls = (await probe.ready.timeout(probeTimeout)).tls ?? false;
    } on Object catch (e) {
      probe.abort();
      if (e is! TunnelExchangeFailure && e is! TimeoutException) rethrow;
      final code = e is TunnelExchangeFailure ? e.code : 'TIMEOUT';
      AbLog.warn(
        'preview',
        'preview probe failed',
        fields: {
          'port': port,
          'code': code,
          if (e is TunnelExchangeFailure) 'message': e.message,
        },
      );
      if (superseded()) return;
      if (reportErrors) {
        _setState(
          _state.copyWith(
            error: code == 'UNREACHABLE'
                ? 'Nothing is listening on port $port'
                : 'Could not reach port $port ($code)',
          ),
        );
      } else {
        // Nothing opened, so a later ports:update may try this port again.
        _autoOpenConsidered.remove(port);
      }
      return;
    }
    if (superseded()) return;

    // A re-open of the same port rebinds it, so the previous forwarder must
    // release the port first.
    final previous = _forwarders.remove(port);
    await previous?.close();
    if (superseded()) return;

    final forwarder = PreviewPortForwarder(open: _openerFor(port));
    final int localPort;
    try {
      localPort = await forwarder.start(port);
    } on Object {
      await forwarder.close();
      rethrow;
    }
    if (superseded()) {
      await forwarder.close();
      return;
    }
    _forwarders[port] = forwarder;

    final tabScheme = tls ? 'https' : 'http';
    _setState(_state.copyWith(clearError: true));
    _upsertTab(
      PreviewTab(
        port: port,
        scheme: tabScheme,
        localPort: localPort,
        currentUrl: '$tabScheme://localhost:$localPort$suffix',
      ),
      focus: focus,
    );
  }

  void _upsertTab(PreviewTab tab, {required bool focus}) {
    // A replaced tab carries its own target; a load queued for the old one
    // would override it.
    _pendingNav.remove(tab.port);
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

  /// Focuses an already-open tab. Pure state flip — no network/forwarder work —
  /// which is what guarantees switching tabs never reloads one.
  void setActiveTab(int port) {
    if (_tabByPort(port) == null) return;
    if (_state.activeTabId == port) return;
    _setState(_state.copyWith(activeTabId: port));
  }

  /// Closes [port]'s tab, releasing its forwarder (relay mode; a no-op in local
  /// mode, which never binds one). Reassigns the active tab to the first
  /// remaining one, or clears it if none remain.
  Future<void> closeTab(int port) async {
    // Invalidates an open still probing or binding this port, and lets a fresh
    // open start instead of joining it.
    _generation.update(port, (g) => g + 1, ifAbsent: () => 1);
    // The removed open is still awaited by the caller that started it.
    unawaited(_opening.remove(port));
    final forwarder = _forwarders.remove(port);
    await forwarder?.close();

    // After the await: a link followed while the forwarder was closing must
    // not survive the tab it was aimed at.
    _pendingNav.remove(port);
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

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    // Before the first await, like FileService/ConfigService: the awaits below
    // can throw (and this dispose runs unawaited from _sweepCheckouts), and a
    // hydrator left registered re-requests a snapshot for a dead checkout on
    // every reconnect for the rest of the session.
    session.unhydrateCheckout(checkoutId, _snapshotHydratorKey);

    // Parked before any await, so a successor built while this teardown is
    // still running finds it.
    _handoff.withdraw(_handoffKey, _adoptLate);
    final forwarders = Map.of(_forwarders);
    _forwarders.clear();
    if (!session.transport.isLocal && forwarders.isNotEmpty) {
      for (final forwarder in forwarders.values) {
        forwarder.rebind(null);
      }
      _handoff.park(
        _handoffKey,
        ParkedPreview(
          forwarders: forwarders,
          tabs: [
            for (final tab in _state.tabs)
              if (forwarders.containsKey(tab.port)) tab,
          ],
          activeTabId: _state.activeTabId,
          autoOpenConsidered: Set.of(_autoOpenConsidered),
        ),
      );
    } else {
      for (final forwarder in forwarders.values) {
        await forwarder.close();
      }
    }

    await _heavySub?.cancel();
    _heavySub = null;
    await _statusSub?.cancel();
    _statusSub = null;
    await _resumeSub?.cancel();
    _resumeSub = null;

    await _stateController.close();
  }
}
