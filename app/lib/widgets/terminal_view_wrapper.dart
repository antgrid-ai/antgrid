import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';

import '../design/ab_status_tone.dart';
import '../design/ab_tokens.dart';
import '../design/ab_colors.dart';
import '../design/ansi_palette.dart';
import '../design/widgets/ab_snack_bar.dart';
import '../design/widgets/ab_status_dot.dart';
import '../models/terminal_models.dart';
import '../providers/client_id.dart';
import '../providers/providers.dart';
import '../services/app_settings_service.dart';
import '../services/terminal_service.dart';
import '../services/upload_service.dart';
import 'send_to_agent_button.dart';
import 'send_to_agent_comment.dart';
import 'terminal_quick_actions_bar.dart';
import 'terminal_upload_button.dart';

/// True on desktop platforms (not web) where a physical keyboard is guaranteed.
final bool _hasPhysicalKeyboard =
    !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

// ANSI color resolution uses `app/lib/design/ansi_palette.dart` — Windows
// Terminal's Campbell, re-solved per-lightness against Antgrid's backgrounds so
// the renderer's contrast floor does not have to collapse normal/bright pairs
// to make it readable. The vendored Ghostty package's own default (misleadingly
// named `xterm`, actually Tokyo Night) has pastel red/yellow/blue that read as
// washed-out, and `campbellPalette` there is untuned — hence this override.

class TerminalViewWrapper extends ConsumerStatefulWidget {
  final TerminalTab tab;
  final TerminalService terminalService;
  final VoidCallback? onDelete;

  const TerminalViewWrapper({
    super.key,
    required this.tab,
    required this.terminalService,
    this.onDelete,
  });

  @override
  ConsumerState<TerminalViewWrapper> createState() =>
      _TerminalViewWrapperState();
}

class _TerminalViewWrapperState extends ConsumerState<TerminalViewWrapper> {
  /// Most-recent text selected in the terminal view. Tracked via Ghostty's
  /// `onSelectionContentChanged` callback so we can show the send-to-agent
  /// overlay button only when the user has a non-empty selection.
  String? _selectedText;

  /// Wraps the terminal subtree so we can detect when the user's primary
  /// focus is inside this view. Required for the paste interceptor, which
  /// must scope its effect to the focused terminal — `HardwareKeyboard`
  /// handlers fire app-wide otherwise.
  final FocusScopeNode _focusScope = FocusScopeNode();

  /// Explicit soft-keyboard handle for mobile. Terminal taps scroll/select
  /// only (`showKeyboardOnInteraction: false`); the IME is summoned solely by
  /// the Keyboard quick-action, so reading output never pops the keyboard.
  final GhosttyTerminalSoftKeyboardController _softKeyboardController =
      GhosttyTerminalSoftKeyboardController();

  /// Exact float cell metrics reported post-frame by Ghostty
  /// (`onCellMetricsChanged`). Null until the first frame settles; the
  /// non-driver branch needs `_charWidth` to size the authoritative grid and
  /// the resize-sender needs both to derive native cols/rows from constraints.
  double? _charWidth;
  double? _lineHeightPx;

  /// True while this view holds primary focus — mirrors `_focusScope.hasFocus`.
  /// Drives the optimistic-driver state: while `driverClientId == null` (no
  /// device has claimed yet) the locally-focused view paints as the driver and
  /// immediately claims; the `terminal:size` echo then makes the authority
  /// explicit and corrects every viewer.
  bool _locallyActive = false;

  /// Whether this view has already sent a claim for the *current* focus
  /// session. Re-armed (false) on every focus-gain so a re-focus re-claims;
  /// stays true across pure relayouts so we don't re-send on every frame.
  bool _claimed = false;

  /// Desktop focus can be restored by rebuild/autofocus without any local user
  /// action. Require an explicit pointer/key activation before a desktop
  /// non-driver view can take terminal-width ownership from another device.
  bool _claimRequestedByUser = false;

  /// Last native (cols, rows) sent, so an `amDriver` view only re-sends when
  /// the local viewport actually changes the native grid.
  int? _lastSentCols;
  int? _lastSentRows;

