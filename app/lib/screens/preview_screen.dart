import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_all/webview_all.dart';

import '../analytics/events.dart';
import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_confirm_dialog.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_menu.dart';
import '../design/widgets/ab_snack_bar.dart';
import '../design/widgets/ab_toolbar.dart';
import '../design/widgets/ab_url_field.dart';
import '../models/preview_models.dart';
import '../models/workspace_view.dart';
import '../navigation/back_intent.dart';
import '../demo/demo_identity.dart';
import '../providers/analytics.dart';
import '../providers/demo_mode.dart';
import '../services/preview_service.dart';
import '../providers/agent_transport.dart';
import '../providers/providers.dart';
import '../providers/visible_surface.dart';
import '../util/detached.dart';
import '../util/external_url.dart';
import '../utils/platform_utils.dart';
import '../widgets/preview_tab_bar.dart';
import '../util/ab_log.dart';
import '../widgets/new_session/environment_menu.dart'
    show PanelHint, PanelRow, PanelSectionHeader;
import '../util/image_thumbnail.dart';
import '../widgets/preview_draw_overlay.dart';
import '../widgets/send_capture_to_agent.dart';
import '../widgets/preview_empty_state.dart';
import '../widgets/send_to_agent_comment.dart';
import '../design/widgets/ab_loading.dart';
import 'preview_context_menu_script.dart';
import 'preview_element_picker_script.dart';
import 'preview_screenshot_script.dart';

/// The browser preview screen. A URL bar at the top of the panel with
/// refresh/external-browser/element-picker actions, a popup tab switcher
/// ([PreviewTabsButton]) over the open ports, and one embedded webview per
/// open port.
class PreviewScreen extends ConsumerStatefulWidget {
  const PreviewScreen({super.key});

  @override
  ConsumerState<PreviewScreen> createState() => _PreviewScreenState();
}

/// Per-tab webview + navigation state, keyed by port in
/// [_PreviewScreenState._tabStates]. Every open tab gets one of these and
/// keeps it alive while backgrounded — switching tabs must never rebuild a
/// controller (that would force a full reload), so state lives here rather
/// than in bare instance fields the way a single-tab screen would use.
class _TabWebViewState {
  WebViewController? controller;
  // The webview ORIGIN (scheme://localhost:port, no path) for this tab. In
  // relay mode this is the local proxy's http origin; in local mode it
  // carries the target scheme (http/https). Used to re-anchor address-bar
  // input and as the origin boundary [_toDisplayUrl] rewrites from — always
  // path-free, even though the tab's actual initial load (see
  // [lastAppliedUrl]) may land on a path a pasted link named.
  String origin = '';
  // What the address bar presents as this tab's origin: the logical target
  // (`scheme://localhost:<port>`), not the plain-http proxy origin the
  // webview actually loads — otherwise an https target reads as "http://…"
  // and the real port is hidden behind the proxy's random one. Identical to
  // [origin] in local mode.
  String displayOrigin = '';
  // The last `PreviewTab.currentUrl` (or its default) a controller was built
  // from — path included. Purely a rebuild guard: a same-port http↔https
  // toggle, or a fresh link opened on an already-tracked port, produces a
  // new value here and that's what triggers a new controller; [origin]
  // itself can't serve this since it's deliberately path-free.
  String lastAppliedUrl = '';
  String currentUrl = '';
  bool canGoBack = false;
  bool canGoForward = false;
}

/// One in-flight viewport capture request — see
/// [_PreviewScreenState._captureScreenshot] and
/// [_PreviewScreenState._onScreenshotMessage]. [chunks] starts empty (sized
/// once the `start` message reports how many pieces to expect) and is
/// null-filled positionally, since chunk messages are not guaranteed to
/// arrive in order.
class _ScreenshotCapture {
  _ScreenshotCapture(this.port);
  final int port;
  final Completer<Uint8List> completer = Completer<Uint8List>();
  List<String?> chunks = [];
  int dataChars = 0;
}

class _PreviewScreenState extends ConsumerState<PreviewScreen> {
  static const _screenshotChunkChars = 200000;
  static const _maxScreenshotBytes = 20 * 1024 * 1024;
  static const _maxScreenshotDataChars =
      ((_maxScreenshotBytes + 2) ~/ 3) * 4 + 64;
  static const _maxScreenshotChunks =
      (_maxScreenshotDataChars + _screenshotChunkChars - 1) ~/
          _screenshotChunkChars;

  final Map<int, _TabWebViewState> _tabStates = {};

  /// Port of the tab the element picker is currently armed on, or null. A
  /// single nullable port, not a per-tab map — the picker is one in-the-moment
  /// interaction, never armed on more than one tab at once.
  int? _pickerActiveForPort;

  /// Non-null while a viewport capture is in flight — port it was requested
  /// on, the completer its [kScreenshotCaptureScript] reply resolves, and the
  /// chunk buffer that reply fills in over several `AntgridScreenshotCapture`
  /// messages (see [_onScreenshotMessage]). A single in-flight capture, not
  /// per-port: like the picker, this is one in-the-moment interaction, and
  /// both callers disable their trigger for the duration.
  _ScreenshotCapture? _screenshotCapture;

  /// Port of the tab the draw overlay is armed on, or null — the same shape
  /// as [_pickerActiveForPort], and mutually exclusive with it: both claim
  /// every pointer over the page, so only one can be live at a time.
  ///
  /// The overlay draws on the LIVE page and captures nothing until send, so
  /// arming it neither freezes the preview nor swaps the surface — see
  /// [PreviewDrawOverlay].
  int? _drawActiveForPort;

  /// Reaches the live overlay so a system back can go through its own
  /// confirm-before-discarding path rather than around it — see
  /// [_backFromPreview].
  final GlobalKey<PreviewDrawOverlayState> _drawKey = GlobalKey();

  /// Port + Flutter-global anchor position of an in-flight right-click, from
  /// [_onSecondaryPointerDown] until either [_onContextMenuMessage] resolves
  /// it with real DOM context (a link, a selection, an editable field) or
  /// [_contextMenuFallbackTimer] gives up and shows a generic menu anyway —
  /// right-click doing nothing at all (the native WebView2 menu is disabled
  /// at the plugin level with no Dart-side toggle) is the bug this exists to
  /// fix, so SOME menu has to appear even when the page swallows the click or
  /// the content script hasn't loaded yet. Desktop only; right-click has no
  /// touch equivalent.
  int? _pendingContextMenuPort;
  Offset? _pendingContextMenuAnchor;
  Timer? _contextMenuFallbackTimer;

  /// True while the address bar is armed to open a NEW tab (via the "+"
  /// button) rather than navigate the active one — the two share the same
  /// field, so this is what disambiguates a submit between them. Irrelevant
  /// (never checked) when there's no active tab at all: with nothing to
  /// navigate, a submit always means "open a new tab" regardless of this
  /// flag. See [_handleAddressSubmit].
  bool _composingNewTab = false;

  // Pull-to-refresh (touch platforms only — see _buildTabWebView). A raw
  // pointer drag over the active tab's webview, armed only when the page was
  // already scrolled to the top when the drag started (matching the platform
  // convention: otherwise every downward drag to scroll content UP would
  // spuriously trigger a reload). Single fields, not per-port: only the
  // visible tab is ever hit-testable (see the IndexedStack in _buildBody), so
  // at most one drag can be in flight at a time.
  double? _pullStartY;
  double _pullDistance = 0;
  bool _pullArmed = false;
  int? _refreshingPort;
  static const _kPullRefreshThreshold = 70.0;
  static const _kPullRefreshMax = 100.0;

  late final TextEditingController _addrController;
  late final FocusNode _addrFocus;

