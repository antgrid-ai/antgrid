import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';

import '../design/ab_tokens.dart';
import '../design/ab_colors.dart';
import '../design/ansi_palette.dart';
import '../design/widgets/ab_snack_bar.dart';
import '../models/terminal_models.dart';
import '../project/project_session.dart';
import '../providers/client_id.dart';
import '../providers/providers.dart';
import '../services/app_settings_service.dart';
import '../services/terminal_service.dart';
import '../util/detached.dart';
import '../util/external_url.dart';
import 'clipboard_image.dart';
import 'send_to_agent_button.dart';
import 'send_to_agent_comment.dart';
import 'terminal_attachment_uploader.dart';
import 'terminal_cell_metrics.dart';
import 'terminal_drop_target.dart';
import 'terminal_hyperlink_preview.dart';
import 'terminal_quick_actions_bar.dart';
import 'terminal_upload_button.dart';
import 'terminal_upload_strip.dart';

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

  /// The clipboard's image side, injected so the paste chord is testable
  /// without a platform clipboard — under `flutter_test` a real read throws
  /// `NoSuchChannelException` rather than answering "no image".
  final Future<ClipboardImage?> Function() readImage;

  const TerminalViewWrapper({
    super.key,
    required this.tab,
    required this.terminalService,
    this.readImage = readClipboardImage,
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

  /// The OSC 8 link under the pointer and where to park its readout, or null
  /// when the pointer is over no link.
  ///
  /// Held here rather than read from the view because the view paints only an
  /// underline: the destination itself is disclosed by
  /// [TerminalHyperlinkPreview] or by nothing at all. A notifier rather than
  /// `setState` because this is the terminal's primary surface and a hover
  /// crossing a wall of links would otherwise relayout the whole panel — three
  /// nested `LayoutBuilder`s and a fresh `GhosttyTerminalView` — per link, to
  /// toggle one floating card. Same shape the sibling upload strip already uses.
  final ValueNotifier<({String uri, Offset at})?> _hoveredLink = ValueNotifier(
    null,
  );

  /// A hovered URI still waiting for the pointer position that produced it.
  ///
  /// The view reports the URI from a `MouseRegion` BELOW this widget's own
  /// hover handler, and Flutter walks a hit-test path child-first — so at the
  /// instant the URI arrives, the position for that same event has not reached
  /// us yet, and on the first hover into the panel there is no earlier position
  /// to fall back on. Parking the URI here until the enclosing handler supplies
  /// the matching position is what keeps the card on the link it describes
  /// rather than one hover behind it.
  String? _pendingHoverUri;

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
  /// (`onCellMetricsChanged`), tagged with the inputs they were measured for.
  ///
  /// The tag is what makes the reported values safe to PREFER over
  /// [measureTerminalCell]: the report arrives a frame after the font inputs
  /// change, so an untagged pair is stale for one frame after every zoom step
  /// and every UI-Size change — the same one-frame wrong grid the synchronous
  /// measurement exists to eliminate.
  ({
    double fontSize,
    FontWeight fontWeight,
    double devicePixelRatio,
    double charWidth,
    double linePixels,
  })?
  _reportedCell;

  /// The reported cell, but only when it was measured for exactly these
  /// inputs; null otherwise, so the caller falls back to measuring itself.
  ({double charWidth, double linePixels})? _reportedCellMatching(
    double fontSize,
    FontWeight fontWeight,
    double devicePixelRatio,
  ) {
    final reported = _reportedCell;
    if (reported == null) return null;
    if (reported.fontSize != fontSize) return null;
    if (reported.fontWeight != fontWeight) return null;
    if (reported.devicePixelRatio != devicePixelRatio) return null;
    return (charWidth: reported.charWidth, linePixels: reported.linePixels);
  }

  /// Our own last measurement, tagged the same way.
  ({
    double fontSize,
    FontWeight fontWeight,
    double devicePixelRatio,
    double charWidth,
    double linePixels,
  })?
  _measuredCell;

  /// [measureTerminalCell], memoized on its inputs.
  ///
  /// The view's report cannot be the only cache: it is dispatched only when the
  /// SNAPPED metrics move, and both are step functions of `fontSize`, so a small
  /// zoom step that lands in the same physical-pixel bucket changes the inputs
  /// and produces no report. `_reportedCell` then keeps a tag that can never
  /// match again and the measurement runs on every build for the life of the
  /// widget — and builds are frequent here (a selection drag rebuilds per
  /// pointer move). Correctness never depended on the report: the fallback is a
  /// hand-mirror of the same measurement, pinned by
  /// `terminal_cell_metrics_contract_test.dart`.
  ({double charWidth, double linePixels}) _measureCellCached(
    double fontSize,
    FontWeight fontWeight,
    double devicePixelRatio,
  ) {
    final memo = _measuredCell;
    if (memo != null &&
        memo.fontSize == fontSize &&
        memo.fontWeight == fontWeight &&
        memo.devicePixelRatio == devicePixelRatio) {
      return (charWidth: memo.charWidth, linePixels: memo.linePixels);
    }
    final cell = measureTerminalCell(
      fontFamily: AbTokens.fontMono,
      fontFamilyFallback: AbTokens.fontMonoFallbacks,
      fontSize: fontSize,
      fontWeight: fontWeight,
      devicePixelRatio: devicePixelRatio,
    );
    _measuredCell = (
      fontSize: fontSize,
      fontWeight: fontWeight,
      devicePixelRatio: devicePixelRatio,
      charWidth: cell.charWidth,
      linePixels: cell.linePixels,
    );
    return cell;
  }

  /// Keeps `GhosttyTerminalView`'s element alive across the branch swaps below.
  ///
  /// The branches build structurally different subtrees (driver grid-freeze vs
  /// non-driver letterbox), so without a key Flutter reconciles by
  /// runtimeType at the same position, fails to match, and UNMOUNTS the view —
  /// taking its selection, focus node, scroll offset, soft-keyboard hooks and
  /// grid bookkeeping with it, for what is a pure layout event that does not
  /// even change the engine geometry. Same failure and same remedy as
  /// `workspace_shell.dart`'s `_agentPanelKey`/`_contextPanelKey`.
  ///
  /// Must stay a `final` field on the State — each mount owns its own. A static
  /// or widget-level key throws "Multiple widgets used the same GlobalKey" the
  /// moment two wrappers are mounted at once, e.g. during the mobile
  /// list-and-detail route transition.
  final GlobalKey _viewKey = GlobalKey();

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

  /// Size the driver's grid is actually rendered at, reported by
  /// `_TerminalGridFreeze`. The PTY's authoritative `cols`/`rows` are derived
  /// from this (not the live viewport) so the size sent to the PTY lands in
  /// lockstep with the locally-rendered grid — see
  /// `_TerminalGridFreeze.onSettled`.
  Size? _renderSize;

  void _onRenderSizeSettled(Size size) {
    if (!mounted || _renderSize == size) return;
    setState(() => _renderSize = size);
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

  /// The one pipeline every attach gesture goes through. Its upload service is
  /// resolved from THIS terminal's own session and checkout rather than from a
  /// focused-* provider: the file has to be staged into the tree the terminal
  /// writes to, and focus can move during a multi-second upload.
  late final TerminalAttachmentUploader _uploader;

  @override
  void initState() {
    super.initState();
    _uploader = TerminalAttachmentUploader(
      // `existingServicesForCheckout`, not `servicesForCheckout` — the latter
      // creates and broadcasts a bundle as a side effect.
      resolveUpload: () {
        final service = widget.terminalService.session
            .existingServicesForCheckout(widget.terminalService.checkoutId)
            ?.uploadService;
        if (service == null) return null;
        // Adapted rather than torn off: the terminal types the absolute path
        // and nothing else, while the rest of [UploadResult] exists for the
        // preview surface, which has no consumer on this path.
        return ({
          required fileName,
          required bytes,
          mimeType,
          onProgress,
        }) async => (await service.upload(
          fileName: fileName,
          bytes: bytes,
          mimeType: mimeType,
          onProgress: onProgress,
        )).path;
      },
      insert: (text) =>
          widget.terminalService.sendInput(widget.tab.terminalId, text),
      onError: (message) {
        if (mounted) showAbSnackBar(context, message);
      },
    );
    FocusManager.instance.addEarlyKeyEventHandler(_handleEarlyKey);
    _focusScope.addListener(_onFocusChange);
  }

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_handleEarlyKey);
    _focusScope.removeListener(_onFocusChange);
    _focusScope.dispose();
    _uploader.dispose();
    _hoveredLink.dispose();
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

  /// Intercepts the paste chord and Ctrl+C (copy / agent-SIGINT shield)
  /// before Ghostty consumes them as control characters, and encodes the
  /// `Alt+<printable>` chords Ghostty's Dart shim drops on the floor.
  ///
  /// Why an EARLY focus-manager handler and not `Shortcuts` or
  /// `HardwareKeyboard.addHandler`: the focus tree dispatches to the focused
  /// descendant first and Ghostty returns `handled` for these chords, so an
  /// ancestor `Focus` / `Shortcuts` never sees them — and a `HardwareKeyboard`
  /// handler cannot preempt either, because Flutter invokes every one of those
  /// "in order regardless of their return value" and then dispatches to the
  /// focus tree anyway (its `true` only suppresses add-to-app native
  /// propagation). Under that mechanism an intercepted Ctrl+V pasted the
  /// clipboard AND sent `^V`. An early handler returning
  /// [KeyEventResult.handled] is the only one that stops the focus tree.
  ///
  /// Why `writeBytes` not `controller.write`: Ghostty's built-in paste
  /// path passes `sanitizePaste: true`, which silently drops multi-line
  /// or control-char-bearing payloads. Pasting raw bytes preserves them.
  KeyEventResult _handleEarlyKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (!_focusScope.hasFocus) return KeyEventResult.ignored;
    _requestUserClaim();

    final keyboard = HardwareKeyboard.instance;
    final ctrl = keyboard.isControlPressed;
    final meta = keyboard.isMetaPressed;
    final shift = keyboard.isShiftPressed;
    // AltGr surfaces as Ctrl+Alt on Windows — the `!ctrl` guards below are what
    // keep AltGr+C (→ ć on some intl layouts) reaching the PTY untouched.
    final alt = keyboard.isAltPressed;

    // The paste chord per platform, matching what each one's terminals use:
    // Cmd+V on macOS/iOS, Ctrl+V on Windows, Ctrl+Shift+V on Linux (GNOME
    // Terminal / Konsole / Ghostty). Linux must leave BARE Ctrl+V to the PTY —
    // agent CLIs bind it themselves, and Claude Code's paste-image shortcut is
    // ctrl+v on every platform except Windows/WSL, where it is alt+v (which
    // the meta-chord branch below now delivers). Shift+Insert is intercepted
    // alongside so every paste chord takes the non-lossy `writeBytes` path
    // rather than Ghostty's `sanitizePaste`.
    final pasteModifier = switch (defaultTargetPlatform) {
      // iPadOS keyboards paste with Cmd+V exactly as macOS does, and Ghostty's
      // own matcher only recognizes Cmd+V on macOS — so without iOS here, an
      // iPad's paste chord reaches nothing at all.
      TargetPlatform.macOS || TargetPlatform.iOS => meta,
      TargetPlatform.linux => ctrl && shift,
      _ => ctrl,
    };
    final isPasteChord =
        (event.logicalKey == LogicalKeyboardKey.keyV && pasteModifier) ||
        (event.logicalKey == LogicalKeyboardKey.insert &&
            shift &&
            defaultTargetPlatform != TargetPlatform.macOS);

    if (isPasteChord && !alt) {
      // Auto-repeat is swallowed, not acted on. A held chord repeats ~30x/s;
      // each repeat would re-read the clipboard (on Windows, re-synthesizing a
      // multi-megabyte PNG from CF_DIB per repeat) and then lose the uploader's
      // single-flight race, and `showAbSnackBar` queues its 4s bars serially —
      // so one second of held key buys a minute of unclearable BUSY toasts.
      // Still `handled`: returning `ignored` would hand Ghostty a `^V`.
      if (event is KeyRepeatEvent) return KeyEventResult.handled;
      // Detached, not a bare `.then`: a clipboard read can reject (no clipboard
      // owner on a headless/Wayland session), and from this callback the
      // discarded future would land on `PlatformDispatcher.onError` as a fatal.
      detached('TerminalView', 'clipboard paste failed', _paste);
      // Consume unconditionally, before knowing WHAT is on the clipboard: the
      // decision needs an async read and this must answer now, so the whole
      // image-or-text choice moves inside `_paste`. Letting the chord through
      // to decide later would hand Ghostty a `^V` alongside whatever we then
      // pasted ourselves.
      return KeyEventResult.handled;
    }

    // Ctrl+C (Ctrl-gated on every platform; Cmd+C stays with Ghostty's
    // native copy on macOS):
    //   selection → copy + swallow (Windows Terminal-style)
    //   no selection, agent running → swallow (don't SIGINT the agent)
    //   otherwise → fall through so the PTY gets ^C
    if (event.logicalKey == LogicalKeyboardKey.keyC && ctrl && !alt) {
      final selection = _selectedText;
      if (selection != null && selection.isNotEmpty) {
        detached(
          'TerminalView',
          'clipboard copy failed',
          () => Clipboard.setData(ClipboardData(text: selection)),
        );
        return KeyEventResult.handled;
      }
      final agentRunning =
          widget.tab.isAgent &&
          widget.tab.sessionState != TerminalSessionState.exited;
      if (agentRunning) return KeyEventResult.handled;
    }

    // Alt+<printable> as an ESC-prefixed chord ("meta sends escape", DEC 1036).
    // Ghostty's engine encodes these correctly, but its Dart shim never hands
    // them over: `ghosttyTerminalLogicalKeyMap` holds only special keys, so a
    // letter resolves to no key enum, and both fallbacks (printable text,
    // control char) bail out the moment Alt is down — the chord reaches the PTY
    // as nothing at all. That silently costs every alt binding an agent CLI
    // has, including Claude Code's alt+v paste-image on Windows.
    //
    // Special keys are excluded via the same map, because Alt+Enter and friends
    // DO reach the engine and are already encoded there; re-encoding them here
    // would double up. Only Windows and Linux opt in: Option+<letter> composes
    // real characters on macOS AND iPadOS (√, ç) — which is why Ghostty's own
    // `macos-option-as-alt` defaults to off — and on Android the Alt layer and
    // the IME already own those keys, so encoding here would double-type them.
    final altChordPlatform =
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux;
    if (alt && !ctrl && !meta && altChordPlatform) {
      final chord = _altChordText(event, shift: shift);
      if (chord != null) {
        widget.tab.ghostty.writeBytes([0x1B, ...utf8.encode(chord)]);
        return KeyEventResult.handled;
      }
    }

    return KeyEventResult.ignored;
  }

  /// Serves one paste chord: an image on the clipboard is uploaded and its
  /// host path typed; anything else pastes as text, exactly as it always has.
  ///
  /// The image probe is scoped to RELAY sessions because intercepting a local
  /// one would be a downgrade: every agent CLI reads the host clipboard itself
  /// and turns the image into a native in-conversation attachment, which beats
  /// a file path it has to open with a read tool. Only when the clipboard and
  /// the agent are on different machines does the image have no way across.
  Future<void> _paste() async {
    if (widget.terminalService.session.mode == ProjectSessionMode.relay) {
      final image = await widget.readImage();
      if (!mounted) return;
      if (image != null) {
        await _uploader.attach(
          bytes: image.bytes,
          fileName: image.fileName,
          mimeType: image.mimeType,
        );
        return;
      }
    }
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (!mounted || text == null || text.isEmpty) return;
    widget.tab.ghostty.writeBytes(utf8.encode(_sanitizePaste(text)));
  }

  /// Text an Alt-modified key should carry after the ESC prefix, or null when
  /// the key has no single-character form (modifiers, F-keys) or is a special
  /// key the Ghostty engine already encodes itself.
  ///
  /// Prefers the platform-reported character so shifted symbols land as typed
  /// (Alt+Shift+1 → `!`), and falls back to the key label for layouts that omit
  /// character metadata under Alt.
  ///
  /// Deliberately ASCII-only. Every binding this exists for (agent CLI alt
  /// chords, `meta sends escape` readline words) is ASCII, while a non-ASCII
  /// character under Alt is the signature of a composed AltGr glyph on a layout
  /// where the platform reports AltGr as a bare right-Alt rather than Ctrl+Alt
  /// — emitting `ESC €` for a plain `€` would corrupt the input. Control
  /// characters are rejected for the same reason: a character-bearing Enter or
  /// Tab would otherwise be encoded twice.
  String? _altChordText(KeyEvent event, {required bool shift}) {
    if (ghosttyTerminalLogicalKey(event.logicalKey) != null) return null;

    final character = event.character ?? '';
    if (character.isNotEmpty) {
      // The platform already resolved this chord to text, so the label fallback
      // must not second-guess it: a composed glyph rejected here has to stay
      // un-intercepted, not be re-derived as the bare key it was typed on.
      if (character.runes.length != 1) return null;
      final code = character.runes.first;
      return (code >= 0x20 && code < 0x7F) ? character : null;
    }

    final label = event.logicalKey.keyLabel;
    if (label.runes.length != 1) return null;
    final code = label.runes.first;
    if (code < 0x20 || code >= 0x7F) return null;
    if (!shift) return label.toLowerCase();
    // Under Shift the label is the UNSHIFTED key, so only letters (whose label
    // is already the shifted form) can be answered from it. Guessing `1` for
    // Alt+Shift+1 would send the wrong byte; sending nothing at least leaves
    // the chord inert rather than corrupting the agent's input.
    final isLetter = code >= 0x41 && code <= 0x5A;
    return isLetter ? label : null;
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

    if (message == null || !mounted) return;
    // `mounted` doesn't imply the focused project still has a resolved session:
    // the comment dialog holds this open indefinitely, and a reconnect or LRU
    // evict in that window makes the façade throw — into a fire-and-forget
    // button callback, so unhandled.
    final svc = focusedCheckoutServiceOrNull(
      ref.container,
      (s) => s.terminalService,
    );
    if (svc == null) return;
    svc.sendToAgentTerminal(message);
    ref.read(switchToAgentProvider)?.call();
    setState(() => _selectedText = null);
    showSentToAgentSnackBar(context);
  }

  @override
  Widget build(BuildContext context) {
    final isExited = widget.tab.sessionState == TerminalSessionState.exited;
    final showStoppedView = !widget.tab.isAgent && isExited;

    return Column(
      children: [
        // Stopped state: centered start button; running: terminal view
        Expanded(
          child: showStoppedView
              ? _buildStoppedView(context)
              : _buildTerminal(context),
        ),

        // Quick-action buttons — only on mobile/web (no physical keyboard)
        if (!_hasPhysicalKeyboard && !showStoppedView)
          ValueListenableBuilder<AttachProgress?>(
            valueListenable: _uploader.progress,
            builder: (context, attach, _) => _buildQuickActions(attach != null),
          ),
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
    // Desktop's only attach route. Mobile already has one in the quick-actions
    // bar, and a LOCAL session needs none: the agent reads the user's own disk,
    // so a path typed by hand or dropped by the OS already works.
    final showAttachButton =
        _hasPhysicalKeyboard &&
        widget.terminalService.session.mode == ProjectSessionMode.relay;
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

    // Scale with the app's UI Size setting (injected as a MediaQuery
    // textScaler): the view lays out its own TextPainters, so the ambient
    // scaler never reaches them — pre-scale the size instead. `_hPad` is
    // deliberately font-independent and must not scale with this.
    final terminalFontSize =
        MediaQuery.textScalerOf(context).scale(AbTokens.fontBody) *
        effectiveZoom;

    // One local feeds both the measurement and the view, so the two are
    // structurally incapable of disagreeing on the weight the cell was sized at.
    final terminalFontWeight = AbTokens.bumpedWeight(
      FontWeight.w400,
      terminalFontSize,
    );
    final dpr = MediaQuery.devicePixelRatioOf(context);
    // Prefer what the view actually reported, but only while it still describes
    // these inputs; otherwise measure the cell ourselves so this frame's grid is
    // already right rather than corrected one frame later.
    final cell =
        _reportedCellMatching(terminalFontSize, terminalFontWeight, dpr) ??
        _measureCellCached(terminalFontSize, terminalFontWeight, dpr);

    final terminalView = GhosttyTerminalView(
      key: _viewKey,
      controller: tab.ghostty,
      autofocus: true,
      // Mobile: taps scroll/read; the IME comes only from the Keyboard
      // quick-action. Desktop has no IME bridge, so `true` is a no-op there.
      showKeyboardOnInteraction: _hasPhysicalKeyboard,
      softKeyboardController: _softKeyboardController,
      fontSize: terminalFontSize,
      // The bundled mono face, so the cell grid measures identically on every
      // platform. Never hardcode a family here: an earlier 'Cascadia Mono'
      // literal silently fell back on macOS — where it isn't installed — to a
      // non-mono face, and the grid measured against the wrong advance.
      fontFamily: AbTokens.fontMono,
      fontFamilyFallback: AbTokens.fontMonoFallbacks,
      // The low-DPI weight bump reaches chrome through monoStyle/sansStyle,
      // but the view paints via its own TextPainters — so it has to be handed
      // in explicitly or the terminal, the surface that matters most here,
      // stays thin on exactly the displays the bump exists for.
      fontWeight: terminalFontWeight,
      boldFontWeight: AbTokens.bumpedWeight(FontWeight.w700, terminalFontSize),
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
      // Without this the package falls back to a bare `launchUrlString`, which
      // uses the platform-default launch mode and reports nothing when it
      // fails. Route through the app's helper so a link opens externally and a
      // failure is visible, and so terminal-authored URIs are scheme-checked.
      // `disclosed` is this widget answering for its own readout, not a guess
      // from the platform: the card is up for THIS uri, so the destination was
      // on screen when the activation landed. A desktop touchscreen, a Shift
      // chord and a link that scrolled out from under a resting pointer all
      // reach here with nothing shown, and all of them get the sheet — which a
      // `defaultTargetPlatform` test silently exempted the first of.
      onOpenHyperlink: (uri) => openTerminalHyperlink(
        context,
        uri,
        disclosed: _hoveredLink.value?.uri == uri,
      ),
      onHyperlinkHover: _onHyperlinkHover,
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
        // Compare-then-setState: the grid width and `_maybeSendResize`'s
        // cols/rows are derived from these during build, so a bare assignment
        // would leave both computing on stale metrics with no corrective
        // rebuild. Stamped with the inputs this report was measured for — the
        // callback is captured per build, so they are the view's own.
        if (!mounted) return;
        final next = (
          fontSize: terminalFontSize,
          fontWeight: terminalFontWeight,
          devicePixelRatio: dpr,
          charWidth: charWidth,
          linePixels: linePixels,
        );
        if (_reportedCell == next) return;
        setState(() => _reportedCell = next);
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
      // Below the Listener so `_requestUserClaim` still fires (it is
      // translucent and joins the hit path regardless of the child), and above
      // everything else so the whole panel — letterbox margins and sub-cell
      // padding strip included — is a valid drop target. Both session modes
      // accept: unlike the paste chord this displaces no native behaviour,
      // because a drop on the terminal does nothing at all today.
      child: TerminalDropTarget(
        attach: _uploader.attach,
        onError: (m) {
          if (mounted) showAbSnackBar(context, m);
        },
        child: ColoredBox(
          color: context.antgrid.bgDeepest,
          child: FocusScope(
            node: _focusScope,
            child: Stack(
              children: [
                // Wraps the terminal, not the whole subtree: this is the
                // Stack's only non-positioned child, so it shares the Stack's
                // origin — which is the space the preview's anchor is read in.
                // Non-opaque so it joins the hit path above the view's own
                // MouseRegion without taking anything from it.
                MouseRegion(
                  opaque: false,
                  onHover: _onHoverPosition,
                  // The view's own exit report cannot be relied on alone: a
                  // MouseRegion unmounted while hovered never fires onExit, and
                  // the branches below swap widget types under the pointer
                  // (grid-freeze vs letterbox), so a card can
                  // outlive the terminal that reported it. This is the one
                  // handler that survives those swaps.
                  onExit: (_) {
                    _pendingHoverUri = null;
                    _hoveredLink.value = null;
                  },
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      _maybeSendResize(
                        tab.terminalId,
                        constraints,
                        amDriver,
                        tab.driverClientId,
                        charWidth: cell.charWidth,
                        lineHeightPx: cell.linePixels,
                      );

                      // Driver → fill the viewport. Pin the grid to the last
                      // settled width via `_TerminalGridFreeze` so transient
                      // resizes (e.g. dragging the agent/workspace divider)
                      // don't spam Ghostty grid resizes —
                      // `ghostty_vte_flutter` doesn't reflow soft-wrapped lines, and
                      // Ink-style TUI redraws (Claude Code) leak stale fragments
                      // when the grid changes underneath them.
                      if (amDriver) {
                        return _TerminalGridFreeze(
                          onSettled: _onRenderSizeSettled,
                          child: terminalView,
                        );
                      }

                      // Non-driver → size the grid to the driver's authoritative
                      // cols AND rows, then letterbox it. No `_TerminalGridFreeze`
                      // here — a viewer must track the authoritative geometry, not
                      // pin a local one.
                      //
                      // Rows matter for the same reason cols do, and the attach
                      // blob is what makes it acute: the agent serializes a screen
                      // exactly `tab.rows` tall, so an engine with FEWER rows
                      // scrolls the blob's opening rows away as it paints and every
                      // absolute cursor move in the live stream that follows lands
                      // short. A phone viewing a desktop-driven terminal is that
                      // case by default.
                      // Through `gridExtentFor` rather than inline: `cells *
                      // metric` does not survive the view's own
                      // `floor((extent - padding) / metric)`, and a cell lost
                      // there is the mismatch this pinning exists to remove.
                      final authWidth = gridExtentFor(
                        cells: tab.cols,
                        metric: cell.charWidth,
                        padding: _hPad,
                      );
                      final authHeight = gridExtentFor(
                        cells: tab.rows,
                        metric: cell.linePixels,
                        padding: _hPad,
                      );
                      // `scaleDown` rather than a scroll view on the overflowing
                      // axis: `GhosttyTerminalView` owns a ScrollController and
                      // vertical drag handlers for its own scrollback, so a
                      // vertical scroll view wrapped around it loses every drag to
                      // the inner scrollable and the rows it exists to reveal
                      // become unreachable. Scaling keeps the whole driver screen
                      // visible with no gesture to arbitrate, and never enlarges —
                      // so the fits case is a plain centred letterbox on both axes.
                      return FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.center,
                        child: SizedBox(
                          width: authWidth,
                          height: authHeight,
                          child: terminalView,
                        ),
                      );
                    },
                  ),
                ),
                // Top-LEFT, deliberately: `SendToAgentButton` owns top-right and
                // both can be live at once, while the bottom edge is where the
                // prompt — and the path this types into it — lands.
                Positioned(
                  top: AbTokens.space8,
                  left: AbTokens.space8,
                  child: ValueListenableBuilder<AttachProgress?>(
                    valueListenable: _uploader.progress,
                    builder: (context, attach, _) => Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (showAttachButton)
                          TerminalAttachOverlayButton(
                            pick: pickUploadFile,
                            onPicked: (picked) => _uploader.attach(
                              bytes: picked.bytes,
                              fileName: picked.name,
                            ),
                            busy: attach != null,
                            onError: (m) {
                              if (mounted) showAbSnackBar(context, m);
                            },
                          ),
                        if (attach != null) ...[
                          if (showAttachButton)
                            const SizedBox(height: AbTokens.space6),
                          TerminalUploadStrip(progress: attach),
                        ],
                      ],
                    ),
                  ),
                ),
                if (showSendButton)
                  SendToAgentButton(onPressed: _onSendToAgent),
                Positioned.fill(
                  child: ValueListenableBuilder<({String uri, Offset at})?>(
                    valueListenable: _hoveredLink,
                    builder: (context, link, _) => link == null
                        ? const SizedBox.shrink()
                        : TerminalHyperlinkPreview(
                            uri: link.uri,
                            anchor: link.at,
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Shows or hides the destination readout as the pointer enters and leaves
  /// links.
  ///
  /// The view fires this only on a real change, so there is no same-value
  /// rebuild to guard against here. A new link is only PENDING until
  /// [_onHoverPosition] supplies the position it was hovered at — see
  /// [_pendingHoverUri] for why the position cannot be read here.
  void _onHyperlinkHover(String? uri) {
    if (!mounted) return;
    if (uri == null) {
      _pendingHoverUri = null;
      _hoveredLink.value = null;
      return;
    }
    _pendingHoverUri = uri;
    // Output can scroll a DIFFERENT link under a STATIONARY pointer, and no
    // hover event follows to carry it — so repoint the card at once against
    // the anchor it already has, rather than let it go on naming a
    // destination the click would not open. The pending URI still re-anchors
    // it on the next real move.
    final shown = _hoveredLink.value;
    if (shown != null && shown.uri != uri) {
      _hoveredLink.value = (uri: uri, at: shown.at);
    }
  }

  /// Anchors a pending link to the pointer position of the event that produced
  /// it.
  ///
  /// Sampled once, at the change, rather than tracked live: a card sliding
  /// under the cursor it belongs to is unreadable, and re-laying it out every
  /// hover frame would be work for nothing.
  void _onHoverPosition(PointerHoverEvent event) {
    final pending = _pendingHoverUri;
    if (pending == null) return;
    _pendingHoverUri = null;
    _hoveredLink.value = (uri: pending, at: event.localPosition);
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
    String? observedDriverClientId, {
    required double charWidth,
    required double lineHeightPx,
  }) {
    // Subtract the view's symmetric padding from BOTH axes so the native grid
    // matches what GhosttyTerminalView._syncGrid actually renders
    // (floor((dim - padding) / cellMetric)). `_hPad` (= padding.horizontal,
    // which equals padding.vertical since the padding is EdgeInsets.all(8))
    // covers the vertical case too — omitting it would send one extra row vs
    // the driver's own render, reintroducing the sent-vs-rendered mismatch this
    // feature exists to eliminate.
    // BOTH axes come from the driver's *rendered* (settled) size so the PTY
    // tracks the grid the engine is actually showing — not the live viewport,
    // which would race ahead of the pinned grid (`_renderSize` via
    // `_TerminalGridFreeze.onSettled`). A claiming view that isn't yet the
    // driver (focus takeover) has no settled size, so it falls back to the
    // live viewport to resize the PTY to its own window.
    //
    // Rows matter as much as cols. A line-oriented TUI only scrolls when the
    // row count moves, which is why rows used to track the live height — but a
    // fullscreen one addresses rows absolutely, so every row the PTY and the
    // local grid disagree on is a line drawn in the wrong place for as long as
    // the disagreement lasts.
    final renderSize = amDriver ? _renderSize : null;
    final widthForCols = renderSize?.width ?? constraints.maxWidth;
    final heightForRows = renderSize?.height ?? constraints.maxHeight;
    final nativeCols = math.max(
      1,
      ((widthForCols - _hPad) / charWidth).floor(),
    );
    final nativeRows = math.max(
      1,
      ((heightForRows - _hPad) / lineHeightPx).floor(),
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

  Widget _buildQuickActions(bool uploadBusy) {
    return TerminalQuickActionsBar(
      softKeyboardController: _softKeyboardController,
      onPick: pickUploadFile,
      onPicked: (picked) =>
          _uploader.attach(bytes: picked.bytes, fileName: picked.name),
      uploadBusy: uploadBusy,
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

/// Pins its child to the most recently *settled* size. While the incoming
/// constraints change every frame (e.g. an active divider drag), the child
/// stays laid out at the last size that held still long enough; once the size
/// is stable for [_settleDelay], the pinned size snaps to the new value and
/// the child relayouts once.
///
/// Both axes are pinned. Width is what soft-wrap and Ink-style redraws depend
/// on, but a fullscreen TUI addresses rows absolutely, so a height that passes
/// through live moves the local grid under a frame the guest composed against
/// the old row count. The grid-centering concern (floor-rounded cell remainder
/// distributed on all four sides) is owned by
/// `GhosttyTerminalView.cellAlignment` and configured at the callsite above.
class _TerminalGridFreeze extends StatefulWidget {
  final Widget child;

  /// Fires (post-frame) with the size the child is actually rendered at, both
  /// on the initial instant pin and after each settle. The driver sources the
  /// PTY's authoritative `cols`/`rows` from this — NOT from the live viewport —
  /// so the size sent to the PTY always matches the grid the engine is
  /// rendering. Sending from the live size instead lets the PTY (and the
  /// agent's SIGWINCH redraw) move to the new geometry while this pinned grid
  /// is still at the old one, corrupting the redraw until a focus round-trip
  /// re-triggers it.
  final ValueChanged<Size>? onSettled;

  const _TerminalGridFreeze({required this.child, this.onSettled});

  @override
  State<_TerminalGridFreeze> createState() => _TerminalGridFreezeState();
}

class _TerminalGridFreezeState extends State<_TerminalGridFreeze> {
  static const _settleDelay = Duration(milliseconds: 150);

  Size? _pinnedSize;
  Timer? _settleTimer;

  @override
  void dispose() {
    _settleTimer?.cancel();
    super.dispose();
  }

  /// Notify the parent of the rendered size without mutating state during
  /// layout (the immediate pin happens inside `build`): defer to post-frame.
  void _notifySettled(Size size) {
    final cb = widget.onSettled;
    if (cb == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) cb(size);
    });
  }

  void _scheduleSettle(Size size) {
    _settleTimer?.cancel();
    _settleTimer = Timer(_settleDelay, () {
      if (!mounted) return;
      setState(() => _pinnedSize = size);
      _notifySettled(size);
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final live = Size(constraints.maxWidth, constraints.maxHeight);
        // Adopt the first observed size instantly so the initial layout
        // doesn't show a 150ms blank flash.
        if (_pinnedSize == null) {
          _pinnedSize = live;
          _notifySettled(live);
        }
        if (_pinnedSize != live) {
          _scheduleSettle(live);
        }
        final inner = _pinnedSize!;
        return ClipRect(
          child: OverflowBox(
            minWidth: inner.width,
            maxWidth: inner.width,
            minHeight: inner.height,
            maxHeight: inner.height,
            alignment: Alignment.topLeft,
            child: widget.child,
          ),
        );
      },
    );
  }
}