  /// Width the driver's grid is actually rendered at, reported by
  /// `_TerminalGridFreeze`. The PTY's authoritative `cols` is derived from this
  /// (not the live viewport width) so the size sent to the PTY lands in lockstep
  /// with the locally-rendered grid — see `_TerminalGridFreeze.onSettled`.
  double? _renderWidth;

  void _onRenderWidthSettled(double width) {
    if (!mounted || _renderWidth == width) return;
    setState(() => _renderWidth = width);
  }

  bool get _hasSelection => (_selectedText ?? '').isNotEmpty;

  /// In-flight pinch scale relative to gesture start, applied multiplicatively
  /// over the persisted zoom so text tracks the fingers live. 1.0 between
  /// gestures; committed into the setting only on gesture end (no debounce —
  /// a mid-gesture persist would re-derive font metrics every frame).
  double _liveZoomFactor = 1.0;

  void _onZoomUpdate(double factor) {
    // The package guards its division, but keep the wrapper self-defending:
    // a non-finite or non-positive factor must never reach layout.
    if (!factor.isFinite || factor <= 0) return;
    if (factor == _liveZoomFactor) return;
    setState(() => _liveZoomFactor = factor);
  }

  void _onZoomEnd() {
    final settings = ref.read(appSettingsServiceProvider);
    final target = settings.terminalZoom * _liveZoomFactor;
    if (target.isFinite && target > 0 && _liveZoomFactor != 1.0) {
      // setTerminalZoom clamps to the allowed range and updates provider state
      // synchronously, so resetting the live factor in the same frame cannot
      // flash back to the pre-gesture size.
      ref.read(appSettingsServiceProvider.notifier).setTerminalZoom(target);
    }
    setState(() => _liveZoomFactor = 1.0);
  }