  /// Anchor for the mobile compact toolbar's overflow ("hamburger") menu —
  /// see [_openOverflowMenu].
  final _overflowButtonKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _addrController = TextEditingController();
    _addrFocus = FocusNode();
    // Discard unsubmitted edits on blur — restore the live URL.
    // (Select-all-on-focus is handled by AbUrlField.)
    _addrFocus.addListener(() {
      if (!_addrFocus.hasFocus) {
        if (_composingNewTab && mounted) {
          setState(() => _composingNewTab = false);
        }
        final id = ref.read(previewStateProvider).value?.activeTabId;
        final tabState = id != null ? _tabStates[id] : null;
        // No active tab — nothing to restore to, so discard the edit outright
        // rather than leaving whatever was typed on screen.
        final display = tabState == null
            ? ''
            : _toDisplayUrl(tabState, tabState.currentUrl);
        if (_addrController.text != display) {
          _addrController.text = display;
        }
      }
    });
  }

  /// Strips a URL down to its bare origin (scheme://host:port) — a pasted
  /// link's path/query/fragment is for the INITIAL load only, never for
  /// [_TabWebViewState.origin], which path-relative navigation and
  /// [_toDisplayUrl]'s rewrite both depend on staying path-free. Identity
  /// (best-effort) if [url] doesn't parse as absolute.
  String _originOf(String url) {
    final parsed = Uri.tryParse(url);
    if (parsed == null || !parsed.hasScheme || !parsed.hasAuthority) {
      return url;
    }
    return '${parsed.scheme}://${parsed.host}:${parsed.port}';
  }

  /// Maps a real webview URL onto its user-facing form by swapping the proxy
  /// origin for the logical target origin. Identity when they already match
  /// (local mode) or the URL is foreign to the preview origin.
  String _toDisplayUrl(_TabWebViewState tabState, String url) {
    if (tabState.origin.isEmpty ||
        tabState.displayOrigin.isEmpty ||
        tabState.origin == tabState.displayOrigin) {
      return url;
    }
    if (!url.startsWith(tabState.origin)) return url;
    // Origin boundary: 'http://localhost:5678' must not claim
    // 'http://localhost:56789/...' — the port digits have to end here.
    final rest = url.substring(tabState.origin.length);
    if (rest.isNotEmpty && !'/?#'.contains(rest[0])) return url;
    return '${tabState.displayOrigin}$rest';
  }

  /// Build a webview controller anchored at [initialUrl] for [port]'s tab.
  /// JS on; navigation callbacks write into that tab's [_TabWebViewState]
  /// specifically — a backgrounded tab can finish navigating while a
  /// different one is on screen, so they must never touch whichever tab
  /// happens to be active when the callback fires.
  WebViewController _buildController(
    int port,
    String initialUrl,
    Color background,
  ) {
    return WebViewController()
      // Without this the webview paints white during page load/navigation — a
      // hard flash in a near-black UI. macOS honours it only where its WKWebView
      // version exposes a public background-color API; the ColoredBox underlay
      // in _buildTabWebView covers the versions where it no-ops.
      ..setBackgroundColor(background)
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      // Registered before loadRequest: webview_all only picks up a new JS
      // channel starting with the NEXT page load, so registering any later
      // would miss the very load this controller is being built for.
      ..addJavaScriptChannel(
        'AntgridElementPicker',
        onMessageReceived: (msg) => _onElementPicked(port, msg.message),
      )
      ..addJavaScriptChannel(
        'AntgridScreenshotCapture',
        onMessageReceived: (msg) => _onScreenshotMessage(port, msg.message),
      )
      ..addJavaScriptChannel(
        'AntgridContextMenu',
        onMessageReceived: (msg) => _onContextMenuMessage(port, msg.message),
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            _clearPickerIfArmedOn(port);
            _refreshHistoryFlags(port);
            // Persistent (unlike the picker), so it's re-armed on every real
            // navigation rather than only while some tool is active — see
            // kContextMenuScript's doc. Touch platforms have no right-click.
            if (!isMobilePlatform) {
              unawaited(
                _tabStates[port]?.controller?.runJavaScript(kContextMenuScript),
              );
            }
            if (_refreshingPort == port && mounted) {
              setState(() => _refreshingPort = null);
            }
          },
          onUrlChange: (change) {
            _clearPickerIfArmedOn(port);
            final url = change.url;
            final tabState = _tabStates[port];
            if (tabState == null || url == null || url == tabState.currentUrl) {
              _refreshHistoryFlags(port);
              return;
            }
            if (mounted) {
              setState(() {
                tabState.currentUrl = url;
              });
              if (ref.read(previewStateProvider).value?.activeTabId == port) {
                _syncAddrField(_toDisplayUrl(tabState, url));
              }
            }
            _refreshHistoryFlags(port);
          },
          onWebResourceError: (error) {
            AbLog.error(
              'PreviewScreen',
              'WebView error',
              fields: {'description': error.description},
            );
          },
        ),
      )
      ..loadRequest(Uri.parse(initialUrl));
  }

  Future<void> _refreshHistoryFlags(int port) async {
    final tabState = _tabStates[port];
    final ctrl = tabState?.controller;
    if (tabState == null || ctrl == null) return;
    final results = await Future.wait([ctrl.canGoBack(), ctrl.canGoForward()]);
    if (!mounted) return;
    final back = results[0];
    final fwd = results[1];
    if (back == tabState.canGoBack && fwd == tabState.canGoForward) return;
    setState(() {
      tabState.canGoBack = back;
      tabState.canGoForward = fwd;
    });
  }

  /// A real navigation tears down the page's whole JS world, taking any
  /// armed picker's listeners with it — the toolbar must not keep showing
  /// "armed" once the JS side backing it is gone.
  void _clearPickerIfArmedOn(int port) {
    if (_pickerActiveForPort != port) return;
    if (mounted) setState(() => _pickerActiveForPort = null);
  }

  @override
  void dispose() {
    _addrController.dispose();
    _addrFocus.dispose();
    _contextMenuFallbackTimer?.cancel();
    _tabStates.clear();
    super.dispose();
  }

  /// Sync the address bar controller with [url] without clobbering an
  /// in-progress edit (focused field).
  void _syncAddrField(String url) {
    if (_addrFocus.hasFocus) return;
    if (_addrController.text == url) return;
    _addrController.text = url;
  }

  /// Resolve user input → a navigable URL on the ACTIVE tab. This panel
  /// previews YOUR dev-server ports, not the open web, so the two things
  /// worth doing with typed input are: follow an absolute URL exactly as
  /// given (a redirect target, an OAuth provider, a link your own app
  /// produced — the webview has real device networking regardless of
  /// local/relay mode, it isn't sandboxed to the tab's origin), or treat
  /// free text as a PATH relative to that tab's origin — the useful "type
  /// `/login` to jump around your own dev server" behavior this panel exists
  /// for. There is no third case: a bare word that isn't a path doesn't get
  /// guessed at as a site or searched for.
  void _navigateToInput(String input) {
    final id = ref.read(previewStateProvider).value?.activeTabId;
    final tabState = id != null ? _tabStates[id] : null;
    if (tabState == null) return;
    final trimmed = input.trim();
    if (trimmed.isEmpty) return;

    final parsed = Uri.tryParse(trimmed);
    if (parsed != null && parsed.hasScheme && parsed.hasAuthority) {
      tabState.controller?.loadRequest(parsed);
      _addrFocus.unfocus();
      return;
    }

    if (tabState.origin.isEmpty) return;
    String pathAndQuery;
    if (parsed != null && parsed.hasScheme) {
      final q = parsed.hasQuery ? '?${parsed.query}' : '';
      final f = parsed.hasFragment ? '#${parsed.fragment}' : '';
      final p = parsed.path.isEmpty ? '/' : parsed.path;
      pathAndQuery = '$p$q$f';
    } else {
      pathAndQuery = trimmed.startsWith('/') ? trimmed : '/$trimmed';
    }
    final target = '${tabState.origin}$pathAndQuery';
    tabState.controller?.loadRequest(Uri.parse(target));
    _addrFocus.unfocus();
  }

  /// Dispatches an address-bar submit to whichever job it means: opening a
  /// NEW tab (no active tab to navigate, or the "+" button armed
  /// [_composingNewTab]) versus navigating the active one. One field serves
  /// both — a real browser's address bar does the same double duty for
  /// "new tab" vs "this tab", it just has an actual blank tab to submit into
  /// first; this panel has no such placeholder tab, so the flag stands in
  /// for it.
  ///
  /// A new tab accepts a PORT or a LINK to your own dev server (see
  /// [parsePreviewTarget]) — both open through the real preview/tunnel
  /// pipeline, same as picking one from the port list, and land at whatever
  /// path the link named. Anything else is rejected: this previews your dev
  /// server, not the open web.
  void _handleAddressSubmit(String input) {
    final activeId = ref.read(previewStateProvider).value?.activeTabId;
    if (activeId == null || _composingNewTab) {
      if (_composingNewTab) setState(() => _composingNewTab = false);
      final trimmed = input.trim();
      if (trimmed.isEmpty) return;

      final target = parsePreviewTarget(trimmed);
      if (target == null) {
        showAbSnackBar(
          context,
          'Enter a port (e.g. 3000) or a link like localhost:3000/path',
        );
        return;
      }
      final (port, scheme, path) = target;
      unawaited(_openPort(port, scheme, path: path));
      _addrFocus.unfocus();
      return;
    }
    _navigateToInput(input);
  }

  /// Arms the address bar to open a NEW tab on its next submit rather than
  /// navigate the active one, then focuses it — the "+" button's whole job.
  /// No dialog: typing a port (or a link) and pressing Enter in the SAME top
  /// bar is the entire flow, matching how the truly-empty state (no tab open
  /// yet) is already handled by [_handleAddressSubmit].
  void _startComposingNewTab() {
    setState(() {
      _composingNewTab = true;
      _addrController.clear();
    });
    _addrFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final previewStateAsync = ref.watch(previewStateProvider);
    // watch, not the `ref.read` in [_backFromPreview]: the `active` flag has to
    // be recomputed when this tab goes on or off screen.
    final onScreen =
        ref.watch(visibleWorkspaceViewProvider) == WorkspaceView.preview;
    final activeId = previewStateAsync.value?.activeTabId;
    final activeCanGoBack =
        activeId != null && (_tabStates[activeId]?.canGoBack ?? false);
    return BackHandler(
      priority: BackPriority.previewContent,
      active:
          onScreen &&
          (_drawActiveForPort != null || activeCanGoBack || activeId != null),
      onBack: _backFromPreview,
      child: previewStateAsync.when(
        loading: () => const AbLoading(message: 'loading preview...'),
        error: (error, _) => Center(
          child: Text(
            'Error: $error',
            style: const TextStyle(color: Colors.grey),
          ),
        ),
        data: (state) => _buildContent(state),
      ),
    );
  }

  /// Open an arbitrary port through the preview pipeline. Works in both local
  /// (direct localhost) and relay (tunnel proxy) modes — [PreviewService.
  /// openTab] branches internally. Used by manual entry, recent-port
  /// quick-picks, and the port list. On a relay-mode port conflict, confirms
  /// before falling back to a different local port.
  Future<void> _openPort(int port, String scheme, {String path = '/'}) async {
    // The sample project advertises the ports a real dev server would, because
    // an empty preview tab is not what the product looks like — but the demo
    // transport reports itself LOCAL, so opening one would point a real webview
    // at a localhost port nothing is listening on and render a browser error
    // page inside the demo. Decline in the same words every other demo refusal
    // uses instead.
    if (ref.read(demoModeProvider)) {
      showAbSnackBar(context, kDemoRefusalText);
      return;
    }
    // Pin the project this open belongs to. The provider re-reads below are
    // always the currently-focused service (never disposed at the synchronous
    // moment of read), but focus can move across the dialog await — so we
    // re-check it before the fallback rather than acting on a stale service.
    final projectId = ref.read(selectedRegistrationIdProvider);
    try {
      final svc = focusedCheckoutServiceOrNull(
        ref.container,
        (s) => s.previewService,
      );
      if (svc == null) return;
      final result = await svc.openTab(port, scheme: scheme, path: path);
      if (result != SelectPortResult.portInUse) {
        ref
            .read(analyticsServiceProvider)
            ?.track(AnalyticsEvents.previewOpened);
        return;
      }
      if (!mounted) return;

      final confirmed = await AbConfirmDialog.show(
        context: context,
        title: 'Port $port unavailable',
        body:
            'Port $port could not be opened on this device (it may be in use '
            'or reserved). Open the preview on a different local port instead? '
            'Sites that pin assets to port $port may not fully load.',
        confirmLabel: 'Open anyway',
      );
      if (!confirmed || !mounted) return;
      // Focus may have moved to another project while the dialog was open (e.g.
      // via the projects drawer). Binding the fallback on the now-focused —
      // possibly LRU-evicted/disposed — service would leak its socket, so bail
      // if the focus changed.
      if (ref.read(selectedRegistrationIdProvider) != projectId) return;
      // Re-resolve rather than reusing `svc`: the session can have been
      // invalidated (and its service disposed) while the dialog was open even
      // though focus never moved.
      final fallbackSvc = focusedCheckoutServiceOrNull(
        ref.container,
        (s) => s.previewService,
      );
      if (fallbackSvc == null) return;
      await fallbackSvc.selectPortWithFallback(
        port,
        scheme: scheme,
        path: path,
      );
      // The fallback path opens a preview too — count it like the direct path.
      ref.read(analyticsServiceProvider)?.track(AnalyticsEvents.previewOpened);
    } on Object catch (e) {
      // openTab/selectPortWithFallback run a real socket bind; a non-conflict
      // failure (interface down, handles exhausted) throws here. These calls
      // are fire-and-forget at the callers, so surface the error ourselves
      // instead of letting it become an unobserved async error.
      if (!mounted) return;
      showAbSnackBar(context, 'Could not open preview on port $port: $e');
    }
  }

  Widget _buildContent(PreviewState state) {
    // Build/update every open tab's controller — not just the active one —
    // so a backgrounded tab (auto-detected while looking elsewhere) starts
    // loading the moment it opens rather than only once first focused.
    for (final tab in state.tabs) {
      final initialUrl =
          tab.currentUrl ?? 'http://localhost:${tab.localProxyPort}';
      final tabState = _tabStates.putIfAbsent(tab.port, _TabWebViewState.new);
      // Rebuild only on an actual target change: webview_flutter builds the
      // controller eagerly (unlike inappwebview's onWebViewCreated), so a
      // fresh target means a fresh controller and the ValueKey below swaps
      // the underlying platform view. An unchanged target — the common case
      // on every rebuild once a tab is open — must NOT recreate the
      // controller, or every tab would reload on every state update. Keyed
      // on the full URL (path included), not [_TabWebViewState.origin] —
      // that's deliberately path-free (see its doc) so it can't serve this.
      if (tabState.lastAppliedUrl == initialUrl) continue;
      tabState.lastAppliedUrl = initialUrl;
      tabState.origin = _originOf(initialUrl);
      // Present the logical target, not the proxy: in relay mode the webview
      // loads http://localhost:<random proxy port>, but the tab targets
      // scheme://localhost:<port>.
      tabState.displayOrigin = '${tab.scheme}://localhost:${tab.port}';
      tabState.currentUrl = initialUrl;
      if (tab.port == state.activeTabId) {
        _syncAddrField(_toDisplayUrl(tabState, tabState.currentUrl));
      }
      tabState.controller = _buildController(
        tab.port,
        initialUrl,
        context.antgrid.bgDeepest,
      );
    }
    // Drop state for tabs that closed.
    final openPorts = {for (final tab in state.tabs) tab.port};
    _tabStates.removeWhere((port, _) => !openPorts.contains(port));
    // A closed tab's controller is gone — neither the picker nor the draw
    // overlay can still be armed on it.
    if (_pickerActiveForPort != null &&
        !openPorts.contains(_pickerActiveForPort)) {
      _pickerActiveForPort = null;
    }
    if (_drawActiveForPort != null && !openPorts.contains(_drawActiveForPort)) {
      _drawActiveForPort = null;
    }
    // No active tab (none open, or the last one just closed) — the address
    // bar has no live URL to show, so it must not keep displaying whatever
    // was last typed/loaded. Skipped while composing a new tab: that flow
    // already owns the field (see [_startComposingNewTab]).
    if (state.activeTabId == null && !_composingNewTab) {
      _syncAddrField('');
    }

    // The address bar (and the rest of the toolbar chrome) is always on
    // screen from here on — like a real browser, not just once a tab is
    // open — so it's the one place to type a port whether that opens the
    // first tab, a later one, or navigates the active one.
    return _buildPreviewView(state);
  }

  /// Content below the toolbar: the open tabs' webviews, a loading spinner
  /// while the first tab's proxy binds, or the empty-state recent-ports
  /// quick-pick once nothing's open.
  Widget _buildBody(PreviewState state) {
    if (state.tabs.isNotEmpty) {
      final active = state.activeTab ?? state.tabs.first;
      // Tab open but proxy not ready yet.
      if (active.localProxyPort == null) return const AbLoading();
      final activeIndex = state.activeTabId == null
          ? 0
          : state.tabs.indexWhere((t) => t.port == state.activeTabId);
      // The overlay only mounts over the tab it was armed on, and only while
      // that tab is the visible one — a background tab's marks would be
      // drawn against a page nobody can see.
      final drawController = _drawActiveForPort == active.port
          ? _tabStates[active.port]?.controller
          : null;
      // Every open tab's webview stays mounted in an IndexedStack so
      // switching tabs never disposes (and reloads) a background one — the
      // same keep-mounted technique the outer WorkspacePanel already uses
      // for its own panes.
      return _framed(
        Stack(
          children: [
            IndexedStack(
              index: activeIndex < 0 ? 0 : activeIndex,
              children: [for (final tab in state.tabs) _buildTabWebView(tab)],
            ),
            // Fills exactly the webview's own box, which is what lets a
            // mark's position map onto the captured viewport with nothing
            // but a width ratio — see [compositePreviewMarks].
            if (drawController != null)
              Positioned.fill(
                child: PreviewDrawOverlay(
                  key: _drawKey,
                  captureScreenshot: () => _captureScreenshot(
                    active.port,
                    drawController,
                    onError: (reason) {
                      if (mounted) {
                        showAbSnackBar(
                          context,
                          'Could not capture the preview: $reason',
                        );
                      }
                    },
                  ),
                  onClose: () => setState(() => _drawActiveForPort = null),
                  onSend: (bytes) => detached(
                    'PreviewScreen',
                    'send drawing',
                    () => _sendDrawing(active.port, bytes),
                  ),
                ),
              ),
          ],
        ),
      );
    }

    // No tabs open — just the plain empty state. Detected ports
    // (`state.ports`) are shown only through the open-tabs UI now: bridge-side
    // detection is a text heuristic over agent/process output and can list a
    // port nothing is actually serving, so it's not worth surfacing as a
    // standalone "closed tabs" reopen list either.
    return _framed(const PreviewEmptyState());
  }

  /// Insets [child] into a rounded, subtly-bordered browser-window frame —
  /// corners genuinely rounded, including over the live webview tab.
  ///
  /// Deliberately no `ClipRRect` on [child] itself: the live tab is a native
  /// WebView2 texture surface, and clipping a platform view forces Flutter to
  /// push clip-rect updates through the platform channel on every relayout,
  /// which is what produced a flicker (and is suspected behind a hang report)
  /// when stacked on the reparent the panel-expand/restore toggle already
  /// does via GlobalKey (see `workspace_shell.dart`'s
  /// `_agentPanelKey`/`_contextPanelKey` doc). Instead, [_CornerMaskPainter]
  /// paints the four corner wedges in the surrounding chrome color OVER the
  /// content — a plain paint layer with its own independent size/position,
  /// so it never touches the webview's own RenderObject or triggers a clip
  /// update on it, whatever [child] happens to be this frame.
  Widget _framed(Widget child) => Padding(
    padding: const EdgeInsets.all(AbTokens.space8),
    child: Stack(
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: context.antgrid.borderSubtle),
            borderRadius: BorderRadius.circular(AbTokens.radiusLg),
          ),
          child: child,
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _CornerMaskPainter(
                radius: AbTokens.radiusLg,
                // Matches WorkspacePanel's own ColoredBox behind this route —
                // the mask has to disappear into that, not paint a visible
                // square of some OTHER color at each corner.
                color: context.antgrid.bgDeep,
              ),
            ),
          ),
        ),
      ],
    ),
  );

  /// Closes the active tab. Returns false when there is no service or no
  /// active tab to close.
  bool _closeActiveTab() {
    final preview = focusedCheckoutServiceOrNull(
      ref.container,
      (s) => s.previewService,
    );
    final id = ref.read(previewStateProvider).value?.activeTabId;
    if (preview == null || id == null) return false;
    unawaited(preview.closeTab(id));
    return true;
  }

  /// Back inside the preview: the draw overlay first if it's armed, then one
  /// webview page, then the active tab.
  bool _backFromPreview() {
    if (ref.read(visibleWorkspaceViewProvider) != WorkspaceView.preview) {
      return false;
    }
    // Through the overlay's own close, not straight to the flag: back is how
    // a phone user dismisses, so it has to hit the same
    // confirm-before-discarding guard the Close button does.
    if (_drawActiveForPort != null) {
      unawaited(_drawKey.currentState?.requestClose() ?? Future.value());
      return true;
    }
    // Re-check at invoke time: the controller can be gone since registration.
    final id = ref.read(previewStateProvider).value?.activeTabId;
    final tabState = id != null ? _tabStates[id] : null;
    if ((tabState?.canGoBack ?? false) && tabState?.controller != null) {
      unawaited(tabState!.controller!.goBack());
      // _refreshHistoryFlags re-syncs from onUrlChange.
      return true;
    }
    if (id == null) return false;
    return _closeActiveTab();
  }

  Future<void> _openInSystemBrowser(
    PreviewService preview,
    PreviewTab tab,
  ) async {
    // The URL must be reachable from THIS device. In local mode that's the
    // logical target directly; in relay mode the real dev server is on a
    // different machine — only the app's own in-process tunnel proxy is
    // reachable here, which is what the webview itself already loads.
    final url = preview.session.transport.isLocal
        ? '${tab.scheme}://localhost:${tab.port}'
        : 'http://localhost:${tab.localProxyPort}';
    await openExternalUrl(context, url);
  }

  /// Arms or disarms the element picker on [activeTab]. Injects the picker
  /// script directly via `runJavaScript` — it is not re-injected on
  /// navigation (a real page load already tears down its listeners, which
  /// is what disarms the picker automatically; see [_clearPickerIfArmedOn]).
  void _togglePicker(PreviewTab activeTab, _TabWebViewState? activeState) {
    if (_pickerActiveForPort == activeTab.port) {
      unawaited(
        activeState?.controller?.runJavaScript(kElementPickerStopScript),
      );
      setState(() => _pickerActiveForPort = null);
      return;
    }
    // Arming on a different tab than any previous armed one — best-effort
    // tear down the old tab's listeners so a lingering hover overlay doesn't
    // resurface if the user switches back to it later without reloading.
    if (_pickerActiveForPort != null) {
      unawaited(
        _tabStates[_pickerActiveForPort]?.controller?.runJavaScript(
          kElementPickerStopScript,
        ),
      );
    }
    unawaited(activeState?.controller?.runJavaScript(kElementPickerScript));
    // The draw overlay swallows every pointer over the page, so an armed
    // picker underneath it could never be clicked — see [_toggleDraw], which
    // disarms in the other direction.
    setState(() {
      _drawActiveForPort = null;
      _pickerActiveForPort = activeTab.port;
    });
  }

  /// Handles a message from the `AntgridElementPicker` JS channel. [port] is
  /// bound at channel-registration time (see `_buildController`), so a
  /// message from a backgrounded tab can never be misattributed to whichever
  /// tab happens to be active when it arrives.
  void _onElementPicked(int port, String rawMessage) {
    Object? decoded;
    try {
      decoded = jsonDecode(rawMessage);
    } on FormatException {
      return;
    }
    if (decoded is! Map<String, dynamic>) return;

    if (decoded['type'] == 'cancelled') {
      _clearPickerIfArmedOn(port);
      return;
    }
    if (decoded['type'] != 'picked') return;

    // The picker auto-disarms itself on pick (one-shot, per the script), so
    // this is just keeping the toolbar in sync with that.
    if (_pickerActiveForPort == port) {
      setState(() => _pickerActiveForPort = null);
    }

    final state = ref.read(previewStateProvider).value;
    if (state == null || port != state.activeTabId) return;

    final picked = decoded;
    final selectedText = formatPickedElement(picked);
    final sourceUrl = _tabStates[port]?.currentUrl ?? '';
    detached(
      'PreviewScreen',
      'send picked element',
      () => _sendPickedElement(
        port,
        selectedText,
        sourceUrl,
        pickedRegion(picked),
      ),
    );
  }

  /// Sends a DOM pick to the agent, with a picture of THAT ELEMENT attached
  /// alongside the description whenever one can be taken — the DOM text alone
  /// can't tell the agent what the element actually looks like, and a shot of
  /// the whole page hands back the very question the pick just answered.
  ///
  /// Captured and cropped best-effort: a failed shot, or a payload from an
  /// older script with no rect in it, never blocks the pick, since the DOM
  /// description is still a complete, useful message on its own.
  Future<void> _sendPickedElement(
    int port,
    String selectedText,
    String sourceUrl,
    ({Rect rect, Size viewport})? region,
  ) async {
    final container = ref.container;
    final controller = _tabStates[port]?.controller;

    Uint8List? image;
    if (controller != null) {
      final screenshot = await _captureScreenshot(port, controller);
      if (screenshot != null) {
        image = region == null
            ? screenshot
            : await cropImageToRegion(
                    screenshot,
                    region: region.rect,
                    regionSpace: region.viewport,
                  ) ??
                  screenshot;
      }
    }

    if (!mounted) return;
    final message = await showSendToAgentComment(
      context: context,
      selectedText: selectedText,
      sourceLabel: '[from preview: $sourceUrl]',
      imageBytes: image,
    );
    if (message == null || !mounted) return;
    await sendCaptureToAgent(
      context: context,
      container: container,
      text: message,
      imageBytes: image,
      fileName: 'preview-element-${DateTime.now().millisecondsSinceEpoch}.png',
    );
  }

  /// Handles one message from the `AntgridScreenshotCapture` channel. [port]
  /// is bound at channel-registration time, same as [_onElementPicked] — a
  /// message from a tab that isn't the one a capture is pending on is
  /// ignored rather than misattributed.
  void _onScreenshotMessage(int port, String rawMessage) {
    final capture = _screenshotCapture;
    if (capture == null ||
        capture.port != port ||
        capture.completer.isCompleted) {
      return;
    }
    Object? decoded;
    try {
      decoded = jsonDecode(rawMessage);
    } on FormatException {
      return;
    }
    if (decoded is! Map<String, dynamic>) return;

    switch (decoded['type']) {
      case 'error':
        capture.completer.completeError(
          StateError(decoded['message'] as String? ?? 'capture failed'),
        );
      case 'start':
        final total = decoded['totalChunks'];
        if (capture.chunks.isNotEmpty ||
            total is! int ||
            total <= 0 ||
            total > _maxScreenshotChunks) {
          capture.completer.completeError(
            StateError('invalid screenshot capture size'),
          );
          return;
        }
        capture.chunks = List<String?>.filled(total, null);
      case 'chunk':
        final seq = decoded['seq'];
        final data = decoded['data'];
        if (seq is! int ||
            data is! String ||
            seq < 0 ||
            seq >= capture.chunks.length ||
            data.length > _screenshotChunkChars) {
          capture.completer.completeError(
            StateError('invalid screenshot capture chunk'),
          );
          return;
        }
        final replaced = capture.chunks[seq]?.length ?? 0;
        final dataChars = capture.dataChars - replaced + data.length;
        if (dataChars > _maxScreenshotDataChars) {
          capture.completer.completeError(
            StateError('screenshot capture is too large'),
          );
          return;
        }
        capture.chunks[seq] = data;
        capture.dataChars = dataChars;
      case 'end':
        if (capture.chunks.isEmpty || capture.chunks.any((c) => c == null)) {
          capture.completer.completeError(
            StateError('incomplete screenshot capture'),
          );
          return;
        }
        final dataUrl = capture.chunks.join();
        final comma = dataUrl.indexOf(',');
        if (!dataUrl.startsWith('data:image/png;base64,') || comma < 0) {
          capture.completer.completeError(StateError('malformed data URL'));
          return;
        }
        try {
          capture.completer.complete(
            base64Decode(dataUrl.substring(comma + 1)),
          );
        } on FormatException {
          capture.completer.completeError(StateError('malformed PNG data'));
        }
    }
  }

  /// Captures [port]'s current viewport via [kScreenshotCaptureScript],
  /// returning PNG bytes or null on failure/timeout. Disarms an armed
  /// element picker on this tab first — its overlay (highlight box, hover
  /// label) would otherwise show up in the shot — shared by both callers,
  /// since either flow can fire while the other's overlay is live. [onError],
  /// if given, is reported a human-readable reason on failure; omit it for a
  /// best-effort caller that should just carry on without a shot rather than
  /// interrupt its own flow over one.
  Future<Uint8List?> _captureScreenshot(
    int port,
    WebViewController controller, {
    void Function(String reason)? onError,
  }) async {
    if (_screenshotCapture != null) {
      onError?.call('another screenshot capture is already in progress');
      return null;
    }
    if (_pickerActiveForPort == port) {
      unawaited(controller.runJavaScript(kElementPickerStopScript));
      setState(() => _pickerActiveForPort = null);
    }
    final capture = _ScreenshotCapture(port);
    setState(() => _screenshotCapture = capture);
    try {
      unawaited(controller.runJavaScript(kScreenshotCaptureScript));
      return await capture.completer.future.timeout(
        const Duration(seconds: 20),
      );
    } on Object catch (e) {
      onError?.call('$e');
      return null;
    } finally {
      if (_screenshotCapture == capture) {
        if (mounted) {
          setState(() => _screenshotCapture = null);
        } else {
          _screenshotCapture = null;
        }
      }
    }
  }

  /// Arms/disarms the draw overlay on [activeTab] (mobile reaches it via the
  /// overflow menu, desktop via its own trailing-row icon). Arming is pure
  /// state — nothing is captured, nothing is injected into the page, and the
  /// preview does not change size — so pressing the pencil costs the live
  /// page neither a reflow nor a repaint. The capture happens once, later,
  /// when the user sends (see [PreviewDrawOverlay]).
  ///
  /// Mutually exclusive with the element picker for the same reason the two
  /// are separate buttons: both claim every pointer over the page.
  void _toggleDraw(PreviewTab activeTab, _TabWebViewState? activeState) {
    if (activeState?.controller == null) return;
    final port = activeTab.port;
    if (_drawActiveForPort == port) {
      setState(() => _drawActiveForPort = null);
      return;
    }
    if (_pickerActiveForPort != null) {
      unawaited(
        _tabStates[_pickerActiveForPort]?.controller?.runJavaScript(
          kElementPickerStopScript,
        ),
      );
    }
    setState(() {
      _pickerActiveForPort = null;
      _drawActiveForPort = port;
    });
  }

  /// Hands the flattened screenshot+drawing [bytes] straight to the agent,
  /// with no comment box in between.
  ///
  /// Unlike a DOM pick — where the popover is what shows the description and
  /// the crop that are ABOUT to be sent — a drawing is already the whole
  /// message, made on the page the user was looking at. Interposing a second
  /// "are you sure, add a comment" step there only asks them to confirm what
  /// they just drew. Where the words go instead depends on the mode, which is
  /// what [sendCaptureToAgent] decides: a chat gets the image as an
  /// attachment in its composer, ready to be typed at; a terminal gets the
  /// staged path written into it on the spot.
  Future<void> _sendDrawing(int port, Uint8List bytes) async {
    final container = ref.container;
    final sourceUrl = _tabStates[port]?.currentUrl ?? '';
    setState(() => _drawActiveForPort = null);

    await sendCaptureToAgent(
      context: context,
      container: container,
      text: '[from preview screenshot: $sourceUrl]',
      imageBytes: bytes,
      fileName:
          'preview-annotation-${DateTime.now().millisecondsSinceEpoch}.png',
    );
  }

  /// The toolbar (address bar always on top, like a normal/mobile browser)
  /// plus whatever [_buildBody] shows below it — rendered for EVERY preview
  /// state, tabs open or not, so opening the first port, opening another
  /// one, and navigating the active tab are all just "type in the top bar
  /// and press Enter" (see [_handleAddressSubmit]) instead of three
  /// different surfaces (a centered form, a dialog, a field).
  Widget _buildPreviewView(PreviewState state) {
    // [previewStateProvider] keeps its last value while it re-runs, so this
    // view can render one frame past a session that was invalidated (host
    // restart, LRU evict) — long enough for a raw façade read to throw during
    // build. Resolve nullably and disable the actions that need the service.
    final preview = focusedCheckoutServiceOrNull(
      ref.container,
      (s) => s.previewService,
    );
    final activeTab = state.activeTab;
    final activeState = state.activeTabId != null
        ? _tabStates[state.activeTabId]
        : null;
    final captureInFlight = _screenshotCapture != null;

    // Desktop-only, and only while driving THIS device's own dev server —
    // opening the tunnel proxy's URL in the controller's own system browser
    // while remote-controlling a different machine isn't the address the
    // user typed, so hide it there rather than open something confusing.
    final showOpenExternal =
        !isMobilePlatform && (preview?.session.transport.isLocal ?? false);

    return Column(
      children: [
        AbToolbar.actions(
          // Back/Forward stay inline on every platform, always visible and
          // DISABLED (not hidden) until the active tab can actually go that
          // way — same reasoning as the hamburger's rows below.
          leading: [
            AbIconButton(
              icon: AbIcons.chevronLeft,
              tooltip: 'Back',
              onTap: (activeState?.canGoBack ?? false)
                  ? () => activeState?.controller?.goBack()
                  : null,
            ),
            AbIconButton(
              icon: AbIcons.chevronRight,
              tooltip: 'Forward',
              onTap: (activeState?.canGoForward ?? false)
                  ? () => activeState?.controller?.goForward()
                  : null,
            ),
          ],
          center: AbUrlField(
            controller: _addrController,
            focusNode: _addrFocus,
            hint: (activeTab == null || _composingNewTab)
                ? 'Port or link'
                : 'URL',
            onSubmitted: _handleAddressSubmit,
          ),
          trailing: isMobilePlatform
              ? [
                  // Everything else (New/Draw & send/Tabs) lives behind this
                  // one button on mobile — see _openOverflowMenu.
                  AbIconButton(
                    key: _overflowButtonKey,
                    icon: AbIcons.menu,
                    tooltip: 'More',
                    onTap: () => unawaited(
                      _openOverflowMenu(
                        activeTab: activeTab,
                        activeState: activeState,
                        preview: preview,
                      ),
                    ),
                  ),
                ]
              : [
                  if (showOpenExternal)
                    AbIconButton(
                      icon: AbIcons.openExternal,
                      tooltip: 'Open in browser',
                      onTap: (preview == null || activeTab == null)
                          ? null
                          : () => _openInSystemBrowser(preview, activeTab),
                    ),
                  AbIconButton(
                    icon: AbIcons.elementPicker,
                    tooltip: 'Pick an element',
                    selected:
                        _pickerActiveForPort != null &&
                        _pickerActiveForPort == activeTab?.port,
                    onTap: activeTab == null || captureInFlight
                        ? null
                        : () => _togglePicker(activeTab, activeState),
                  ),
                  AbIconButton(
                    icon: AbIcons.draw,
                    tooltip: 'Draw on the page',
                    selected:
                        _drawActiveForPort != null &&
                        _drawActiveForPort == activeTab?.port,
                    onTap: activeTab == null || captureInFlight
                        ? null
                        : () => _toggleDraw(activeTab, activeState),
                  ),
                  AbIconButton(
                    icon: AbIcons.refresh,
                    tooltip: 'Refresh',
                    onTap: activeState == null
                        ? null
                        : () => activeState.controller?.reload(),
                  ),
                  PreviewTabsButton(
                    onSelected: (port) => _selectTab(port, preview),
                    onClosed: (port) => preview?.closeTab(port),
                  ),
                  // Only needed to disambiguate "open a new tab" from
                  // "navigate the active one" on the shared address bar —
                  // with no tab open yet, a submit already means "open a
                  // new tab", so there's nothing for this button to add.
                  if (state.tabs.isNotEmpty)
                    AbIconButton(
                      icon: AbIcons.add,
                      tooltip: 'Open a new port',
                      onTap: preview == null ? null : _startComposingNewTab,
                    ),
                ],
        ),
        Expanded(child: _buildBody(state)),
      ],
    );
  }

  /// Shared by [PreviewTabsButton.onSelected] and the mobile overflow menu's
  /// tab-list section: switching tabs always cancels an in-flight pick — the
  /// picker was never meant to persist as tab state, and the backgrounded
  /// tab's listeners are still live (tabs stay mounted), so leaving it armed
  /// could fire a stale flow on an unrelated tab later.
  void _selectTab(int port, PreviewService? preview) {
    if (_pickerActiveForPort != null && _pickerActiveForPort != port) {
      unawaited(
        _tabStates[_pickerActiveForPort]?.controller?.runJavaScript(
          kElementPickerStopScript,
        ),
      );
      setState(() => _pickerActiveForPort = null);
    }
    // Same reasoning for the draw overlay, plus one of its own: its marks are
    // in the OUTGOING page's coordinates, so carrying them to another tab
    // would send the agent a drawing over the wrong screenshot.
    if (_drawActiveForPort != null && _drawActiveForPort != port) {
      setState(() => _drawActiveForPort = null);
    }
    preview?.setActiveTab(port);
    // _buildContent only resyncs the address field for a tab whose target URL
    // just CHANGED (see its `lastAppliedUrl` guard) — switching to an
    // already-open, unchanged tab never hits that line, so without this the
    // field keeps showing whichever tab was active before the switch.
    final tabState = _tabStates[port];
    if (tabState != null) {
      _syncAddrField(_toDisplayUrl(tabState, tabState.currentUrl));
    }
  }

  /// Mobile's compact toolbar folds everything the desktop trailing row
  /// spreads across separate icons — back/forward, refresh, the element
  /// picker, opening a new port, and the tab switcher — into one popup, the
  /// same "address bar + overflow menu" shape a phone browser uses. The tab
  /// list section reuses [PreviewTabsPanel] verbatim rather than opening a
  /// second nested popup: its rows already pop the enclosing route with the
  /// picked port, which is exactly the single popup this opens.
  Future<void> _openOverflowMenu({
    required PreviewTab? activeTab,
    required _TabWebViewState? activeState,
    required PreviewService? preview,
  }) async {
    final anchorContext = _overflowButtonKey.currentContext;
    if (anchorContext == null) return;
    final anchor = abMenuAnchorRect(anchorContext);
    if (anchor == null) return;
    final port = await showAbPanel<int>(
      context: anchorContext,
      anchorRect: anchor,
      width: 280,
      builder: (_) => _PreviewOverflowPanel(
        hasActiveTab: activeTab != null,
        hasPreviewService: preview != null,
        onNewPort: _startComposingNewTab,
        onRefresh: () => activeState?.controller?.reload(),
        onDraw: activeTab == null || _screenshotCapture != null
            ? null
            : () => _toggleDraw(activeTab, activeState),
        drawArmed:
            _drawActiveForPort != null && _drawActiveForPort == activeTab?.port,
        onClosedTab: (p) => preview?.closeTab(p),
      ),
    );
    if (port != null) _selectTab(port, preview);
  }

  /// Arms a pull-to-refresh candidate: records the drag origin and (async)
  /// whether the page was scrolled to the top at that moment. `getScrollPosition`
  /// racing a fast flick is fine — `_pullStartY` being cleared by
  /// [_onPullUp]/[_cancelPull] before it resolves is checked below.
  void _onPullDown(
    int port,
    WebViewController controller,
    PointerDownEvent event,
  ) {
    _pullStartY = event.position.dy;
    _pullArmed = false;
    unawaited(
      controller
          .getScrollPosition()
          .then((pos) {
            if (!mounted || _pullStartY == null) return;
            if (pos.dy <= 0) _pullArmed = true;
          })
          .catchError((_) {}),
    );
  }

  void _onPullMove(PointerMoveEvent event) {
    final start = _pullStartY;
    if (start == null) return;
    final delta = event.position.dy - start;
    if (delta <= 0 || !_pullArmed) {
      if (_pullDistance != 0) setState(() => _pullDistance = 0);
      return;
    }
    final next = delta.clamp(0, _kPullRefreshMax).toDouble();
    if (next != _pullDistance) setState(() => _pullDistance = next);
  }

  void _onPullUp(int port, WebViewController controller) {
    final shouldRefresh = _pullArmed && _pullDistance >= _kPullRefreshThreshold;
    setState(() {
      _pullStartY = null;
      _pullDistance = 0;
      _pullArmed = false;
      if (shouldRefresh) _refreshingPort = port;
    });
    if (shouldRefresh) unawaited(controller.reload());
  }

  void _cancelPull() {
    if (_pullStartY == null && _pullDistance == 0) return;
    setState(() {
      _pullStartY = null;
      _pullDistance = 0;
      _pullArmed = false;
    });
  }

  /// Right-click detection. A plain [Listener], not a gesture recognizer —
  /// coexists with the [EagerGestureRecognizer] the webview itself claims
  /// (see [_buildTabWebView]) the same way the mobile pull-to-refresh
  /// [Listener] below already does: a `Listener` never enters the gesture
  /// arena, so it can't take the click away from the page's own handling.
  void _onSecondaryPointerDown(int port, PointerDownEvent event) {
    if (event.buttons & kSecondaryMouseButton == 0) return;
    _pendingContextMenuPort = port;
    _pendingContextMenuAnchor = event.position;
    _contextMenuFallbackTimer?.cancel();
    _contextMenuFallbackTimer = Timer(const Duration(milliseconds: 350), () {
      if (_pendingContextMenuPort != port || !mounted) return;
      final anchor = _pendingContextMenuAnchor;
      _pendingContextMenuPort = null;
      _pendingContextMenuAnchor = null;
      if (anchor != null) {
        _showContextMenu(port, anchor, const PreviewContextMenuInfo.empty());
      }
    });
  }

  /// Handles the `AntgridContextMenu` channel's reply to a right-click.
  /// [port] is bound at channel-registration time, same as the picker and
  /// screenshot channels — a message from a backgrounded tab can never be
  /// misattributed to whichever click is actually pending.
  void _onContextMenuMessage(int port, String rawMessage) {
    // The fallback timer guards this too, and for the same reason: the page's
    // reply arrives on a platform channel that outlives a dispose, and
    // [_showContextMenu] below reads `context`.
    if (!mounted) return;
    if (_pendingContextMenuPort != port) return;
    final anchor = _pendingContextMenuAnchor;
    _contextMenuFallbackTimer?.cancel();
    _pendingContextMenuPort = null;
    _pendingContextMenuAnchor = null;
    if (anchor == null) return;
    final info = parseContextMenuMessage(rawMessage);
    if (info == null) return;
    _showContextMenu(port, anchor, info);
  }

  Future<void> _copyToClipboard(String text, [String? confirm]) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (confirm != null && mounted) showAbSnackBar(context, confirm);
  }

  /// Opens a link/image address found by the content script — routed through
  /// [openContentLink] rather than [_openPort] directly so an EXTERNAL link
  /// (something other than this device's own dev server) still does the
  /// right thing (system browser, with the same deceptive-link checks a
  /// terminal hyperlink or a chat markdown link already gets) instead of
  /// being silently dropped.
  void _openContextMenuLink(String href) {
    detached(
      'PreviewScreen',
      'open context-menu link',
      () => openContentLink(
        context,
        href,
        fileService: () =>
            focusedCheckoutServiceOrNull(ref.container, (s) => s.fileService),
        previewService: () => focusedCheckoutServiceOrNull(
          ref.container,
          (s) => s.previewService,
        ),
        // Already on the Preview tab — this IS that surface.
        revealView: (_) {},
      ),
    );
  }

  /// Builds and shows the right-click menu for [port]'s tab at [anchor] —
  /// Flutter GLOBAL coordinates from the [Listener] that caught the click,
  /// not the DOM event's own CSS-pixel position, which would need a
  /// scale-factor translation the Listener's coordinates never require.
  ///
  /// Every row's `onTap` always runs through [detached] where it does
  /// anything async — see `util/detached.dart` — since [showAbMenu]'s own
  /// `onTap` is exactly the void-callback boundary that rule exists for.
  void _showContextMenu(int port, Offset anchor, PreviewContextMenuInfo info) {
    final tabState = _tabStates[port];
    final controller = tabState?.controller;
    final entries = <AbMenuEntry>[];

    if (info.href case final href?) {
      final host = Uri.tryParse(href)?.host ?? '';
      entries.add(
        AbMenuItem(
          label: isLocalDevHost(host)
              ? 'Open link in new tab'
              : 'Open link in browser',
          icon: AbIcons.openExternal,
          onTap: () => _openContextMenuLink(href),
        ),
      );
      entries.add(
        AbMenuItem(
          label: 'Copy link',
          icon: AbIcons.copy,
          onTap: () => detached(
            'PreviewScreen',
            'copy link',
            () => _copyToClipboard(href, 'Copied link'),
          ),
        ),
      );
    }

    if (info.imgSrc case final imgSrc? when imgSrc != info.href) {
      final host = Uri.tryParse(imgSrc)?.host ?? '';
      entries.add(
        AbMenuItem(
          label: isLocalDevHost(host)
              ? 'Open image in new tab'
              : 'Open image in browser',
          icon: AbIcons.openExternal,
          onTap: () => _openContextMenuLink(imgSrc),
        ),
      );
      entries.add(
        AbMenuItem(
          label: 'Copy image address',
          icon: AbIcons.copy,
          onTap: () => detached(
            'PreviewScreen',
            'copy image address',
            () => _copyToClipboard(imgSrc, 'Copied image address'),
          ),
        ),
      );
    }

    if (info.selectionText.isNotEmpty) {
      if (entries.isNotEmpty) entries.add(const AbMenuDivider());
      entries.add(
        AbMenuItem(
          label: 'Copy',
          icon: AbIcons.copy,
          onTap: () => detached(
            'PreviewScreen',
            'copy selection',
            () => _copyToClipboard(info.selectionText, 'Copied'),
          ),
        ),
      );
      if (info.editable) {
        entries.add(
          AbMenuItem(
            label: 'Cut',
            onTap: () => detached('PreviewScreen', 'cut selection', () async {
              await _copyToClipboard(info.selectionText, 'Cut');
              await controller?.runJavaScript(
                kContextMenuDeleteSelectionScript,
              );
            }),
          ),
        );
      }
    }
    if (info.editable) {
      entries.add(
        AbMenuItem(
          label: 'Paste',
          enabled: controller != null,
          onTap: () => detached('PreviewScreen', 'paste into page', () async {
            final ctrl = controller;
            if (ctrl == null) return;
            final data = await Clipboard.getData(Clipboard.kTextPlain);
            final text = data?.text;
            if (text == null || text.isEmpty) return;
            await ctrl.runJavaScript(buildContextMenuPasteScript(text));
          }),
        ),
      );
    }

    if (entries.isNotEmpty) entries.add(const AbMenuDivider());
    entries.add(
      AbMenuItem(
        label: 'Reload',
        icon: AbIcons.refresh,
        enabled: controller != null,
        onTap: () => detached(
          'PreviewScreen',
          'reload page',
          () async => controller?.reload(),
        ),
      ),
    );
    entries.add(
      AbMenuItem(
        label: 'Copy page URL',
        icon: AbIcons.copy,
        enabled: tabState != null,
        onTap: () {
          if (tabState == null) return;
          detached(
            'PreviewScreen',
            'copy page url',
            () => _copyToClipboard(
              _toDisplayUrl(tabState, info.pageUrl ?? tabState.currentUrl),
              'Copied page URL',
            ),
          );
        },
      ),
    );

    unawaited(
      showAbMenu<void>(
        context: context,
        anchorRect: Rect.fromCenter(center: anchor, width: 1, height: 1),
        entries: entries,
      ),
    );
  }

  Widget _buildTabWebView(PreviewTab tab) {
    final controller = _tabStates[tab.port]?.controller;
    if (controller == null) return const SizedBox.shrink();
    final webview = ColoredBox(
      // Dark underlay so the beat before the platform view first paints (and
      // platforms that ignore setBackgroundColor, e.g. macOS) never flashes
      // white.
      color: context.antgrid.bgDeepest,
      child: WebViewWidget(
        key: ValueKey('preview-${tab.port}'),
        controller: controller,
        // Claim every gesture over the page surface: inside the mobile
        // PageView the platform view otherwise loses the arena to the
        // pager's drag recognizer and web scrolling dies. Page-switching
        // stays available via the bottom nav and swipes outside the webview.
        gestureRecognizers: const {
          Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new),
        },
      ),
    );
    if (!isMobilePlatform) {
      // Same reasoning as the mobile Listener below — sees the raw
      // right-click regardless of what the EagerGestureRecognizer above does
      // with it, without taking the click away from the page.
      return Listener(
        onPointerDown: (e) => _onSecondaryPointerDown(tab.port, e),
        child: webview,
      );
    }
    // A Listener sees every raw pointer regardless of which gesture recognizer
    // wins the arena, so this coexists with the EagerGestureRecognizer above
    // (which still owns the drag for the page's own scrolling) without
    // fighting it — Listener never participates in arena disambiguation.
    return Stack(
      children: [
        Listener(
          onPointerDown: (e) => _onPullDown(tab.port, controller, e),
          onPointerMove: _onPullMove,
          onPointerUp: (_) => _onPullUp(tab.port, controller),
          onPointerCancel: (_) => _cancelPull(),
          child: webview,
        ),
        if (_pullDistance > 0 || _refreshingPort == tab.port)
          Positioned(
            top: AbTokens.space12,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Center(
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 120),
                  opacity: _refreshingPort == tab.port
                      ? 1
                      : (_pullDistance / _kPullRefreshThreshold).clamp(0, 1),
                  child: const AbLoadingDot(size: 16),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Content for [_PreviewScreenState._openOverflowMenu] — mobile's overflow
/// popup for everything besides Back/Forward and the address bar, which stay
/// inline in the toolbar (see [_buildPreviewView]). Every action row performs
/// its effect then pops the route itself (`Navigator.of(context).pop()`, no
/// value); the tab-list section below it is [PreviewTabsPanel] unmodified,
/// whose rows instead pop with the picked port — the caller distinguishes the
/// two by whether the awaited result is non-null.
///
/// Every row is ALWAYS rendered, DISABLED (not hidden) until there's something
/// to act on — opening this menu with nothing open must show what it can do,
/// not come up empty. Same reasoning covers the tab list: [PanelHint] stands
/// in for it while there's nothing to list, so the "Tabs" section itself never
/// disappears either.
///
/// A [ConsumerWidget], not stateless: [showAbPanel] builds this once from the
/// state at open time, but whether a tab is open can change WHILE the menu is
/// up (e.g. closing the last tab from the tab-list section below) — watching
/// [previewStateProvider] directly, the same way [PreviewTabsPanel] already
/// does for its own rows, is what keeps this panel from freezing on a
/// snapshot that stopped being true.
class _PreviewOverflowPanel extends ConsumerWidget {
  const _PreviewOverflowPanel({
    required this.hasActiveTab,
    required this.hasPreviewService,
    required this.onNewPort,
    required this.onRefresh,
    required this.onDraw,
    required this.drawArmed,
    required this.onClosedTab,
  });

  final bool hasActiveTab;

  /// Whether a [PreviewService] was resolved at open time — static rather
  /// than watched, like [hasActiveTab]: unlike the tab list, the service
  /// itself isn't a provider value this widget can watch directly. Gates
  /// "New" the same way desktop's own inline "+" button does — on the
  /// service being resolvable at all, not on a tab already being open.
  final bool hasPreviewService;
  final VoidCallback onNewPort;
  final VoidCallback onRefresh;

  /// Toggles the draw overlay; null while there is no tab to draw on.
  final VoidCallback? onDraw;

  /// Whether the overlay is currently armed — the row latches, the same way
  /// desktop's own inline pencil does, since arming it outlives the popup.
  final bool drawArmed;
  final ValueChanged<int> onClosedTab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void act(VoidCallback action) {
      action();
      Navigator.of(context).pop();
    }

    final hasTabs = ref.watch(
      previewStateProvider.select((s) => s.value?.tabs.isNotEmpty ?? false),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PanelRow(
          icon: AbIcons.add,
          label: 'New',
          selected: false,
          mono: false,
          onTap: hasPreviewService ? () => act(onNewPort) : null,
        ),
        PanelRow(
          icon: AbIcons.draw,
          label: 'Draw on the page',
          selected: drawArmed,
          mono: false,
          onTap: onDraw == null ? null : () => act(onDraw!),
        ),
        PanelRow(
          icon: AbIcons.refresh,
          label: 'Refresh',
          selected: false,
          mono: false,
          onTap: hasActiveTab ? () => act(onRefresh) : null,
        ),
        const PanelSectionHeader('Tabs', mono: false),
        if (hasTabs)
          PreviewTabsPanel(onClosed: onClosedTab)
        else
          const PanelHint('No ports open'),
      ],
    );
  }
}

/// Paints the four corner wedges of a [size]-sized rect in [color] — the
/// area a rounded rect of the same [radius] excludes. Layered OVER plain
/// content (see [_PreviewScreenState._framed]) this reads as rounded
/// corners without ever clipping whatever sits underneath, which matters
/// specifically for the live webview tab: clipping a platform view is what
/// produced a flicker under the panel-expand/restore reparent (see
/// `_framed`'s doc).
class _CornerMaskPainter extends CustomPainter {
  const _CornerMaskPainter({required this.radius, required this.color});

  final double radius;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final outer = Path()..addRect(Offset.zero & size);
    final inner = Path()
      ..addRRect(
        RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)),
      );
    final corners = Path.combine(PathOperation.difference, outer, inner);
    canvas.drawPath(corners, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _CornerMaskPainter oldDelegate) =>
      oldDelegate.radius != radius || oldDelegate.color != color;
}

