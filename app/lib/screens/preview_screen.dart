import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_all/webview_all.dart';

import '../analytics/events.dart';
import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/widgets/ab_confirm_dialog.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_snack_bar.dart';
import '../design/widgets/ab_toolbar.dart';
import '../design/widgets/ab_url_field.dart';
import '../models/preview_models.dart';
import '../providers/analytics.dart';
import '../services/preview_service.dart';
import '../providers/agent_transport.dart';
import '../providers/providers.dart';
import '../util/ab_log.dart';
import '../widgets/port_entry.dart';
import '../widgets/port_list_widget.dart';
import '../widgets/preview_empty_state.dart';
import '../design/widgets/ab_loading.dart';

/// The browser preview screen. Shows detected ports, an embedded webview
/// for the selected port, a URL bar, and a refresh button.
class PreviewScreen extends ConsumerStatefulWidget {
  const PreviewScreen({super.key});

  @override
  ConsumerState<PreviewScreen> createState() => _PreviewScreenState();
}

class _PreviewScreenState extends ConsumerState<PreviewScreen> {
  WebViewController? _webViewController;
  String _currentUrl = '';
  // The webview origin (scheme://localhost:port) for the active preview. In
  // relay mode this is the local proxy's http origin; in local mode it carries
  // the target scheme (http/https). Used to re-anchor address-bar input and as
  // the rebuild key — so a same-port http↔https toggle still reloads.
  String _origin = '';
  // What the address bar presents as the origin: the logical target
  // (`scheme://localhost:<selectedPort>`), not the plain-http proxy origin the
  // webview actually loads — otherwise an https target reads as "http://…"
  // and the real port is hidden behind the proxy's random one. Identical to
  // [_origin] in local mode.
  String _displayOrigin = '';
  bool _canGoBack = false;
  bool _canGoForward = false;

  late final TextEditingController _addrController;
  late final FocusNode _addrFocus;

  @override
  void initState() {
    super.initState();
    _addrController = TextEditingController();
    _addrFocus = FocusNode();
    // Discard unsubmitted edits on blur — restore the live URL.
    // (Select-all-on-focus is handled by AbUrlField.)
    _addrFocus.addListener(() {
      if (!_addrFocus.hasFocus) {
        final display = _toDisplayUrl(_currentUrl);
        if (_addrController.text != display) {
          _addrController.text = display;
        }
      }
    });
  }

  /// Maps a real webview URL onto its user-facing form by swapping the proxy
  /// origin for the logical target origin. Identity when they already match
  /// (local mode) or the URL is foreign to the preview origin.
  String _toDisplayUrl(String url) {
    if (_origin.isEmpty ||
        _displayOrigin.isEmpty ||
        _origin == _displayOrigin) {
      return url;
    }
    if (!url.startsWith(_origin)) return url;
    // Origin boundary: 'http://localhost:5678' must not claim
    // 'http://localhost:56789/...' — the port digits have to end here.
    final rest = url.substring(_origin.length);
    if (rest.isNotEmpty && !'/?#'.contains(rest[0])) return url;
    return '$_displayOrigin$rest';
  }