  void _stepZoom(double delta) {
    final current = ref.read(appSettingsServiceProvider).terminalZoom;
    ref
        .read(appSettingsServiceProvider.notifier)
        .setTerminalZoom(current + delta);
  }

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleHardwareKey);
    _focusScope.addListener(_onFocusChange);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleHardwareKey);
    _focusScope.removeListener(_onFocusChange);
    _focusScope.dispose();
    super.dispose();
  }

  /// Tracks focus transitions. On focus-gain, re-arm the claim so the next
  /// LayoutBuilder pass sends a resize that makes this device the driver.
  void _onFocusChange() {
    final active = _focusScope.hasFocus;
    if (active == _locallyActive) return;
    setState(() {
      _locallyActive = active;
      if (active && !_hasPhysicalKeyboard) _claimed = false;
      if (!active) _claimRequestedByUser = false;
    });
  }

  void _requestUserClaim() {
    if (!_hasPhysicalKeyboard) return;
    if (_claimRequestedByUser && !_claimed) return;
    setState(() {
      _claimRequestedByUser = true;
      _claimed = false;
    });
  }

  /// Intercepts Ctrl+V (paste) and Ctrl+C (copy / agent-SIGINT shield)
  /// before Ghostty consumes them as control characters. Without this,
  /// Ctrl+V is invisible to the user (they expect Windows Terminal-style
  /// paste, not literal-next), and Ctrl+C in the agent terminal would
  /// SIGINT-kill the running agent (Claude Code, etc.).
  ///
  /// Why `HardwareKeyboard` instead of a `Shortcuts` wrapper: Flutter's
  /// focus tree dispatches keys to the focused descendant first; Ghostty
  /// returns `handled` for Ctrl+V/Ctrl+C (sends `^V` / `^C`), so an
  /// ancestor `Focus` / `Shortcuts` widget never sees the event.
  /// `HardwareKeyboard` runs before focus dispatch and can preempt.
  ///
  /// Why `writeBytes` not `controller.write`: Ghostty's built-in paste
  /// path passes `sanitizePaste: true`, which silently drops multi-line
  /// or control-char-bearing payloads. Pasting raw bytes preserves them.
  bool _handleHardwareKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    if (!_focusScope.hasFocus) return false;
    _requestUserClaim();

    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    final ctrl =
        keys.contains(LogicalKeyboardKey.controlLeft) ||
        keys.contains(LogicalKeyboardKey.controlRight);
    final meta =
        keys.contains(LogicalKeyboardKey.metaLeft) ||
        keys.contains(LogicalKeyboardKey.metaRight);
    // AltGr surfaces as Ctrl+Alt on Win/Linux — exclude so AltGr+C (→ ć on
    // some intl layouts) reaches the PTY untouched.
    final alt =
        keys.contains(LogicalKeyboardKey.altLeft) ||
        keys.contains(LogicalKeyboardKey.altRight);
    final hasPasteModifier =
        (Platform.isMacOS && meta) || (!Platform.isMacOS && ctrl);

    if (event.logicalKey == LogicalKeyboardKey.keyV &&
        hasPasteModifier &&
        !alt) {
      // Read the clipboard and inject the result. Fire-and-forget — by the
      // time the future resolves the keypress has long since dispatched.
      Clipboard.getData(Clipboard.kTextPlain).then((data) {
        final text = data?.text;
        if (text == null || text.isEmpty) return;
        widget.tab.ghostty.writeBytes(utf8.encode(_sanitizePaste(text)));
      });
      return true; // consume so Ghostty doesn't also send `^V`
    }

    // Ctrl+C (Ctrl-gated on every platform; Cmd+C stays with Ghostty's
    // native copy on macOS):
    //   selection → copy + swallow (Windows Terminal-style)
    //   no selection, agent running → swallow (don't SIGINT the agent)
    //   otherwise → fall through so the PTY gets ^C
    if (event.logicalKey == LogicalKeyboardKey.keyC && ctrl && !alt) {
      final selection = _selectedText;
      if (selection != null && selection.isNotEmpty) {
        Clipboard.setData(ClipboardData(text: selection));
        return true;
      }
      final agentRunning =
          widget.tab.isAgent &&
          widget.tab.sessionState != TerminalSessionState.exited;
      if (agentRunning) return true;
    }

    return false;
  }

  /// Normalizes clipboard text for terminal injection.
  ///
  /// 1. Convert all line endings to CR (`\r`). Terminals receive CR as
  ///    "Enter" — pasting `\n` to most shells does nothing, while CR
  ///    submits each line correctly.
  /// 2. Strip the trailing CR. Without this, copying "git status" from a
  ///    web page (which often appends `\r\n`) auto-executes on paste.
  ///    The user can press Enter explicitly if they want it submitted.
  String _sanitizePaste(String text) {
    final normalized = text.replaceAll('\r\n', '\r').replaceAll('\n', '\r');
    return normalized.endsWith('\r')
        ? normalized.substring(0, normalized.length - 1)
        : normalized;
  }

  Future<void> _onSendToAgent() async {
    final text = _selectedText;
    if (text == null || text.isEmpty) return;

    final sourceLabel = '[from terminal: ${widget.tab.name}]';
    final message = await showSendToAgentComment(
      context: context,
      selectedText: text,
      sourceLabel: sourceLabel,
    );

    if (message != null && mounted) {
      ref.read(terminalServiceProvider).sendToAgentTerminal(message);
      ref.read(switchToAgentProvider)?.call();
      setState(() => _selectedText = null);
      showSentToAgentSnackBar(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isExited = widget.tab.sessionState == TerminalSessionState.exited;
    final showControls = !widget.tab.isAgent;
    final showStoppedView = showControls && isExited;

    return Column(
      children: [
        // Status bar for non-agent terminals
        if (showControls) _buildStatusBar(context, isExited),

        // Stopped state: centered start button; running: terminal view
        Expanded(
          child: showStoppedView
              ? _buildStoppedView(context)
              : _buildTerminal(context),
        ),

        // Quick-action buttons — only on mobile/web (no physical keyboard)
        if (!_hasPhysicalKeyboard && !showStoppedView) _buildQuickActions(),
      ],
    );
  }

  /// WCAG AA floor for terminal text. Render-time only — the painted
  /// foreground is nudged per-cell against that cell's background; the palette
  /// itself (and what the PTY/agent sees) is untouched.
  ///
  /// `ansi_palette.dart` already clears this against every shipped preset
  /// background, so on the default background the floor is nearly inert. It
  /// stays because a static palette cannot cover what remains: cells whose
  /// background the TUI painted itself, 256-color and truecolor output that
  /// bypasses the 16 entries entirely, ANSI 0 used as a foreground, and custom
  /// presets with a mid-tone background.
  static const double _minContrastRatio = 4.5;

  /// Must equal GhosttyTerminalView's own default padding total per axis
  /// (`EdgeInsets.all(8)` → 16px). Subtracted from the viewport before deriving
  /// native cols/rows, and added back when sizing the non-driver authoritative
  /// grid — both rely on this matching what the engine's `_syncGrid` subtracts.
  /// If the package's default padding changes, this drifts silently and the
  /// non-driver grid mismatches the driver again. Keep in lockstep with
  /// `GhosttyTerminalView`'s default `padding`.
  static const double _hPad = AbTokens.space8 * 2;

  Widget _buildTerminal(BuildContext context) {
    final agentTab = ref.watch(agentTerminalProvider);
    final showSendButton = _hasSelection && agentTab != null;
    final myClientId = ref.watch(clientIdProvider).value;

    final tab = widget.tab;
    // Unclaimed (no device has driven this terminal yet) → this view drives and
    // claims, even without keyboard focus. A single client must track its own
    // window the moment the terminal mounts, not wait for focus to land inside
    // it — otherwise resizing the panel before the terminal is focused grows the
    // letterbox while the content stays pinned at the stale spawn `cols`.
    // Claiming an unowned terminal can't steal the role from anyone; once some
    // device owns it (`driverClientId` non-null) only the owner drives, and
    // another device takes over by focusing (the focus-gated claim below). The
    // `terminal:size` echo makes the authority explicit for every viewer.
    final amDriver = tab.driverClientId == null
        ? true
        : tab.driverClientId == myClientId;

    // Persisted zoom × live pinch factor, clamped so an in-flight gesture
    // can't momentarily exceed the range the commit will clamp to anyway.
    final persistedZoom = ref.watch(
      appSettingsServiceProvider.select((s) => s.terminalZoom),
    );
    final effectiveZoom = (persistedZoom * _liveZoomFactor).clamp(
      AppSettingsService.minTerminalZoom,
      AppSettingsService.maxTerminalZoom,
    );

    final terminalView = GhosttyTerminalView(
      controller: tab.ghostty,
      autofocus: true,
      // Mobile: taps scroll/read; the IME comes only from the Keyboard
      // quick-action. Desktop has no IME bridge, so `true` is a no-op there.
      showKeyboardOnInteraction: _hasPhysicalKeyboard,
      softKeyboardController: _softKeyboardController,
      // Scale with the app's UI Size setting (injected as a MediaQuery
      // textScaler): the view lays out its own TextPainters, so the ambient
      // scaler never reaches them — pre-scale the size instead. `_hPad` is
      // deliberately font-independent and must not scale with this.
      fontSize:
          MediaQuery.textScalerOf(context).scale(AbTokens.fontBody) *
          effectiveZoom,
      // Use the design-system mono face per platform (Cascadia Mono on
      // Windows, Menlo on Apple). Hardcoding 'Cascadia Mono' silently fell
      // back on macOS — where it isn't installed — to a non-mono face.
      fontFamily: AbTokens.fontMono,
      fontFamilyFallback: AbTokens.fontMonoFallbacks,
      // Center the sub-cell remainder on all four sides so the
      // leftover-padding strip doesn't accumulate asymmetrically
      // (otherwise a TUI whose bg differs from chrome — e.g.
      // opencode's #0a0a0a vs Antgrid's #09090B — shows a visible
      // strip on the right/bottom only).
      cellAlignment: Alignment.center,
      cursorColor: context.antgrid.textPrimary,
      backgroundColor: context.antgrid.bgDeepest,
      // Palette + foreground picked for the preset's background (see
      // ansi_palette.dart for the tuning). The view pushes them into the
      // Ghostty engine so the native `renderState` path resolves ANSI/256
      // colors against them, AND the formatter path (scrollback fallback)
      // reads the same palette — keeping both paths in sync.
      renderer: GhosttyTerminalRendererMode.renderState,
      foregroundColor: ansiForegroundFor(context.antgrid.bgDeepest),
      palette: ansiPaletteFor(context.antgrid.bgDeepest),
      // Override Ghostty's hardcoded blues with Antgrid's accent so
      // terminal selection/hyperlinks match the rest of the system.
      selectionColor: context.antgrid.accent.withValues(alpha: 0.3),
      hyperlinkColor: context.antgrid.accent,
      showHeader: false,
      showFocusRing: false,
      // Thin terminal-native scrollbar — thumb tracks
      // `borderStrong` so it reads as a 1px accent line against
      // the dark surface; track stays transparent to avoid a
      // chunky gutter.
      showVerticalScrollbar: true,
      scrollbarThickness: 6,
      scrollbarThumbColor: context.antgrid.borderStrong,
      scrollbarTrackColor: const Color(0x00000000),
      minimumContrastRatio: _minContrastRatio,
      onCellMetricsChanged: (charWidth, linePixels) {
        // Compare-then-setState: `_maybeSendResize` derives cols/rows from
        // these during build, so a bare assignment would leave it computing on
        // stale metrics with no corrective rebuild after a font-size change.
        if (!mounted) return;
        if (_charWidth == charWidth && _lineHeightPx == linePixels) return;
        setState(() {
          _charWidth = charWidth;
          _lineHeightPx = linePixels;
        });
      },
      onSelectionContentChanged: (content) {
        final text = content?.text;
        if (text != _selectedText) {
          setState(() => _selectedText = text);
        }
      },
      onZoomUpdate: _onZoomUpdate,
      onZoomEnd: _onZoomEnd,
    );

    // ColoredBox underlay paints `bgDeepest` across the full widget bounds.
    // Ghostty v0.1.3 has a first-paint quirk where its own backgroundColor
    // only covers the computed content rect, leaving the surrounding widget
    // area unpainted until a resize forces a full repaint. The underlay
    // hides this.
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _requestUserClaim(),
      child: ColoredBox(
        color: context.antgrid.bgDeepest,
        child: FocusScope(
          node: _focusScope,
          child: Stack(
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  _maybeSendResize(
                    tab.terminalId,
                    constraints,
                    amDriver,
                    tab.driverClientId,
                  );

                  // Driver (or metrics not yet known) → fill the viewport. Pin
                  // the grid to the last settled width via `_TerminalGridFreeze`
                  // so transient resizes (e.g. dragging the agent/workspace
                  // divider) don't spam Ghostty grid resizes —
                  // `ghostty_vte_flutter` doesn't reflow soft-wrapped lines, and
                  // Ink-style TUI redraws (Claude Code) leak stale fragments
                  // when the grid changes underneath them.
                  final charWidth = _charWidth;
                  if (amDriver || charWidth == null || charWidth <= 0) {
                    return _TerminalGridFreeze(
                      onSettled: _onRenderWidthSettled,
                      child: terminalView,
                    );
                  }

                  // Non-driver → size the grid to the driver's authoritative
                  // cols so wrapping matches exactly. Letterbox (center) when it
                  // fits; horizontal-scroll when the driver is wider than this
                  // viewport. No `_TerminalGridFreeze` here — a viewer must
                  // track the authoritative width, not pin a local one.
                  final authWidth = tab.cols * charWidth + _hPad;
                  final grid = SizedBox(width: authWidth, child: terminalView);
                  return authWidth <= constraints.maxWidth
                      ? Align(alignment: Alignment.center, child: grid)
                      : SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: grid,
                        );
                },
              ),
              if (showSendButton) SendToAgentButton(onPressed: _onSendToAgent),
            ],
          ),
        ),
      ),
    );
  }

  /// Sends a `terminal:resize` derived from the local viewport + cell metrics
  /// when this view just claimed focus, or when it is the driver and its
  /// native grid changed. The send is the SOLE resize source (the engine's
  /// auto-`onResize` was removed). Guarded behind a post-frame callback so it
  /// never mutates state or fires network sends during layout/build.
  void _maybeSendResize(
    String terminalId,
    BoxConstraints constraints,
    bool amDriver,
    String? observedDriverClientId,
  ) {
    final charWidth = _charWidth;
    final lineHeightPx = _lineHeightPx;
    if (charWidth == null || lineHeightPx == null) return;
    if (charWidth <= 0 || lineHeightPx <= 0) return;

    // Subtract the view's symmetric padding from BOTH axes so the native grid
    // matches what GhosttyTerminalView._syncGrid actually renders
    // (floor((dim - padding) / cellMetric)). `_hPad` (= padding.horizontal,
    // which equals padding.vertical since the padding is EdgeInsets.all(8))
    // covers the vertical case too — omitting it would send one extra row vs
    // the driver's own render, reintroducing the sent-vs-rendered mismatch this
    // feature exists to eliminate.
    // Cols come from the driver's *rendered* (settled) width so the PTY tracks
    // the grid the engine is actually showing — not the live viewport, which
    // would race ahead of the pinned grid (`_renderWidth` via
    // `_TerminalGridFreeze.onSettled`). A claiming view that isn't yet the
    // driver (focus takeover) has no settled width, so it falls back to the
    // live width to resize the PTY to its own viewport. Rows are never frozen,
    // so they always track the live height.
    final widthForCols = (amDriver && _renderWidth != null)
        ? _renderWidth!
        : constraints.maxWidth;
    final nativeCols = math.max(
      1,
      ((widthForCols - _hPad) / charWidth).floor(),
    );
    final nativeRows = math.max(
      1,
      ((constraints.maxHeight - _hPad) / lineHeightPx).floor(),
    );

    // Claims fire only on becoming locally-active — a view built without focus
    // must never send a resize that flips `driverClientId` to a device the user
    // isn't actually driving.
    final autoClaiming = !_hasPhysicalKeyboard && _locallyActive && !_claimed;
    final userClaiming = _claimRequestedByUser && !_claimed;
    final claiming = autoClaiming || userClaiming;
    final changed = nativeCols != _lastSentCols || nativeRows != _lastSentRows;
    if (!claiming && !(amDriver && changed)) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (claiming) {
        _claimed = true;
        _claimRequestedByUser = false;
      }
      _lastSentCols = nativeCols;
      _lastSentRows = nativeRows;
      widget.terminalService.sendResize(
        terminalId,
        nativeCols,
        nativeRows,
        baseDriverClientId: observedDriverClientId,
      );
    });
  }

  Widget _buildStoppedView(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.terminal,
            size: 48,
            color: colorScheme.onSurface.withValues(alpha: 0.3),
          ),
          const SizedBox(height: AbTokens.space16),
          Text(
            'Terminal stopped',
            style: TextStyle(
              color: colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(
            height: 24,
          ), // 24px non-ladder vertical breathing room before CTA
          FilledButton.icon(
            onPressed: () =>
                widget.terminalService.requestStart(widget.tab.terminalId),
            icon: const Icon(Icons.play_arrow),
            label: const Text('Start'),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBar(BuildContext context, bool isExited) {
    final colorScheme = Theme.of(context).colorScheme;
    final statusTone = isExited ? AbStatusTone.danger : AbStatusTone.success;
    final statusLabel = isExited
        ? (widget.tab.exitCode != null
              ? 'Exited (code ${widget.tab.exitCode})'
              : 'Exited')
        : 'Running';

    return Container(
      height: AbTokens.rowHeightSm,
      padding: const EdgeInsets.symmetric(horizontal: AbTokens.space12),
      color: colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          AbStatusDot(tone: statusTone, size: AbDotSize.md),
          const SizedBox(width: AbTokens.space8),
          Text(
            statusLabel,
            style: TextStyle(
              fontSize: AbTokens.fontSm,
              color: colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
          const Spacer(),
          if (isExited)
            _controlButton(
              context,
              icon: Icons.play_arrow,
              tooltip: 'Start',
              onPressed: () =>
                  widget.terminalService.requestStart(widget.tab.terminalId),
            ),
          if (widget.onDelete != null)
            _controlButton(
              context,
              icon: Icons.delete_outline,
              tooltip: 'Delete',
              onPressed: widget.onDelete!,
            ),
        ],
      ),
    );
  }

  Widget _controlButton(
    BuildContext context, {
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.all(AbTokens.space4),
          child: Icon(
            icon,
            size: 18,
            color: colorScheme.onSurface.withValues(alpha: 0.7),
          ),
        ),
      ),
    );
  }

  Widget _buildQuickActions() {
    return TerminalQuickActionsBar(
      softKeyboardController: _softKeyboardController,
      onPick: pickUploadFile,
      onUpload: (name, bytes) {
        final svc = serviceWhenReady(ref, uploadServiceProvider);
        if (svc == null) {
          throw const UploadException('OFFLINE', 'Not connected');
        }
        return svc.upload(fileName: name, bytes: bytes);
      },
      onInsertPath: (path) =>
          widget.terminalService.sendInput(widget.tab.terminalId, '"$path" '),
      onUploadError: (m) {
        if (mounted) showAbSnackBar(context, m);
      },
      onSendInput: (data) =>
          widget.terminalService.sendInput(widget.tab.terminalId, data),
      onZoomOut: () => _stepZoom(-0.1),
      onZoomIn: () => _stepZoom(0.1),
      onZoomReset: () =>
          ref.read(appSettingsServiceProvider.notifier).setTerminalZoom(1.0),
    );
  }
}