/// Parses top-bar input for opening a NEW tab: a bare port ("3000"), a
/// scheme-prefixed one ("https://3000"), or a full link to your own dev
/// server ("http://localhost:3000/dashboard", "localhost:8443/docs"). This
/// browser previews YOUR dev-server ports, not arbitrary sites, so an
/// explicit host other than `localhost`/`127.0.0.1` is rejected rather than
/// guessed at — there's no tunnel to reach anything else through anyway.
/// Preserves any path/query/fragment so a pasted link lands where it
/// points, not just at the origin. Standalone (not a method) so it's
/// unit-testable directly, same convention as [formatPickedElement].
@visibleForTesting
(int port, String scheme, String path)? parsePreviewTarget(String input) {
  var s = input.trim();
  if (s.isEmpty) return null;

  var scheme = 'http';
  final schemeMatch = RegExp(r'^(https?)://').firstMatch(s);
  if (schemeMatch != null) {
    scheme = schemeMatch.group(1)!;
    s = s.substring(schemeMatch.end);
  }

  // An explicit host is only ever ours to open if it's localhost — a real
  // external hostname (has a dot, or is anything but `localhost`) means
  // this isn't a link to the user's own dev server.
  final hostMatch = RegExp(r'^([^/:?#]+)').firstMatch(s);
  if (hostMatch != null) {
    final host = hostMatch.group(1)!;
    final looksLikeHost = host == 'localhost' || host.contains('.');
    if (looksLikeHost) {
      if (host != 'localhost' && host != '127.0.0.1') return null;
      s = s.substring(host.length);
      if (s.startsWith(':')) s = s.substring(1);
    }
  }

  final portMatch = RegExp(r'^(\d+)').firstMatch(s);
  if (portMatch == null) return null;
  final port = int.parse(portMatch.group(1)!);
  if (port < 1 || port > 65535) return null;

  final rest = s.substring(portMatch.end);
  return (port, scheme, rest.isEmpty ? '/' : rest);
}