  /// Build a webview controller anchored at [initialUrl]. JS on; navigation
  /// callbacks mirror the old inappwebview handlers (onPageFinished ←
  /// onLoadStop, onUrlChange ← onUpdateVisitedHistory, onWebResourceError ←
  /// onReceivedError).
  WebViewController _buildController(String initialUrl, Color background) {
    return WebViewController()
      // Without this the webview paints white during page load/navigation — a
      // hard flash in a near-black UI. webview_all silently no-ops this on
      // macOS (native overlay platform view); the ColoredBox underlay in
      // _buildPreviewView covers that gap.
      ..setBackgroundColor(background)
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) => _refreshHistoryFlags(),
          onUrlChange: (change) {
            final url = change.url;
            if (mounted && url != null && url != _currentUrl) {
              setState(() {
                _currentUrl = url;
              });
              _syncAddrField(_toDisplayUrl(url));
            }
            _refreshHistoryFlags();
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

  Future<void> _refreshHistoryFlags() async {
    final ctrl = _webViewController;
    if (ctrl == null) return;
    final results = await Future.wait([ctrl.canGoBack(), ctrl.canGoForward()]);
    if (!mounted) return;
    final back = results[0];
    final fwd = results[1];
    if (back == _canGoBack && fwd == _canGoForward) return;
    setState(() {
      _canGoBack = back;
      _canGoForward = fwd;
    });
  }

  @override
  void dispose() {
    _addrController.dispose();
    _addrFocus.dispose();
    _webViewController = null;
    super.dispose();
  }

  /// Sync the address bar controller with [url] without clobbering an
  /// in-progress edit (focused field).
  void _syncAddrField(String url) {
    if (_addrFocus.hasFocus) return;
    if (_addrController.text == url) return;
    _addrController.text = url;
  }

  /// Resolve user input → a navigable URL. Always re-anchored to the current
  /// proxy origin — pasted full URLs keep only their path/query/fragment so
  /// the address bar can't be used for cross-origin navigation.
  void _navigateToInput(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty || _origin.isEmpty) return;
    String pathAndQuery;
    final parsed = Uri.tryParse(trimmed);
    if (parsed != null && parsed.hasScheme) {
      final q = parsed.hasQuery ? '?${parsed.query}' : '';
      final f = parsed.hasFragment ? '#${parsed.fragment}' : '';
      final p = parsed.path.isEmpty ? '/' : parsed.path;
      pathAndQuery = '$p$q$f';
    } else {
      pathAndQuery = trimmed.startsWith('/') ? trimmed : '/$trimmed';
    }
    final target = '$_origin$pathAndQuery';
    _webViewController?.loadRequest(Uri.parse(target));
    _addrFocus.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final previewStateAsync = ref.watch(previewStateProvider);

    return previewStateAsync.when(
      loading: () => const AbLoading(message: 'loading preview...'),
      error: (error, _) => Center(
        child: Text(
          'Error: $error',
          style: const TextStyle(color: Colors.grey),
        ),
      ),
      data: (state) => _buildContent(state),
    );
  }

  /// Open an arbitrary port through the preview pipeline. Works in both local
  /// (direct localhost) and relay (tunnel proxy) modes — [PreviewService.
  /// selectPort] branches internally. Used by manual entry, recent-port
  /// quick-picks, and the port list. On a relay-mode port conflict, confirms
  /// before falling back to a different local port.
  Future<void> _openPort(int port, String scheme) async {
    // Pin the project this open belongs to. The provider re-reads below are
    // always the currently-focused service (never disposed at the synchronous
    // moment of read), but focus can move across the dialog await — so we
    // re-check it before the fallback rather than acting on a stale service.
    final projectId = ref.read(selectedRegistrationIdProvider);
    try {
      final svc = focusedCheckoutServiceOrNull(ref.container, (s) => s.previewService);
      if (svc == null) return;
      final result = await svc.selectPort(port, scheme: scheme);
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
      await fallbackSvc.selectPortWithFallback(port, scheme: scheme);
      // The fallback path opens a preview too — count it like the direct path.
      ref.read(analyticsServiceProvider)?.track(AnalyticsEvents.previewOpened);
    } on Object catch (e) {
      // selectPort* run a real socket bind; a non-conflict failure (interface
      // down, handles exhausted) throws here. These calls are fire-and-forget
      // at the callers, so surface the error ourselves instead of letting it
      // become an unobserved async error.
      if (!mounted) return;
      showAbSnackBar(context, 'Could not open preview on port $port: $e');
    }
  }