/// Pins its child to the most recently *settled* width. While the incoming
/// width is changing every frame (e.g. an active divider drag), the child
/// stays laid out at the last width that held still long enough; once the
/// width is stable for [_settleDelay], the pinned width snaps to the new
/// value and the child relayouts once.
///
/// Height passes through live — only width is pinned, which is what matters
/// for terminal soft-wrap / Ink redraw correctness. The grid-centering
/// concern (floor-rounded cell remainder distributed on all four sides) is
/// owned by `GhosttyTerminalView.cellAlignment` and configured at the
/// callsite above.
class _TerminalGridFreeze extends StatefulWidget {
  final Widget child;

  /// Fires (post-frame) with the width the child is actually rendered at, both
  /// on the initial instant pin and after each settle. The driver sources the
  /// PTY's authoritative `cols` from this — NOT from the live viewport width —
  /// so the size sent to the PTY always matches the grid the engine is
  /// rendering. Sending from the live width instead lets the PTY (and the
  /// agent's SIGWINCH redraw) move to the new width while this pinned grid is
  /// still at the old one, corrupting the redraw until a focus round-trip
  /// re-triggers it.
  final ValueChanged<double>? onSettled;

  const _TerminalGridFreeze({required this.child, this.onSettled});

  @override
  State<_TerminalGridFreeze> createState() => _TerminalGridFreezeState();
}