/// Formats a decoded `"picked"` payload from [kElementPickerScript] into a
/// readable text block for [showSendToAgentComment]. Standalone (not a
/// method) so it's unit-testable without any widget/webview scaffolding —
/// `@visibleForTesting` rather than a leading underscore because Dart
/// privacy is per-file, and a test file needs to import and call this
/// directly (same convention as `systemBarStyleFor` in `main.dart`).
///
/// [json] is untrusted — it's parsed from a message posted by arbitrary web
/// content running in the preview. Every field is handled as possibly
/// missing or the wrong type; this never throws.
@visibleForTesting
String formatPickedElement(Map<String, dynamic> json) {
  final tag = json['tag'] is String ? json['tag'] as String : 'element';
  final id = json['id'] is String ? json['id'] as String : null;
  final classes = json['classes'] is List
      ? (json['classes'] as List).whereType<String>().toList()
      : const <String>[];
  final text = json['text'] is String ? json['text'] as String : '';
  final html = json['html'] is String ? json['html'] as String : '';
  final selector = json['selector'] is String
      ? json['selector'] as String
      : null;

  final buffer = StringBuffer();
  final tagLine = StringBuffer('<$tag');
  if (id != null && id.isNotEmpty) tagLine.write(' id="$id"');
  if (classes.isNotEmpty) tagLine.write(' class="${classes.join(' ')}"');
  tagLine.write('>');
  buffer.writeln(tagLine.toString());
  buffer.writeln('Selector: ${selector ?? '(unknown)'}');
  if (text.isNotEmpty) buffer.writeln('Text: "${_recap(text)}"');
  if (html.isNotEmpty) buffer.writeln('HTML: ${_recap(html)}');
  return buffer.toString().trimRight();
}