  Widget _buildContent(PreviewState state) {
    // A selected port wins over everything below — a manually-entered port
    // never appears in state.ports, so this check must come before the
    // empty-ports fallback or the webview would never show.
    if (state.selectedPort != null) {
      // Port selected but proxy not ready yet
      if (state.localProxyPort == null) {
        return const AbLoading();
      }

      // Rebuild whenever the origin changes. The origin comes from
      // state.currentUrl (carries the target scheme in local mode; plain-http
      // proxy origin in relay mode), so toggling http↔https on the *same* local
      // port — where localProxyPort is unchanged — still re-anchors and forces
      // the webview to reload.
      final origin =
          state.currentUrl ?? 'http://localhost:${state.localProxyPort}';
      if (_origin != origin) {
        _origin = origin;
        // Present the logical target, not the proxy: in relay mode the webview
        // loads http://localhost:<random proxy port>, but the user selected
        // scheme://localhost:<selectedPort>.
        _displayOrigin = state.selectedPort != null
            ? '${state.scheme}://localhost:${state.selectedPort}'
            : origin;
        _currentUrl = origin;
        _syncAddrField(_toDisplayUrl(_currentUrl));
        // webview_flutter builds the controller eagerly (unlike inappwebview's
        // onWebViewCreated), so recreate it here on every origin change and let
        // the ValueKey below swap the underlying platform view.
        _webViewController = _buildController(origin, context.antgrid.bgDeepest);
      }

      return _buildPreviewView();
    }

    // No ports detected — offer manual entry as the fallback path. Source the
    // project id from the focus provider (not previewServiceProvider) so this
    // build path stays cheap and doesn't construct the session/service.
    if (state.ports.isEmpty) {
      _origin = '';
      _displayOrigin = '';
      _webViewController = null;
      final projectId = ref.watch(selectedRegistrationIdProvider);
      return PreviewEmptyState(
        action: projectId == null
            ? null
            : SizedBox(
                width: 320,
                child: PortEntryForm(
                  projectId: projectId,
                  onSubmit: (port, scheme) =>
                      unawaited(_openPort(port, scheme)),
                ),
              ),
      );
    }

    // Ports available but none selected -- show port list
    _origin = '';
    _displayOrigin = '';
    _webViewController = null;
    return PortListWidget(
      ports: state.ports,
      selectedPort: null,
      onPortSelected: (port, scheme) => unawaited(_openPort(port, scheme)),
    );
  }

  Widget _buildPreviewView() {
    // [previewStateProvider] keeps its last value while it re-runs, so this
    // view can render one frame past a session that was invalidated (host
    // restart, LRU evict) — long enough for a raw façade read to throw during
    // build. Resolve nullably and disable the actions that need the service.
    final preview = focusedCheckoutServiceOrNull(
      ref.container,
      (s) => s.previewService,
    );
    return Column(
      children: [
        AbToolbar.actions(
          leading: [
            AbIconButton(
              icon: AbIcons.list,
              tooltip: 'Show port list',
              onTap: preview == null
                  ? null
                  : () {
                      preview.deselectPort();
                      setState(() {
                        _webViewController = null;
                        _origin = '';
                        _canGoBack = false;
                        _canGoForward = false;
                      });
                    },
            ),
            AbIconButton(
              icon: AbIcons.chevronLeft,
              tooltip: 'Back',
              onTap: _canGoBack ? () => _webViewController?.goBack() : null,
            ),
            AbIconButton(
              icon: AbIcons.chevronRight,
              tooltip: 'Forward',
              onTap: _canGoForward
                  ? () => _webViewController?.goForward()
                  : null,
            ),
          ],
          center: AbUrlField(
            controller: _addrController,
            focusNode: _addrFocus,
            onSubmitted: _navigateToInput,
          ),
          trailing: [
            AbIconButton(
              icon: AbIcons.add,
              tooltip: 'Open a port',
              onTap: preview == null
                  ? null
                  : () => showPortEntryDialog(
                      context,
                      projectId: preview.projectId,
                      onSubmit: (port, scheme) =>
                          unawaited(_openPort(port, scheme)),
                    ),
            ),
            AbIconButton(
              icon: AbIcons.refresh,
              tooltip: 'Refresh',
              onTap: () {
                _webViewController?.reload();
              },
            ),
          ],
        ),
        // WebView. Controller is built eagerly on origin change (see
        // _buildContent); the ValueKey forces a fresh platform view per origin.
        Expanded(
          child: _webViewController == null
              ? const SizedBox.shrink()
              // Dark underlay so the beat before the platform view first
              // paints (and platforms that ignore setBackgroundColor, e.g.
              // macOS) never flashes white.
              : ColoredBox(
                  color: context.antgrid.bgDeepest,
                  child: WebViewWidget(
                    key: ValueKey('preview-$_origin'),
                    controller: _webViewController!,
                    // Claim every gesture over the page surface: inside the
                    // mobile PageView the platform view otherwise loses the
                    // arena to the pager's drag recognizer and web scrolling
                    // dies. Page-switching stays available via the bottom nav
                    // and swipes outside the webview.
                    gestureRecognizers: const {
                      Factory<OneSequenceGestureRecognizer>(
                        EagerGestureRecognizer.new,
                      ),
                    },
                  ),
                ),
        ),
      ],
    );
  }
}