class _TerminalGridFreezeState extends State<_TerminalGridFreeze> {
  static const _settleDelay = Duration(milliseconds: 150);

  double? _pinnedWidth;
  Timer? _settleTimer;

  @override
  void dispose() {
    _settleTimer?.cancel();
    super.dispose();
  }

  /// Notify the parent of the rendered width without mutating state during
  /// layout (the immediate pin happens inside `build`): defer to post-frame.
  void _notifySettled(double width) {
    final cb = widget.onSettled;
    if (cb == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) cb(width);
    });
  }

  void _scheduleSettle(double width) {
    _settleTimer?.cancel();
    _settleTimer = Timer(_settleDelay, () {
      if (!mounted) return;
      setState(() => _pinnedWidth = width);
      _notifySettled(width);
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final live = constraints.maxWidth;
        // Adopt the first observed width instantly so the initial layout
        // doesn't show a 150ms blank flash.
        if (_pinnedWidth == null) {
          _pinnedWidth = live;
          _notifySettled(live);
        }
        if (_pinnedWidth != live) {
          _scheduleSettle(live);
        }
        final inner = _pinnedWidth!;
        return ClipRect(
          child: OverflowBox(
            minWidth: inner,
            maxWidth: inner,
            alignment: Alignment.centerLeft,
            child: widget.child,
          ),
        );
      },
    );
  }
}