/// Reads the picked element's box out of a `"picked"` payload, as the rect
/// plus the viewport it was measured in — what [cropImageToRegion] needs to
/// cut the same-moment screenshot down to just that element.
///
/// [json] is untrusted (it is parsed from a message posted by arbitrary web
/// content), so every field is handled as possibly missing or the wrong type,
/// and a zero-area box is treated as absent rather than cropped to nothing.
/// Null means "attach the whole viewport instead", never an error.
///
/// Standalone and `@visibleForTesting` for the same reason
/// [formatPickedElement] is: Dart privacy is per-file, and this is worth
/// testing without any widget/webview scaffolding.
@visibleForTesting
({Rect rect, Size viewport})? pickedRegion(Map<String, dynamic> json) {
  double? number(Object? value) => value is num ? value.toDouble() : null;

  final rect = json['rect'];
  final viewport = json['viewport'];
  if (rect is! Map || viewport is! Map) return null;

  final x = number(rect['x']);
  final y = number(rect['y']);
  final width = number(rect['width']);
  final height = number(rect['height']);
  final vw = number(viewport['width']);
  final vh = number(viewport['height']);
  if (x == null || y == null || width == null || height == null) return null;
  if (vw == null || vh == null) return null;
  if (width <= 0 || height <= 0 || vw <= 0 || vh <= 0) return null;

  return (rect: Rect.fromLTWH(x, y, width, height), viewport: Size(vw, vh));
}

/// Defensive re-cap: the injected script already caps `text`/`html` before
/// sending, but a value this large in a chat message is still worth bounding
/// even if a future script change ships one uncapped.
const int _kFormatCap = 500;

String _recap(String value) =>
    value.length > _kFormatCap ? '${value.substring(0, _kFormatCap)}…' : value;
