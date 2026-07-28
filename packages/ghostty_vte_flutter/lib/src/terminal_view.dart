import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ghostty_vte/ghostty_vte.dart';

import 'contrast.dart';
import 'keyboard_input.dart';
import 'terminal_auto_scroll_session.dart';
import 'terminal_controller.dart';
import 'terminal_gesture_coordinator.dart';
import 'terminal_interactions.dart';
import 'terminal_pointer_flow.dart';
import 'terminal_render_model.dart';
import 'terminal_snapshot.dart';
import 'terminal_selection_session.dart';

/// Paint backend used by [GhosttyTerminalView].
///
/// [renderState] is the sole renderer: terminal content is painted from the
/// native engine render-state snapshot. The retired formatter-driven mode has
/// been removed. Platforms without a native engine (e.g. web) have no
/// render-state snapshot and therefore paint background only.
enum GhosttyTerminalRendererMode {
  /// Native Ghostty render-state painting for the live viewport. This is the
  /// default and only supported renderer.
  renderState,
}

/// Resolves conflicts between text selection and terminal mouse reporting.
enum GhosttyTerminalInteractionPolicy {
  /// Prefer normal terminal text interactions unless Ghostty mouse reporting is
  /// enabled by the running application.
  auto,

  /// Always prefer Flutter-side text selection, hover, and local viewport
  /// scrolling even if the terminal enables mouse reporting.
  selectionFirst,

  /// Always prefer terminal mouse reporting and suppress Flutter-side
  /// selection, hyperlink activation, and local wheel scrolling.
  terminalMouseFirst,
}

/// Controls how finger drags behave on touch screens.
enum GhosttyTerminalTouchDragBehavior {
  /// Finger drags scroll the terminal transcript; long-press selects text.
  scroll,

  /// Finger drags select text, matching mouse drag behavior.
  selection,
}

/// Builds context-menu buttons for an active terminal text selection.
typedef GhosttyTerminalSelectionContextMenuButtonItemsBuilder =
    List<ContextMenuButtonItem> Function(
      GhosttyTerminalSelectionContextMenuDetails details,
    );

/// Context passed to [GhosttyTerminalSelectionContextMenuButtonItemsBuilder].
final class GhosttyTerminalSelectionContextMenuDetails {
  const GhosttyTerminalSelectionContextMenuDetails({
    required this.selection,
    required this.selectedText,
    required this.defaultButtonItems,
    required this.copySelection,
    required this.selectAll,
    required this.hideToolbar,
  });

  /// Active terminal cell selection.
  final GhosttyTerminalSelection selection;

  /// Plain text resolved from [selection] using the view's copy options.
  final String selectedText;

  /// Default Copy and Select All buttons used by [GhosttyTerminalView].
  final List<ContextMenuButtonItem> defaultButtonItems;

  /// Copies [selectedText] using the view's configured copy behavior.
  final VoidCallback copySelection;

  /// Replaces the current selection with the full terminal transcript.
  final VoidCallback selectAll;

  /// Hides the currently visible selection toolbar.
  final VoidCallback hideToolbar;
}

const double _terminalHeaderHeight = 28.0;

/// Cap for the contrast-floor memo; ~4096 (fg, bg) pairs vastly exceeds any
/// realistic on-screen color population, so hitting it means pathological
/// churn — clearing wholesale is then cheaper than tracking recency.
const int _contrastFloorCacheMaxEntries = 4096;
const Set<PointerDeviceKind> _mouseLikePointerDevices = <PointerDeviceKind>{
  PointerDeviceKind.mouse,
  PointerDeviceKind.stylus,
  PointerDeviceKind.invertedStylus,
  PointerDeviceKind.trackpad,
  PointerDeviceKind.unknown,
};
const Set<PointerDeviceKind> _touchPointerDevices = <PointerDeviceKind>{
  PointerDeviceKind.touch,
};
const double _selectionHandleTouchExtent = 44.0;
const double _selectionHandleVisualRadius = 5.5;
const double _selectionHandleStemHeight = 10.0;
const Key _selectionStartHandleKey = ValueKey<String>(
  'ghostty-terminal-selection-start-handle',
);
const Key _selectionEndHandleKey = ValueKey<String>(
  'ghostty-terminal-selection-end-handle',
);

enum _TerminalSelectionHandleEdge { start, end }

/// Painter-based terminal widget that renders lines from [GhosttyTerminalController].
///
/// The controller keeps a real [VtTerminal] alive, and this widget sizes that
/// VT grid to the available layout while painting the native engine's
/// `renderState` rows (`renderSnapshot.rowsData`) with lightweight Flutter
/// painting. The styled VT formatter snapshot is retained only for line-count /
/// scroll-extent bookkeeping and as a selection-text fallback, not for painting.
class GhosttyTerminalView extends StatefulWidget {
  const GhosttyTerminalView({
    required this.controller,
    super.key,
    this.autofocus = false,
    this.showHeader = true,
    this.showVerticalScrollbar = false,
    this.showFocusRing = true,
    this.scrollController,
    this.scrollPhysics,
    this.autoFollowOnActivity = false,
    this.focusOnInteraction = true,
    this.onTapTerminal,
    this.focusNode,
    this.backgroundColor = const Color(0xFF0A0F14),
    this.foregroundColor = const Color(0xFFE6EDF3),
    this.chromeColor = const Color(0xFF121A24),
    this.fontSize = 14,
    this.lineHeight = 1.35,
    this.fontFamily,
    this.fontFamilyFallback,
    this.fontPackage,
    this.letterSpacing = 0,
    this.cellWidthScale = 1,
    this.renderer = GhosttyTerminalRendererMode.renderState,
    this.padding = const EdgeInsets.all(8),
    this.cellAlignment = Alignment.topLeft,
    this.palette = GhosttyTerminalPalette.xterm,
    this.minimumContrastRatio,
    this.cursorColor = const Color(0xFF9AD1C0),
    this.selectionColor = const Color(0x665DA9FF),
    this.hyperlinkColor = const Color(0xFF61AFEF),
    this.copyOptions = const GhosttyTerminalCopyOptions(),
    this.wordBoundaryPolicy = const GhosttyTerminalWordBoundaryPolicy(),
    this.selectionAutoScrollEdgeInset = 28,
    this.showSelectionContextMenu = true,
    this.selectionContextMenuButtonItemsBuilder,
    this.scrollbarThickness = 10,
    this.scrollbarMinThumbExtent = 24,
    this.scrollbarThumbColor = const Color(0x66FFFFFF),
    this.scrollbarTrackColor = const Color(0x22000000),
    this.interactionPolicy = GhosttyTerminalInteractionPolicy.auto,
    this.touchDragBehavior = GhosttyTerminalTouchDragBehavior.scroll,
    this.onSelectionChanged,
    this.onSelectionContentChanged,
    this.onCopySelection,
    this.onPasteRequest,
    this.onOpenHyperlink,
    this.onCellMetricsChanged,
    this.onZoomUpdate,
    this.onZoomEnd,
  });

  /// Session controller that owns the live VT terminal and process transport.
  final GhosttyTerminalController controller;

  /// Whether the view should request focus automatically when inserted.
  final bool autofocus;

  /// Whether to paint the terminal header/chrome row above the grid.
  final bool showHeader;

  /// Whether to show a local vertical scrollbar for transcript scrolling.
  final bool showVerticalScrollbar;

  /// Whether to paint the 1px focus-state border around the terminal bounds.
  /// Upstream paints a hardcoded `#2A83FF` ring when the view has focus;
  /// set this to `false` when the host app provides its own focus indicator
  /// or the ring clashes with the app palette.
  final bool showFocusRing;

  /// Optional Flutter scroll controller for transcript scrolling.
  final ScrollController? scrollController;

  /// Optional Flutter scroll physics used by the internal scrollable.
  final ScrollPhysics? scrollPhysics;

  /// Whether new terminal activity should snap the viewport back to the live bottom.
  final bool autoFollowOnActivity;

  /// Whether terminal gestures should request focus for keyboard input.
  final bool focusOnInteraction;

  /// Optional callback invoked when the terminal receives a tap interaction.
  final VoidCallback? onTapTerminal;

  /// Optional externally-managed focus node for keyboard input.
  final FocusNode? focusNode;

  /// Terminal background color used for unstyled cells.
  final Color backgroundColor;

  /// Default foreground color used for unstyled text.
  final Color foregroundColor;

  /// Accent color used for terminal chrome such as headers and borders.
  final Color chromeColor;

  /// Base font size in logical pixels for each terminal cell.
  final double fontSize;

  /// Line height multiplier applied to terminal rows.
  final double lineHeight;

  /// Preferred monospace font family for terminal text.
  ///
  /// A bundled monospace font such as `Noto Sans Mono` or `IBM Plex Mono`
  /// gives more consistent terminal text metrics than platform fallback.
  final String? fontFamily;

  /// Fallback font families used when [fontFamily] lacks required glyphs.
  ///
  /// A symbol-oriented fallback such as `Noto Sans Symbols 2` works well for
  /// general-purpose arrows and markers. Terminal primitives such as
  /// box-drawing and block elements may still be rendered by the widget's
  /// custom glyph path for cell-accurate output.
  final List<String>? fontFamilyFallback;

  /// Optional package that provides [fontFamily].
  final String? fontPackage;

  /// Extra tracking applied to terminal glyph layout.
  final double letterSpacing;

  /// Horizontal cell scaling factor used when measuring character advances.
  final double cellWidthScale;

  /// Paint backend used to render terminal cells.
  final GhosttyTerminalRendererMode renderer;

  /// Inner padding between the widget bounds and the terminal grid.
  final EdgeInsets padding;

  /// Where the floor-rounded cell grid sits inside the available content area.
  ///
  /// The grid lays out as whole rows × whole columns, so there's almost
  /// always a sub-cell remainder on one axis. With the default
  /// [Alignment.topLeft], that remainder accumulates on the right and bottom
  /// (matching legacy behavior). [Alignment.center] splits the remainder
  /// equally on all four sides — useful when the surrounding chrome and the
  /// terminal background differ slightly: a single asymmetric strip reads as
  /// "padding" against the chrome, while a centered remainder looks like
  /// intentional inset on all sides. Any [Alignment] is accepted; only the
  /// fractional axis values are used.
  final Alignment cellAlignment;

  /// ANSI and 256-color palette used to resolve terminal color tokens.
  final GhosttyTerminalPalette palette;

  /// Minimum WCAG 2.x contrast ratio enforced between each cell's foreground
  /// and its effective background, applied per-cell at render time to
  /// foregrounds only.
  ///
  /// Null (the default) disables the floor entirely — rendering is identical
  /// to a build without the feature. When set (e.g. `4.5` for WCAG AA),
  /// foregrounds falling below the ratio against the CELL's background (not
  /// the widget default — TUIs paint their own backgrounds) are nudged along
  /// HSL lightness away from the background's luminance until they meet it
  /// (see [ensureMinimumContrast]). The palette, cell backgrounds, and cells
  /// styled invisible (deliberate fg == bg) are never modified.
  final double? minimumContrastRatio;

  /// Cursor fill or stroke color, depending on cursor style.
  final Color cursorColor;

  /// Overlay color used for interactive text selection highlights.
  final Color selectionColor;

  /// Fallback color used when hyperlinks do not specify their own style.
  final Color hyperlinkColor;

  /// Controls how selected cells are converted back into plain text.
  final GhosttyTerminalCopyOptions copyOptions;

  /// Controls how double-click and word-based selections expand.
  final GhosttyTerminalWordBoundaryPolicy wordBoundaryPolicy;

  /// Distance from the viewport edge that triggers auto-scroll during drag selection.
  final double selectionAutoScrollEdgeInset;

  /// Whether touch text selections should show Flutter's adaptive context menu.
  final bool showSelectionContextMenu;

  /// Builds the buttons shown in the touch selection context menu.
  final GhosttyTerminalSelectionContextMenuButtonItemsBuilder?
  selectionContextMenuButtonItemsBuilder;

  /// Visual thickness of the optional vertical scrollbar.
  final double scrollbarThickness;

  /// Minimum logical height of the optional vertical scrollbar thumb.
  final double scrollbarMinThumbExtent;

  /// Fill color for the optional vertical scrollbar thumb.
  final Color scrollbarThumbColor;

  /// Fill color for the optional vertical scrollbar track.
  final Color scrollbarTrackColor;

  /// Controls whether Flutter-side selection or terminal mouse reporting wins
  /// when both could handle the same pointer input.
  final GhosttyTerminalInteractionPolicy interactionPolicy;

  /// Controls whether touch drags scroll the transcript or select text.
  final GhosttyTerminalTouchDragBehavior touchDragBehavior;

  /// Called whenever the active terminal selection changes.
  final ValueChanged<GhosttyTerminalSelection?>? onSelectionChanged;

  /// Called whenever selection text is recomputed for the active selection.
  final ValueChanged<
    GhosttyTerminalSelectionContent<GhosttyTerminalSelection>?
  >?
  onSelectionContentChanged;

  /// Override for copy behavior. When omitted the view writes to the clipboard directly.
  final Future<void> Function(String text)? onCopySelection;

  /// Optional paste callback used instead of reading from the system clipboard.
  final Future<String?> Function()? onPasteRequest;

  /// Callback used when the user activates a hyperlink inside the terminal.
  final Future<void> Function(String uri)? onOpenHyperlink;

  /// Reports the exact (unrounded) cell metrics — character advance width and
  /// line height in logical pixels — whenever they are recomputed. Hosts use
  /// this to size a foreign grid to an exact pixel extent (cols × charWidth)
  /// without the rounding error that `onResize`'s integer `cellWidthPx` carries.
  final void Function(double charWidth, double linePixels)?
  onCellMetricsChanged;

  /// Reports a live zoom gesture (touch pinch or trackpad pinch) as a scale
  /// factor relative to the gesture's start (1.0 = unchanged). The gesture
  /// handling lives inside this view — not the host — because the host cannot
  /// win the pointer against the view's recognizer stack (pan / long-press /
  /// vertical-drag arena claimer) from outside. Null disables pinch handling
  /// entirely: two-finger behavior is identical to a build without the feature.
  final ValueChanged<double>? onZoomUpdate;

  /// Called once when an active zoom gesture ends (a pinch finger lifts or the
  /// trackpad pinch sequence completes). Hosts commit the final factor here.
  final VoidCallback? onZoomEnd;

  @override
  State<GhosttyTerminalView> createState() => _GhosttyTerminalViewState();
}

class _GhosttyTerminalViewState extends State<GhosttyTerminalView> {
  late FocusNode _focusNode;
  late bool _ownsFocusNode;
  late ScrollController _scrollController;
  late bool _ownsScrollController;
  int _scrollOffsetLines = 0;

  /// Sub-line pixel accumulator for trackpad pan-zoom scrolling. Pan-zoom
  /// updates arrive in small fractional-line deltas; we accumulate pixels
  /// here and only emit a `_setScrollOffsetLines` change once the threshold
  /// crosses a full line, carrying the remainder into the next update.
  double _panZoomScrollAccumPx = 0;
  int _lastReportedCols = -1;
  int _lastReportedRows = -1;

  /// Last cell pixel metrics pushed through `controller.resize`. Tracked
  /// separately from cols/rows so a metrics-only change (font size changed but
  /// the grid dimensions happen to match) still re-syncs the engine's
  /// cellWidthPx/cellHeightPx instead of leaving them stale.
  int _lastSyncedCellWidthPx = -1;
  int _lastSyncedCellHeightPx = -1;
  double? _lastMetricCharWidth;
  double? _lastMetricLinePixels;

  /// Latest offset-from-bottom awaiting a single post-frame engine drive.
  int? _pendingEngineOffset;

  /// True while the view is synchronously driving the engine viewport in
  /// response to its OWN scroll. `scrollViewportToOffsetFromBottom` notifies
  /// listeners (`_markDirty`), which re-enters `_onControllerChanged`; without
  /// this guard, `autoFollowOnActivity` would treat a user scroll as new
  /// terminal activity and immediately snap back to the bottom — making it
  /// impossible to scroll up, and oscillating against drag auto-scroll.
  bool _isDrivingEngineViewport = false;

  /// Mirrors the view's offset-from-bottom intent onto the engine viewport so
  /// `renderSnapshot` renders the scrolled rows. Coalesced to once per frame:
  /// `scrollViewportToOffsetFromBottom` reads the engine `scrollbar` (expensive
  /// for arbitrary pins, PageList.zig:2297) and a fling fires the drive every
  /// frame, so we stash the target and flush once after the frame.
  ///
  /// Consequence: during continuous scrolling the rendered rows can trail the
  /// scrollbar thumb by one frame, since the engine drive lands after this
  /// frame's paint. This is an accepted tradeoff of coalescing — the
  /// alternative (a synchronous drive in the scroll callback) fights Flutter's
  /// build/layout/paint lifecycle.
  void _driveEngineViewport(int offsetFromBottom) {
    final alreadyScheduled = _pendingEngineOffset != null;
    _pendingEngineOffset = offsetFromBottom;
    if (alreadyScheduled) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _pendingEngineOffset;
      _pendingEngineOffset = null;
      if (mounted && target != null) {
        _isDrivingEngineViewport = true;
        try {
          widget.controller.scrollViewportToOffsetFromBottom(target);
        } finally {
          _isDrivingEngineViewport = false;
        }
      }
    });
  }

  int _lastVisibleStartLine = 0;
  double _lastMeasuredLinePixels = 1;
  final GhosttyTerminalSelectionSession<GhosttyTerminalSelection>
  _selectionSession =
      GhosttyTerminalSelectionSession<GhosttyTerminalSelection>();
  final GhosttyTerminalAutoScrollSession<_TerminalMetrics> _autoScrollSession =
      GhosttyTerminalAutoScrollSession<_TerminalMetrics>();
  final _TerminalTextPainterCache _nativeRunPainterCache =
      _TerminalTextPainterCache(maxEntries: 512);
  final _TerminalTextIntrinsicWidthCache _nativeRunIntrinsicWidthCache =
      _TerminalTextIntrinsicWidthCache(maxEntries: 1024);

  /// (fg ARGB, effective-bg ARGB) → contrast-floored foreground memo for
  /// [GhosttyTerminalView.minimumContrastRatio]. State-owned (the painter is
  /// rebuilt every frame) so it survives repaints; cleared wholesale in
  /// [didUpdateWidget] when the inputs that determine an entry's validity
  /// change. The ratio itself is NOT part of the key for that same reason.
  final HashMap<(int, int), Color> _contrastFloorCache =
      HashMap<(int, int), Color>();
  ContextMenuController? _selectionContextMenuController;
  int _pendingSerialTapCount = 0;
  PointerDeviceKind _lastPointerKind = PointerDeviceKind.mouse;
  bool _touchSelectionActive = false;
  bool _touchSelectionHandlesVisible = false;

  // --- Touch → terminal-mouse forwarding (mobile) ---
  // When the running program has enabled mouse reporting, one finger drives the
  // TUI the way a mouse drives it on desktop: a tap is a click, a swipe is the
  // scroll wheel. The button PRESS is deferred to pointer-up so a swipe scrolls
  // (wheel) instead of registering a spurious click-drag under the finger. A
  // long-press still selects locally (TUIs never claim long-press), so copy /
  // send-to-agent keeps working while mouse mode is on. Desktop mice never take
  // this path — it is gated on `PointerDeviceKind.touch`.
  //
  // The plain-scrollback and mouse-forward paths share one active-gesture object
  // (they never run at once — mouse reporting decides the role). A single owner
  // is what keeps a second finger from corrupting the tracked finger's state;
  // see `_TouchGesture`. Null between gestures.
  _TouchGesture? _active;

  // --- Pinch-to-zoom (touch + trackpad) ---
  // Fed by the raw Listener, which sees every pointer regardless of gesture
  // arena — the single-tracked `_TouchGesture` above deliberately ignores a
  // second finger, so pinch needs its own per-pointer position ledger. Only
  // populated while `widget.onZoomUpdate` is non-null.
  final Map<int, Offset> _zoomPointerPositions = <int, Offset>{};

  /// The two pointer ids driving the active touch pinch; null = no pinch.
  (int, int)? _zoomPinchPointers;
  double _zoomPinchInitialDistance = 0;

  /// True from the first scaled trackpad pan-zoom update until the gesture
  /// ends: once a pan-zoom sequence reads as a pinch, its remaining updates
  /// must not also scroll (a pinch always carries small pan deltas).
  bool _trackpadZoomActive = false;

  /// Minimum deviation from 1.0 before a pan-zoom sequence latches as a pinch.
  /// The platform reports a scale on every update, and a two-finger SCROLL
  /// rides at ~1.0 with incidental drift; an exact `!= 1.0` test would let one
  /// jittery sample latch zoom mode for the rest of the gesture and kill
  /// scrolling outright.
  static const double _trackpadZoomDeadband = 0.01;

  bool get _pinchZoomActive => _zoomPinchPointers != null;

  /// Below this start distance a scale quotient is numerically meaningless
  /// (two fingers landing on the same spot) — never divide by it.
  static const double _zoomMinInitialDistance = 1.0;

  bool _touchLongPressSelecting = false;
  _TerminalSelectionHandleEdge? _selectionHandleDragEdge;
  Offset? _lastSelectionHandleDragPosition;
  GhosttyTerminalSelection? _wordSelectionAnchor;
  _TerminalSelectionGranularity _dragSelectionGranularity =
      _TerminalSelectionGranularity.cell;
  late final GhosttyTerminalGestureCoordinator<
    GhosttyTerminalCellPosition,
    GhosttyTerminalSelection
  >
  _gestureCoordinator =
      GhosttyTerminalGestureCoordinator<
        GhosttyTerminalCellPosition,
        GhosttyTerminalSelection
      >(_selectionSession);

  GhosttyTerminalSelection? get _selection => _selectionSession.selection;
  String? get _hoveredHyperlink => _selectionSession.hoveredHyperlink;
  int? get _lineSelectionAnchorRow => _selectionSession.lineSelectionAnchorRow;

  void _recordSerialTapDown(SerialTapDownDetails details) {
    _pendingSerialTapCount = details.count;
  }

  /// Bridges the platform soft keyboard (IME) to terminal stdin on touch
  /// devices. Null on desktop/web, where `HardwareKeyboard` already delivers
  /// physical keys and no on-screen keyboard exists. See
  /// [_GhosttyTerminalSoftKeyboard] for why a bare [FocusNode] is not enough.
  _GhosttyTerminalSoftKeyboard? _softKeyboard;

  /// Whether this platform needs the IME bridge to type. A [FocusNode] gaining
  /// focus wires up `HardwareKeyboard` but never attaches a text-input client,
  /// so on Android/iOS the on-screen keyboard would otherwise never appear.
  bool get _needsSoftKeyboard {
    if (kIsWeb) {
      return false;
    }
    final platform = defaultTargetPlatform;
    return platform == TargetPlatform.android || platform == TargetPlatform.iOS;
  }

  @override
  void initState() {
    super.initState();
    _focusNode = widget.focusNode ?? FocusNode();
    _ownsFocusNode = widget.focusNode == null;
    _focusNode.addListener(_handleFocusChangedForSoftKeyboard);
    _scrollController = widget.scrollController ?? ScrollController();
    _ownsScrollController = widget.scrollController == null;
    _scrollController.addListener(_onScrollControllerChanged);
    widget.controller.addListener(_onControllerChanged);
    if (_needsSoftKeyboard) {
      _softKeyboard = _GhosttyTerminalSoftKeyboard(
        onInsert: _writeUserText,
        onBackspace: _sendBackspace,
        onEnter: _sendEnter,
      );
    }
    _syncEngineColors();
  }

  /// Shows the soft keyboard while the terminal holds focus and hides it when
  /// focus leaves — the IME connection is only meaningful while the user is
  /// actually driving this terminal.
  void _handleFocusChangedForSoftKeyboard() {
    final keyboard = _softKeyboard;
    if (keyboard == null) {
      return;
    }
    if (_focusNode.hasFocus) {
      keyboard.show();
    } else {
      keyboard.hide();
    }
  }

  /// Writes IME-inserted text to the PTY, matching [_handleKey]'s side effects
  /// (snap to live bottom, drop any active selection) so typed input behaves
  /// identically whether it arrives from a hardware key or the soft keyboard.
  void _writeUserText(String text) {
    _jumpToLiveBottom();
    if (_selection != null) {
      _setSelection(null);
    }
    widget.controller.write(text);
  }

  void _sendBackspace() {
    _jumpToLiveBottom();
    if (_selection != null) {
      _setSelection(null);
    }
    widget.controller.sendKey(
      key: GhosttyKey.GHOSTTY_KEY_BACKSPACE,
      unshiftedCodepoint: 0,
    );
  }

  void _sendEnter() {
    _jumpToLiveBottom();
    if (_selection != null) {
      _setSelection(null);
    }
    widget.controller.sendKey(
      key: GhosttyKey.GHOSTTY_KEY_ENTER,
      unshiftedCodepoint: 0,
    );
  }

  /// Pushes the view's color params into the controller's terminal engine so
  /// the native `renderState` render path resolves ANSI/256 colors against the
  /// widget's palette instead of the engine's built-in theme.
  ///
  /// `expandAnsiToEnginePalette` requires exactly 16 ANSI colors (the
  /// documented [GhosttyTerminalPalette] contract). This debug assert is the
  /// enforcement point for that invariant: misuse fails loudly in
  /// debug/test/CI. In release it degrades gracefully — rather than crashing,
  /// it skips the engine push for a malformed palette. On web the controller's
  /// `applyEngineColors` is a no-op.
  void _syncEngineColors() {
    final ansi = widget.palette.ansi;
    if (ansi.length != 16) {
      assert(
        false,
        '_syncEngineColors: palette has ${ansi.length} colors, expected 16; '
        'skipping.',
      );
      return;
    }
    widget.controller.applyEngineColors(
      ansiPalette: ansi,
      foreground: widget.foregroundColor,
      background: widget.backgroundColor,
      cursor: widget.cursorColor,
    );
  }

  @override
  void didUpdateWidget(covariant GhosttyTerminalView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      _lastReportedCols = -1;
      _lastReportedRows = -1;
      _lastSyncedCellWidthPx = -1;
      _lastSyncedCellHeightPx = -1;
      _scrollOffsetLines = 0;
      // Abandon any in-flight touch gesture: its remaining moves and deferred
      // tap belong to the old terminal, not the one being attached.
      _resetActiveGesture();
      _setSelection(null);
      _removeSelectionContextMenu();
      _touchSelectionHandlesVisible = false;
      _selectionHandleDragEdge = null;
      _lastSelectionHandleDragPosition = null;
      _selectionSession.reset();
      _autoScrollSession.reset();
    }
    if (oldWidget.focusNode != widget.focusNode) {
      _focusNode.removeListener(_handleFocusChangedForSoftKeyboard);
      if (_ownsFocusNode) {
        _focusNode.dispose();
      }
      _focusNode = widget.focusNode ?? FocusNode();
      _ownsFocusNode = widget.focusNode == null;
      _focusNode.addListener(_handleFocusChangedForSoftKeyboard);
      _handleFocusChangedForSoftKeyboard();
    }
    if (oldWidget.scrollController != widget.scrollController) {
      _scrollController.removeListener(_onScrollControllerChanged);
      if (_ownsScrollController) {
        _scrollController.dispose();
      }
      _scrollController = widget.scrollController ?? ScrollController();
      _ownsScrollController = widget.scrollController == null;
      _scrollController.addListener(_onScrollControllerChanged);
    }
    if (oldWidget.copyOptions != widget.copyOptions && _selection != null) {
      ghosttyTerminalNotifySelectionContent<GhosttyTerminalSelection>(
        selection: _selection,
        resolveText: _resolveSelectionText,
        onSelectionContentChanged: widget.onSelectionContentChanged,
      );
    }
    if (oldWidget.showSelectionContextMenu &&
        !widget.showSelectionContextMenu) {
      _removeSelectionContextMenu();
    }
    if (oldWidget.palette != widget.palette ||
        oldWidget.foregroundColor != widget.foregroundColor ||
        oldWidget.backgroundColor != widget.backgroundColor ||
        oldWidget.cursorColor != widget.cursorColor ||
        oldWidget.controller != widget.controller) {
      _syncEngineColors();
    }
    if (oldWidget.minimumContrastRatio != widget.minimumContrastRatio ||
        oldWidget.palette != widget.palette ||
        oldWidget.backgroundColor != widget.backgroundColor) {
      // Entries were floored against the old ratio / default background (a
      // palette change re-resolves the engine colors the fg keys came from),
      // so every memoized value may now be wrong — drop them all. Painted-run
      // TextPainter caches key on the final color, so they self-invalidate.
      _contrastFloorCache.clear();
    }
  }

  @override
  void dispose() {
    _removeSelectionContextMenu();
    _stopAutoScroll();
    _softKeyboard?.hide();
    widget.controller.removeListener(_onControllerChanged);
    _scrollController.removeListener(_onScrollControllerChanged);
    if (_ownsScrollController) {
      _scrollController.dispose();
    }
    _focusNode.removeListener(_handleFocusChangedForSoftKeyboard);
    if (_ownsFocusNode) {
      _focusNode.dispose();
    }
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) {
      return;
    }
    if (_selection != null) {
      ghosttyTerminalNotifySelectionContent<GhosttyTerminalSelection>(
        selection: _selection,
        resolveText: _resolveSelectionText,
        onSelectionContentChanged: widget.onSelectionContentChanged,
      );
    }
    if (widget.autoFollowOnActivity && !_isDrivingEngineViewport) {
      _jumpToLiveBottom();
    }
    setState(() {});
  }

  void _onScrollControllerChanged() {
    if (!mounted || _lastMeasuredLinePixels <= 0) {
      return;
    }
    final nextOffsetLines = (_scrollController.offset / _lastMeasuredLinePixels)
        .round();
    if (nextOffsetLines == _scrollOffsetLines) {
      return;
    }
    setState(() {
      _scrollOffsetLines = nextOffsetLines;
    });
    _driveEngineViewport(nextOffsetLines);
  }

  bool _resetScrollOffsetToBottom() {
    setState(() {
      _scrollOffsetLines = 0;
    });
    _driveEngineViewport(0);
    return true;
  }

  bool _jumpToLiveBottom() {
    if (_scrollController.hasClients) {
      if (_scrollController.offset.abs() >= 0.5) {
        _scrollController.jumpTo(0);
        return true;
      }
      if (_scrollOffsetLines != 0) {
        return _resetScrollOffsetToBottom();
      }
      return false;
    }

    if (_scrollOffsetLines != 0) {
      return _resetScrollOffsetToBottom();
    }
    return false;
  }

  KeyEventResult _handleKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final modifiers = GhosttyTerminalModifierState.fromHardwareKeyboard();

    if (ghosttyTerminalMatchesCopyShortcut(
      event.logicalKey,
      modifiers: modifiers,
      platform: defaultTargetPlatform,
    )) {
      final text = _selectionText();
      if (text.isNotEmpty) {
        unawaited(_copySelection(text));
        return KeyEventResult.handled;
      }
    }
    if (ghosttyTerminalMatchesClearSelectionShortcut(
          event.logicalKey,
          modifiers: modifiers,
        ) &&
        _selection != null) {
      _setSelection(null);
      return KeyEventResult.handled;
    }
    if (ghosttyTerminalMatchesSelectAllShortcut(
      event.logicalKey,
      modifiers: modifiers,
      platform: defaultTargetPlatform,
    )) {
      final selection = widget.controller.snapshot.selectAllSelection();
      if (selection != null) {
        _setSelection(selection, touchSelectionHandlesVisible: false);
        return KeyEventResult.handled;
      }
    }
    if (ghosttyTerminalMatchesPasteShortcut(
      event.logicalKey,
      modifiers: modifiers,
      platform: defaultTargetPlatform,
    )) {
      unawaited(_pasteClipboard());
      return KeyEventResult.handled;
    }

    final key = ghosttyTerminalLogicalKey(event.logicalKey);
    final mods = modifiers.ghosttyMask;
    final character = ghosttyTerminalPrintableText(event, modifiers: modifiers);
    final controlText = ghosttyTerminalControlText(event, modifiers: modifiers);

    // When the IME soft-keyboard bridge is attached (mobile), the platform
    // delivers plain text, Backspace, and Enter through the input connection
    // (see [_GhosttyTerminalSoftKeyboard]). A hardware/Bluetooth keyboard also
    // surfaces those as raw KeyEvents here, so handling both paths would type
    // every character twice. Defer them to the IME; keep control chords,
    // navigation/function keys, and copy/paste shortcuts (which the IME does
    // not deliver). The whole guard is inert on desktop/web where
    // `_softKeyboard` is null.
    final imeOwnsText = _softKeyboard?.isActive ?? false;
    final plainChord =
        !modifiers.controlPressed &&
        !modifiers.altPressed &&
        !modifiers.metaPressed;

    if (key != null) {
      if (imeOwnsText &&
          plainChord &&
          (key == GhosttyKey.GHOSTTY_KEY_ENTER ||
              key == GhosttyKey.GHOSTTY_KEY_BACKSPACE)) {
        return KeyEventResult.ignored;
      }
      _jumpToLiveBottom();
      if (_selection != null) {
        _setSelection(null);
      }
      // Special keys are encoded from the key enum/modifier state alone.
      // Forwarding printable text metadata here breaks keys like backspace.
      final sent = widget.controller.sendKey(
        key: key,
        action: event is KeyRepeatEvent
            ? GhosttyKeyAction.GHOSTTY_KEY_ACTION_REPEAT
            : GhosttyKeyAction.GHOSTTY_KEY_ACTION_PRESS,
        mods: mods,
        utf8Text: '',
        unshiftedCodepoint: 0,
      );
      return sent ? KeyEventResult.handled : KeyEventResult.ignored;
    }

    if (character.isNotEmpty) {
      if (imeOwnsText) {
        return KeyEventResult.ignored;
      }
      _jumpToLiveBottom();
      if (_selection != null) {
        _setSelection(null);
      }
      final sent = widget.controller.write(character);
      return sent ? KeyEventResult.handled : KeyEventResult.ignored;
    }

    if (controlText != null && controlText.isNotEmpty) {
      _jumpToLiveBottom();
      if (_selection != null) {
        _setSelection(null);
      }
      final sent = widget.controller.write(controlText);
      return sent ? KeyEventResult.handled : KeyEventResult.ignored;
    }

    return KeyEventResult.ignored;
  }

  Future<void> _copySelection(String text) async {
    await ghosttyTerminalCopyText(
      text,
      onCopySelection: widget.onCopySelection,
    );
  }

  Future<void> _pasteClipboard() async {
    final text = await ghosttyTerminalReadPasteText(
      onPasteRequest: widget.onPasteRequest,
    );
    if (text == null || text.isEmpty) {
      return;
    }
    widget.controller.write(text, sanitizePaste: true);
  }

  String _selectionText() {
    final selection = _selection;
    if (selection == null) {
      return '';
    }
    return _resolveSelectionText(selection);
  }

  String _resolveSelectionText(GhosttyTerminalSelection selection) {
    final renderSnapshot = widget.controller.renderSnapshot;
    if (widget.renderer == GhosttyTerminalRendererMode.renderState &&
        renderSnapshot != null &&
        renderSnapshot.hasViewportData) {
      return _renderSnapshotTextForSelection(
        renderSnapshot,
        selection,
        viewportStartLine: _lastVisibleStartLine,
        options: widget.copyOptions,
      );
    }
    return widget.controller.snapshot.textForSelection(
      selection,
      options: widget.copyOptions,
    );
  }

  String? _resolveHyperlinkUriAt(GhosttyTerminalCellPosition position) {
    final renderSnapshot = widget.controller.renderSnapshot;
    if (widget.renderer == GhosttyTerminalRendererMode.renderState &&
        renderSnapshot != null &&
        renderSnapshot.hasViewportData) {
      final uri = _renderSnapshotHyperlinkAt(
        renderSnapshot,
        position,
        viewportStartLine: _lastVisibleStartLine,
      );
      if (uri != null) {
        return uri;
      }
    }
    return widget.controller.snapshot.hyperlinkAt(position);
  }

  GhosttyTerminalSelection? _resolveWordSelectionAt(
    GhosttyTerminalCellPosition position,
  ) {
    final renderSnapshot = widget.controller.renderSnapshot;
    if (widget.renderer == GhosttyTerminalRendererMode.renderState &&
        renderSnapshot != null &&
        renderSnapshot.hasViewportData) {
      return _renderSnapshotWordSelectionAt(
        renderSnapshot,
        position,
        viewportStartLine: _lastVisibleStartLine,
        policy: widget.wordBoundaryPolicy,
      );
    }
    return widget.controller.snapshot.wordSelectionAt(
      position,
      policy: widget.wordBoundaryPolicy,
    );
  }

  // [walkWrapChain] false selects only the given visual rows (touch long-press);
  // true grows the span across the soft-wrapped logical line (desktop line
  // selection). The non-render snapshot path already selects only the given
  // rows, so it ignores the flag.
  GhosttyTerminalSelection? _resolveLineSelectionBetweenRows(
    int baseRow,
    int extentRow, {
    bool walkWrapChain = true,
  }) {
    final renderSnapshot = widget.controller.renderSnapshot;
    if (widget.renderer == GhosttyTerminalRendererMode.renderState &&
        renderSnapshot != null &&
        renderSnapshot.hasViewportData) {
      return _renderSnapshotLineSelectionBetweenRows(
        renderSnapshot,
        baseRow,
        extentRow,
        viewportStartLine: _lastVisibleStartLine,
        walkWrapChain: walkWrapChain,
      );
    }
    return widget.controller.snapshot.lineSelectionBetweenRows(
      baseRow,
      extentRow,
    );
  }

  void _setSelection(
    GhosttyTerminalSelection? selection, {
    bool? touchSelectionHandlesVisible,
  }) {
    final previousSelection = _selection;
    if (!_selectionSession.updateSelection(selection)) {
      return;
    }
    if (selection == null) {
      _removeSelectionContextMenu();
      _touchSelectionHandlesVisible = false;
      _selectionHandleDragEdge = null;
      _lastSelectionHandleDragPosition = null;
    } else if (touchSelectionHandlesVisible != null) {
      _touchSelectionHandlesVisible = touchSelectionHandlesVisible;
    }
    setState(() {});
    ghosttyTerminalNotifySelectionChange<GhosttyTerminalSelection>(
      previousSelection: previousSelection,
      nextSelection: _selection,
      resolveText: _resolveSelectionText,
      onSelectionChanged: widget.onSelectionChanged,
      onSelectionContentChanged: widget.onSelectionContentChanged,
    );
  }

  void _removeSelectionContextMenu() {
    _selectionContextMenuController?.remove();
    _selectionContextMenuController = null;
  }

  void _showSelectionContextMenu({
    required Size size,
    required _TerminalMetrics metrics,
    Offset? fallbackLocalPosition,
  }) {
    if (!widget.showSelectionContextMenu || !mounted) {
      return;
    }
    final selection = _selection;
    if (selection == null || _resolveSelectionText(selection).isEmpty) {
      _removeSelectionContextMenu();
      return;
    }

    final controller = ContextMenuController();
    _selectionContextMenuController = controller;
    controller.show(
      context: context,
      contextMenuBuilder: (context) => AdaptiveTextSelectionToolbar.buttonItems(
        anchors: _selectionContextMenuAnchors(
          size,
          metrics,
          fallbackLocalPosition: fallbackLocalPosition,
        ),
        buttonItems: _selectionContextMenuButtonItems(),
      ),
    );
  }

  void _scheduleSelectionContextMenu({
    required Size size,
    required _TerminalMetrics metrics,
    Offset? fallbackLocalPosition,
  }) {
    if (!widget.showSelectionContextMenu) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _selection == null) {
        return;
      }
      _showSelectionContextMenu(
        size: size,
        metrics: metrics,
        fallbackLocalPosition: fallbackLocalPosition,
      );
    });
  }

  List<ContextMenuButtonItem> _selectionContextMenuButtonItems() {
    final selection = _selection;
    if (selection == null) {
      return const <ContextMenuButtonItem>[];
    }
    final selectedText = _resolveSelectionText(selection);
    final defaultButtonItems = List<ContextMenuButtonItem>.unmodifiable(
      _defaultSelectionContextMenuButtonItems(),
    );
    final builder = widget.selectionContextMenuButtonItemsBuilder;
    if (builder == null) {
      return defaultButtonItems;
    }
    return builder(
      GhosttyTerminalSelectionContextMenuDetails(
        selection: selection,
        selectedText: selectedText,
        defaultButtonItems: defaultButtonItems,
        copySelection: _copySelectionFromContextMenu,
        selectAll: _selectAllFromContextMenu,
        hideToolbar: _removeSelectionContextMenu,
      ),
    );
  }

  List<ContextMenuButtonItem> _defaultSelectionContextMenuButtonItems() {
    return <ContextMenuButtonItem>[
      ContextMenuButtonItem(
        type: ContextMenuButtonType.copy,
        onPressed: _copySelectionFromContextMenu,
      ),
      ContextMenuButtonItem(
        type: ContextMenuButtonType.selectAll,
        onPressed: _selectAllFromContextMenu,
      ),
    ];
  }

  void _copySelectionFromContextMenu() {
    final text = _selectionText();
    _removeSelectionContextMenu();
    if (text.isNotEmpty) {
      unawaited(_copySelection(text));
    }
  }

  void _selectAllFromContextMenu() {
    _removeSelectionContextMenu();
    final selection = widget.controller.snapshot.selectAllSelection();
    if (selection != null) {
      _setSelection(selection);
    }
  }

  TextSelectionToolbarAnchors _selectionContextMenuAnchors(
    Size size,
    _TerminalMetrics metrics, {
    Offset? fallbackLocalPosition,
  }) {
    final renderObject = context.findRenderObject();
    final renderBox = renderObject is RenderBox ? renderObject : null;
    final fallback = fallbackLocalPosition ?? Offset(size.width / 2, 0);
    if (renderBox == null || !renderBox.hasSize) {
      return TextSelectionToolbarAnchors(primaryAnchor: fallback);
    }

    final selectionRect =
        _selectionRectForContextMenu(size, metrics) ??
        Rect.fromCenter(
          center: fallback,
          width: metrics.charWidth,
          height: metrics.linePixels,
        );
    return TextSelectionToolbarAnchors(
      primaryAnchor: renderBox.localToGlobal(selectionRect.topCenter),
      secondaryAnchor: renderBox.localToGlobal(selectionRect.bottomCenter),
    );
  }

  Rect? _selectionRectForContextMenu(Size size, _TerminalMetrics metrics) {
    final selection = _selection;
    if (selection == null) {
      return null;
    }
    final viewport = _viewportFor(size, metrics);
    final visibleStart = viewport.startLine;
    final visibleEnd = viewport.startLine + viewport.maxVisible - 1;
    final normalized = selection.normalized;
    final startRow = normalized.start.row.clamp(visibleStart, visibleEnd);
    final endRow = normalized.end.row.clamp(visibleStart, visibleEnd);
    if (endRow < visibleStart || startRow > visibleEnd || startRow > endRow) {
      return null;
    }

    final isMultiLine = normalized.start.row != normalized.end.row;
    final effPadding = _effectivePadding(size, metrics);
    final contentLeft = effPadding.left;
    final contentRight = size.width - effPadding.right;
    final left = isMultiLine
        ? contentLeft
        : contentLeft + normalized.start.col * metrics.charWidth;
    final right = isMultiLine
        ? contentRight
        : contentLeft + (normalized.end.col + 1) * metrics.charWidth;
    final top =
        viewport.contentTop +
        (startRow - viewport.startLine) * metrics.linePixels;
    final bottom =
        viewport.contentTop +
        (endRow - viewport.startLine + 1) * metrics.linePixels;

    return Rect.fromLTRB(
      left.clamp(contentLeft, contentRight),
      top.clamp(
        viewport.contentTop,
        viewport.contentTop + viewport.contentHeight,
      ),
      right.clamp(contentLeft, contentRight),
      bottom.clamp(
        viewport.contentTop,
        viewport.contentTop + viewport.contentHeight,
      ),
    );
  }

  Widget _buildSelectionHandleOverlay(
    Size size,
    _TerminalMetrics metrics,
    _TerminalViewport viewport,
  ) {
    if (!_touchSelectionHandlesVisible || _selection == null) {
      return const SizedBox.shrink();
    }

    final start = _selectionEndpointOffset(
      _TerminalSelectionHandleEdge.start,
      size,
      metrics,
      viewport,
    );
    final end = _selectionEndpointOffset(
      _TerminalSelectionHandleEdge.end,
      size,
      metrics,
      viewport,
    );
    if (start == null && end == null) {
      return const SizedBox.shrink();
    }

    return Positioned.fill(
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          if (start != null)
            _buildSelectionHandle(
              edge: _TerminalSelectionHandleEdge.start,
              center: start,
              size: size,
              metrics: metrics,
            ),
          if (end != null)
            _buildSelectionHandle(
              edge: _TerminalSelectionHandleEdge.end,
              center: end,
              size: size,
              metrics: metrics,
            ),
        ],
      ),
    );
  }

  Widget _buildSelectionHandle({
    required _TerminalSelectionHandleEdge edge,
    required Offset center,
    required Size size,
    required _TerminalMetrics metrics,
  }) {
    return Positioned(
      left: center.dx - _selectionHandleTouchExtent / 2,
      top: center.dy - _selectionHandleVisualRadius,
      width: _selectionHandleTouchExtent,
      height: _selectionHandleTouchExtent,
      child: GestureDetector(
        key: edge == _TerminalSelectionHandleEdge.start
            ? _selectionStartHandleKey
            : _selectionEndHandleKey,
        supportedDevices: _touchPointerDevices,
        behavior: HitTestBehavior.translucent,
        onPanStart: (details) {
          final localPosition = _terminalLocalFromGlobal(
            details.globalPosition,
          );
          if (localPosition != null) {
            _beginSelectionHandleDrag(edge, localPosition, size, metrics);
          }
        },
        onPanUpdate: (details) {
          final localPosition = _terminalLocalFromGlobal(
            details.globalPosition,
          );
          if (localPosition != null) {
            _updateSelectionHandleDrag(localPosition, size, metrics);
          }
        },
        onPanEnd: (_) => _endSelectionHandleDrag(size, metrics),
        onPanCancel: () => _endSelectionHandleDrag(size, metrics),
        child: CustomPaint(
          painter: _TerminalSelectionHandlePainter(color: widget.cursorColor),
        ),
      ),
    );
  }

  Offset? _terminalLocalFromGlobal(Offset globalPosition) {
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) {
      return null;
    }
    return renderObject.globalToLocal(globalPosition);
  }

  Offset? _selectionEndpointOffset(
    _TerminalSelectionHandleEdge edge,
    Size size,
    _TerminalMetrics metrics,
    _TerminalViewport viewport,
  ) {
    final selection = _selection?.normalized;
    if (selection == null) {
      return null;
    }
    final position = edge == _TerminalSelectionHandleEdge.start
        ? selection.start
        : selection.end;
    if (position.row < viewport.startLine ||
        position.row >= viewport.startLine + viewport.maxVisible) {
      return null;
    }

    final effPadding = _effectivePadding(size, metrics);
    final rawX = edge == _TerminalSelectionHandleEdge.start
        ? effPadding.left + position.col * metrics.charWidth
        : effPadding.left + (position.col + 1) * metrics.charWidth;
    final minX = effPadding.left;
    final maxX = math.max(minX, _lastReportedCols * metrics.charWidth + minX);
    final y =
        viewport.contentTop +
        (position.row - viewport.startLine + 1) * metrics.linePixels;
    return Offset(rawX.clamp(minX, maxX), y);
  }

  void _beginSelectionHandleDrag(
    _TerminalSelectionHandleEdge edge,
    Offset localPosition,
    Size size,
    _TerminalMetrics metrics,
  ) {
    if (_selection == null || _currentPointerUsesTerminalMouse) {
      return;
    }
    _removeSelectionContextMenu();
    _selectionHandleDragEdge = edge;
    _lastSelectionHandleDragPosition = localPosition;
    _touchSelectionActive = true;
    _touchSelectionHandlesVisible = true;
    _dragSelectionGranularity = _TerminalSelectionGranularity.cell;
    _updateSelectionHandleDrag(localPosition, size, metrics);
  }

  void _updateSelectionHandleDrag(
    Offset localPosition,
    Size size,
    _TerminalMetrics metrics,
  ) {
    final position = _positionForOffset(
      localPosition,
      size,
      metrics,
      clampToViewport: true,
    );
    final selection = _selectionForHandleDragPosition(position);
    if (selection == null) {
      return;
    }
    _lastSelectionHandleDragPosition = localPosition;
    _setSelection(selection, touchSelectionHandlesVisible: true);
    _syncAutoScroll(localPosition, size, metrics);
  }

  GhosttyTerminalSelection? _selectionForHandleDragPosition(
    GhosttyTerminalCellPosition? position,
  ) {
    final edge = _selectionHandleDragEdge;
    final current = _selection?.normalized;
    if (edge == null || current == null || position == null) {
      return null;
    }
    return switch (edge) {
      _TerminalSelectionHandleEdge.start => GhosttyTerminalSelection(
        base: position,
        extent: current.end,
      ),
      _TerminalSelectionHandleEdge.end => GhosttyTerminalSelection(
        base: current.start,
        extent: position,
      ),
    };
  }

  void _endSelectionHandleDrag(Size size, _TerminalMetrics metrics) {
    final localPosition = _lastSelectionHandleDragPosition;
    _selectionHandleDragEdge = null;
    _lastSelectionHandleDragPosition = null;
    _touchSelectionActive = false;
    _stopAutoScroll();
    if (_selection != null) {
      _touchSelectionHandlesVisible = true;
      _scheduleSelectionContextMenu(
        size: size,
        metrics: metrics,
        fallbackLocalPosition: localPosition,
      );
    }
  }

  _TerminalMetrics _measureMetrics() {
    final painter = TextPainter(
      text: TextSpan(
        text: 'W',
        style: _terminalTextStyle(
          fontSize: widget.fontSize,
          lineHeight: widget.lineHeight,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    // The font's natural monospace advance (including the base letterSpacing).
    final rawCharWidth = math.max(1.0, painter.width * widget.cellWidthScale);
    final rawLinePixels = math.max(1.0, widget.fontSize * widget.lineHeight);

    // Snap the cell to whole physical pixels so EVERY cell is identical and
    // aligned to the pixel grid — the same fixed-integer cell ghostty uses for
    // its sprite glyphs. A fractional cell (e.g. 8.4px) snapped per-edge yields
    // columns that alternate 8/9px, which distorts block/box glyphs and
    // half-block pixel art (TUI logos, charts). Rows get the same treatment.
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final charWidth = _snapLogicalExtentToPhysical(rawCharWidth, dpr);
    final linePixels = _snapLogicalExtentToPhysical(rawLinePixels, dpr);

    // Because the cell is now snapped but the font advance is not, compensate
    // with letterSpacing so a run still advances exactly one cell per glyph and
    // text stays locked to the grid. Compensate against the unscaled glyph
    // advance (`painter.width`), NOT `rawCharWidth` — `rawCharWidth` folds in
    // `cellWidthScale`, but the font itself advances by `painter.width`
    // regardless of the cell scale, so using `rawCharWidth` would mis-space
    // text whenever `cellWidthScale != 1`.
    final letterSpacing = widget.letterSpacing + (charWidth - painter.width);

    return _TerminalMetrics(
      charWidth: charWidth,
      linePixels: linePixels,
      letterSpacing: letterSpacing,
    );
  }

  TextStyle _terminalTextStyle({
    required double fontSize,
    required double lineHeight,
    Color? color,
    FontWeight? fontWeight,
    FontStyle? fontStyle,
    TextDecoration? decoration,
    TextDecorationStyle? decorationStyle,
    Color? decorationColor,
  }) {
    return TextStyle(
      color: color,
      fontFamily: widget.fontFamily ?? 'monospace',
      fontFamilyFallback: widget.fontFamilyFallback,
      package: widget.fontPackage,
      fontSize: fontSize,
      height: lineHeight,
      letterSpacing: widget.letterSpacing,
      fontWeight: fontWeight,
      fontStyle: fontStyle,
      decoration: decoration,
      decorationStyle: decorationStyle,
      decorationColor: decorationColor,
    );
  }

  double get _headerHeight => widget.showHeader ? _terminalHeaderHeight : 0;

  /// Returns [GhosttyTerminalView.padding] with the floor-rounding remainder
  /// distributed across the four edges according to [GhosttyTerminalView.cellAlignment].
  ///
  /// The cell grid is always laid out as `floor(content / cellSize)` whole
  /// cells, leaving a sub-cell remainder. By default ([Alignment.topLeft])
  /// that remainder lives on the right/bottom edges; [Alignment.center]
  /// splits it equally on all sides, etc. All downstream geometry
  /// (painter, viewport, pointer-to-cell, mouse-encoder padding) reads
  /// through this helper so cell→pixel mapping stays consistent with where
  /// the grid is actually painted. Cell-count computation in [_syncGrid]
  /// still uses the original [widget.padding] — the remainder is derived
  /// *from* that count, not the other way around.
  EdgeInsets _effectivePadding(Size size, _TerminalMetrics metrics) {
    final align = widget.cellAlignment;
    if (align.x == -1 && align.y == -1) {
      return widget.padding; // topLeft fast-path
    }
    final contentWidth = size.width - widget.padding.horizontal;
    final contentHeight = size.height - _headerHeight - widget.padding.vertical;
    if (contentWidth <= 0 || contentHeight <= 0) return widget.padding;
    final cols = math.max(1, (contentWidth / metrics.charWidth).floor());
    final rows = math.max(1, (contentHeight / metrics.linePixels).floor());
    final slopX = math.max(0.0, contentWidth - cols * metrics.charWidth);
    final slopY = math.max(0.0, contentHeight - rows * metrics.linePixels);
    // Alignment uses -1..1; convert to a 0..1 fraction for the leading edge,
    // then floor to whole logical pixels. Two reasons the leading edges
    // MUST be integer-valued:
    //
    //   1. The painter draws cell origins at `padding.left + col*charWidth`
    //      and `padding.top + row*linePixels`. A non-integer leading edge
    //      forces every glyph onto a half-pixel grid; the rasterizer then
    //      spreads each stroke across two device pixels (visibly blurry
    //      text — defeating the whole point of a monospace cell grid).
    //
    //   2. `_mouseEncoderSize` rounds each edge independently before
    //      sending to the native side. If leading + trailing each carry a
    //      .5, both round up and the integer sum overshoots `slopX` by
    //      1px, making the native hit-tester report col+1 along the
    //      rightmost cell column (and similarly for the bottom row).
    //      Flooring the leading edge keeps `slopX - extraLeft` whatever
    //      it needs to be for an exact sum; when `widget.padding` edges
    //      are integers (the common case), the .round() calls in
    //      `_mouseEncoderSize` are no-ops.
    //
    // The trailing edges absorb the fractional remainder; they only feed
    // subtractive arithmetic (contentHeight/Width, mouse-encoder padding),
    // never a paint origin, so non-integer values there are harmless.
    final extraLeft = (slopX * (align.x + 1) / 2).floorToDouble();
    final extraTop = (slopY * (align.y + 1) / 2).floorToDouble();
    return EdgeInsets.fromLTRB(
      widget.padding.left + extraLeft,
      widget.padding.top + extraTop,
      widget.padding.right + (slopX - extraLeft),
      widget.padding.bottom + (slopY - extraTop),
    );
  }

  void _syncGrid(Size size, _TerminalMetrics metrics) {
    final contentWidth = size.width - widget.padding.horizontal;
    final contentHeight = size.height - _headerHeight - widget.padding.vertical;
    if (contentWidth <= 0 || contentHeight <= 0) {
      return;
    }

    if (metrics.charWidth != _lastMetricCharWidth ||
        metrics.linePixels != _lastMetricLinePixels) {
      _lastMetricCharWidth = metrics.charWidth;
      _lastMetricLinePixels = metrics.linePixels;
      final cb = widget.onCellMetricsChanged;
      if (cb != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) cb(metrics.charWidth, metrics.linePixels);
        });
      }
    }

    final cols = math.max(1, (contentWidth / metrics.charWidth).floor());
    final rows = math.max(1, (contentHeight / metrics.linePixels).floor());
    final cellWidthPx = metrics.charWidth.round();
    final cellHeightPx = metrics.linePixels.round();
    // Skip only when cols, rows, AND the cell pixel metrics all match the last
    // sync — a font-size change can leave the grid dimensions unchanged while
    // the engine's cellWidthPx/cellHeightPx (pixel-size reports, CSI 14 t) go
    // stale.
    if (cols == _lastReportedCols &&
        rows == _lastReportedRows &&
        cellWidthPx == _lastSyncedCellWidthPx &&
        cellHeightPx == _lastSyncedCellHeightPx) {
      return;
    }

    _lastReportedCols = cols;
    _lastReportedRows = rows;
    _lastSyncedCellWidthPx = cellWidthPx;
    _lastSyncedCellHeightPx = cellHeightPx;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      widget.controller.resize(
        cols: cols,
        rows: rows,
        cellWidthPx: cellWidthPx,
        cellHeightPx: cellHeightPx,
      );
    });
  }

  void _handlePointerSignal(
    PointerSignalEvent event,
    Size size,
    _TerminalMetrics metrics,
  ) {
    if (event is! PointerScrollEvent) {
      return;
    }

    if (_terminalMouseReportingEnabled) {
      final scrollUp = event.scrollDelta.dy < 0;
      if (!scrollUp && event.scrollDelta.dy <= 0) {
        return;
      }
      _sendWheelStep(event, size, metrics, up: scrollUp);
      return;
    }

    final deltaLines = (event.scrollDelta.dy / metrics.linePixels).round();
    if (deltaLines == 0) {
      return;
    }

    _setScrollOffsetLines(_scrollOffsetLines - deltaLines, size, metrics);
  }

  // One wheel "notch" as a mouse button 4/5 press+release at `event`'s location.
  // `up` → button 4 (scroll up into history), else button 5. Shared by the real
  // wheel (`_handlePointerSignal`) and touch-swipe→wheel
  // (`_onTouchMousePointerMove`) so the two encodings can't drift.
  void _sendWheelStep(
    PointerEvent event,
    Size size,
    _TerminalMetrics metrics, {
    required bool up,
  }) {
    final button = up
        ? GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_FOUR
        : GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_FIVE;
    _sendMouseEvent(
      GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_PRESS,
      event,
      size,
      metrics,
      button: button,
    );
    _sendMouseEvent(
      GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_RELEASE,
      event,
      size,
      metrics,
      button: button,
    );
  }

  void _handlePointerPanZoomStart(PointerPanZoomStartEvent event) {
    _panZoomScrollAccumPx = 0;
    _trackpadZoomActive = false;
    _requestTerminalFocus();
  }

  /// Trackpad two-finger pan. Pan deltas follow finger motion, which is the
  /// opposite sign convention from `PointerScrollEvent.scrollDelta` — so we
  /// add (rather than subtract) the line delta to keep content tracking the
  /// fingers (fingers down = scroll toward live bottom = offset decreases;
  /// fingers up = scroll back into history = offset increases).
  ///
  /// Mouse-reporting forwarding is intentionally skipped: SGR/xterm mouse
  /// protocol has no pan-zoom encoding (only wheel buttons 4/5 / 6/7), so
  /// pan-zoom is silently dropped when the TUI has mouse reporting on. This
  /// matches iTerm2 / Terminal.app behavior.
  void _handlePointerPanZoomUpdate(
    PointerPanZoomUpdateEvent event,
    Size size,
    _TerminalMetrics metrics,
  ) {
    // A scaled update marks the whole gesture as a pinch: report the
    // cumulative `event.scale` (already relative to gesture start) and stop
    // treating the sequence as scroll — a pinch always carries incidental pan
    // deltas, and letting them through would scroll while zooming.
    if (widget.onZoomUpdate != null &&
        (_trackpadZoomActive ||
            (event.scale - 1.0).abs() > _trackpadZoomDeadband)) {
      if (!_trackpadZoomActive) {
        _trackpadZoomActive = true;
        _setSelection(null);
      }
      widget.onZoomUpdate!(event.scale);
      return;
    }
    if (_terminalMouseReportingEnabled) return;
    _panZoomScrollAccumPx += event.panDelta.dy;
    final deltaLines = (_panZoomScrollAccumPx / metrics.linePixels).truncate();
    if (deltaLines == 0) return;
    _panZoomScrollAccumPx -= deltaLines * metrics.linePixels;
    _setScrollOffsetLines(_scrollOffsetLines + deltaLines, size, metrics);
  }

  void _handlePointerPanZoomEnd(PointerPanZoomEndEvent event) {
    _panZoomScrollAccumPx = 0;
    if (_trackpadZoomActive) {
      _trackpadZoomActive = false;
      widget.onZoomEnd?.call();
    }
  }

  VtMouseEncoderSize _mouseEncoderSize(Size size, _TerminalMetrics metrics) {
    final effPadding = _effectivePadding(size, metrics);
    return VtMouseEncoderSize(
      screenWidth: math.max(1, size.width.round()),
      screenHeight: math.max(1, (size.height - _headerHeight).round()),
      cellWidth: math.max(1, metrics.charWidth.round()),
      cellHeight: math.max(1, metrics.linePixels.round()),
      paddingTop: effPadding.top.round(),
      paddingBottom: effPadding.bottom.round(),
      paddingRight: effPadding.right.round(),
      paddingLeft: effPadding.left.round(),
    );
  }

  GhosttyMouseButton? _mouseButtonFromButtons(int buttons) {
    if ((buttons & kPrimaryMouseButton) != 0) {
      return GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_LEFT;
    }
    if ((buttons & kSecondaryMouseButton) != 0) {
      return GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_RIGHT;
    }
    if ((buttons & kMiddleMouseButton) != 0) {
      return GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_MIDDLE;
    }
    return null;
  }

  GhosttyMouseButton? _mouseButtonForEvent(
    GhosttyMouseAction action,
    PointerEvent event,
    GhosttyMouseButton? explicitButton,
  ) {
    if (explicitButton != null) {
      return explicitButton;
    }
    final button = _mouseButtonFromButtons(event.buttons);
    if (button != null) {
      return button;
    }
    if (event.kind == PointerDeviceKind.touch &&
        action != GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_MOTION) {
      return GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_LEFT;
    }
    return null;
  }

  bool _eventHasPressedButton(GhosttyMouseAction action, PointerEvent event) {
    return event.buttons != 0 ||
        action == GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_PRESS;
  }

  bool get _terminalMouseReportingEnabled => switch (widget.interactionPolicy) {
    GhosttyTerminalInteractionPolicy.selectionFirst => false,
    GhosttyTerminalInteractionPolicy.terminalMouseFirst => true,
    GhosttyTerminalInteractionPolicy.auto =>
      _safeTerminalMode(VtModes.x10Mouse) ||
          _safeTerminalMode(VtModes.normalMouse) ||
          _safeTerminalMode(VtModes.buttonMouse) ||
          _safeTerminalMode(VtModes.anyMouse),
  };

  bool _safeTerminalMode(VtMode mode) {
    try {
      return widget.controller.terminal.getMode(mode);
    } catch (_) {
      return false;
    }
  }

  GhosttyMouseTrackingMode? get _terminalMouseTrackingMode {
    if (_safeTerminalMode(VtModes.anyMouse)) {
      return GhosttyMouseTrackingMode.GHOSTTY_MOUSE_TRACKING_ANY;
    }
    if (_safeTerminalMode(VtModes.buttonMouse)) {
      return GhosttyMouseTrackingMode.GHOSTTY_MOUSE_TRACKING_BUTTON;
    }
    if (_safeTerminalMode(VtModes.normalMouse)) {
      return GhosttyMouseTrackingMode.GHOSTTY_MOUSE_TRACKING_NORMAL;
    }
    if (_safeTerminalMode(VtModes.x10Mouse)) {
      return GhosttyMouseTrackingMode.GHOSTTY_MOUSE_TRACKING_X10;
    }
    return null;
  }

  GhosttyMouseFormat? get _terminalMouseFormat {
    if (!_terminalMouseReportingEnabled) {
      return null;
    }
    if (_safeTerminalMode(VtModes.sgrPixelsMouse)) {
      return GhosttyMouseFormat.GHOSTTY_MOUSE_FORMAT_SGR_PIXELS;
    }
    if (_safeTerminalMode(VtModes.sgrMouse)) {
      return GhosttyMouseFormat.GHOSTTY_MOUSE_FORMAT_SGR;
    }
    if (_safeTerminalMode(VtModes.urxvtMouse)) {
      return GhosttyMouseFormat.GHOSTTY_MOUSE_FORMAT_URXVT;
    }
    if (_safeTerminalMode(VtModes.utf8Mouse)) {
      return GhosttyMouseFormat.GHOSTTY_MOUSE_FORMAT_UTF8;
    }
    return GhosttyMouseFormat.GHOSTTY_MOUSE_FORMAT_X10;
  }

  bool _terminalMouseReportingCapturesPointerKind(PointerDeviceKind kind) {
    if (!_terminalMouseReportingEnabled) {
      return false;
    }
    if (kind != PointerDeviceKind.touch) {
      return true;
    }
    // Touch drives the TUI whenever the program actually asked for the mouse.
    // `terminalMouseFirst` always reports; `auto` reaches here only when a
    // mouse mode is live (see `_terminalMouseReportingEnabled`), so touch taps
    // become clicks and swipes become wheel scroll on mobile — matching how a
    // full-screen agent (Claude Code, opencode) expects to be driven.
    // `selectionFirst` never forwards touch.
    return widget.interactionPolicy ==
            GhosttyTerminalInteractionPolicy.terminalMouseFirst ||
        widget.interactionPolicy == GhosttyTerminalInteractionPolicy.auto;
  }

  bool get _currentPointerUsesTerminalMouse =>
      _terminalMouseReportingCapturesPointerKind(_lastPointerKind);

  Set<PointerDeviceKind> get _selectionDragDevices {
    if (widget.touchDragBehavior ==
        GhosttyTerminalTouchDragBehavior.selection) {
      return const <PointerDeviceKind>{
        ..._mouseLikePointerDevices,
        ..._touchPointerDevices,
      };
    }
    return _mouseLikePointerDevices;
  }

  void _sendMouseEvent(
    GhosttyMouseAction action,
    PointerEvent event,
    Size size,
    _TerminalMetrics metrics, {
    GhosttyMouseButton? button,
    Offset? positionOverride,
  }) {
    if (!_terminalMouseReportingCapturesPointerKind(event.kind)) {
      return;
    }

    // Deferred touch clicks report the down location, not the release point:
    // a tap can drift up to `kTouchSlop` before lifting, and the cell the user
    // aimed at is where the finger landed. Same coordinate space as
    // `event.localPosition`.
    final localPosition = positionOverride ?? event.localPosition;
    final terminalLocalY = math.max<double>(
      0,
      localPosition.dy - _headerHeight,
    );
    widget.controller.sendMouse(
      action: action,
      button: _mouseButtonForEvent(action, event, button),
      mods: GhosttyTerminalModifierState.fromHardwareKeyboard().ghosttyMask,
      position: VtMousePosition(x: localPosition.dx, y: terminalLocalY),
      size: _mouseEncoderSize(size, metrics),
      trackingMode: _terminalMouseTrackingMode,
      format: _terminalMouseFormat,
      anyButtonPressed: _eventHasPressedButton(action, event),
      trackLastCell: true,
    );
  }

  /// Total scrollable lines for extent/scrollbar math. Prefers the engine's
  /// native scrollback total (so rows beyond the formatter `maxLines` cap stay
  /// reachable); falls back to the formatter snapshot when the engine viewport
  /// geometry is unavailable (e.g. before the terminal exists).
  int _scrollableLineCount() {
    final bar = widget.controller.viewportScrollbar;
    if (bar != null) {
      return bar.total;
    }
    return widget.controller.snapshot.lines.length;
  }

  int _maxScrollOffset(Size size, _TerminalMetrics metrics) {
    final viewport = _viewportFor(size, metrics);
    return math.max(0, _scrollableLineCount() - viewport.maxVisible);
  }

  _TerminalViewport _viewportFor(Size size, _TerminalMetrics metrics) {
    final effPadding = _effectivePadding(size, metrics);
    final contentTop = _headerHeight + effPadding.top;
    final contentHeight = size.height - contentTop - effPadding.bottom;
    final maxVisible = contentHeight <= 0
        ? 1
        : math.max(1, (contentHeight / metrics.linePixels).floor());
    final lineCount = _scrollableLineCount();
    final maxOffset = math.max(0, lineCount - maxVisible);
    final offset = _scrollOffsetLines.clamp(0, maxOffset);
    final end = math.max(0, lineCount - offset);
    final start = math.max(0, end - maxVisible);
    return _TerminalViewport(
      startLine: start,
      contentTop: contentTop,
      contentHeight: math.max(0, contentHeight),
      maxVisible: maxVisible,
    );
  }

  void _setScrollOffsetLines(int offset, Size size, _TerminalMetrics metrics) {
    final clamped = offset.clamp(0, _maxScrollOffset(size, metrics));
    if (clamped == _scrollOffsetLines && !_scrollController.hasClients) {
      return;
    }
    final targetPixels = clamped * metrics.linePixels;
    if (_scrollController.hasClients) {
      final maxPixels = _scrollController.position.maxScrollExtent;
      final clampedPixels = targetPixels.clamp(0.0, maxPixels);
      if ((_scrollController.offset - clampedPixels).abs() < 0.5) {
        if (clamped != _scrollOffsetLines) {
          setState(() {
            _scrollOffsetLines = clamped;
          });
        }
        _driveEngineViewport(clamped);
        return;
      }
      _scrollController.jumpTo(clampedPixels);
      return;
    }
    setState(() {
      _scrollOffsetLines = clamped;
    });
    _driveEngineViewport(clamped);
  }

  Widget _buildScrollLayer(
    Size size,
    _TerminalMetrics metrics,
    _TerminalViewport viewport,
  ) {
    final maxOffset = _maxScrollOffset(size, metrics);
    if (viewport.contentHeight <= 0) {
      return const SizedBox.shrink();
    }

    final maxScrollPixels = maxOffset * metrics.linePixels;
    final scrollExtentHeight = viewport.contentHeight + maxScrollPixels;
    return Positioned(
      left: 0,
      right: 0,
      top: viewport.contentTop,
      height: viewport.contentHeight,
      child: SingleChildScrollView(
        controller: _scrollController,
        physics: widget.scrollPhysics ?? const ClampingScrollPhysics(),
        child: SizedBox(width: size.width, height: scrollExtentHeight),
      ),
    );
  }

  Widget _buildScrollbarOverlay(
    Size size,
    _TerminalMetrics metrics,
    _TerminalViewport viewport,
  ) {
    final lineCount = _scrollableLineCount();
    final maxOffset = _maxScrollOffset(size, metrics);
    if (!widget.showVerticalScrollbar ||
        viewport.contentHeight <= 0 ||
        lineCount <= viewport.maxVisible ||
        maxOffset <= 0) {
      return const SizedBox.shrink();
    }

    final trackTop = viewport.contentTop;
    final trackHeight = viewport.contentHeight;
    final visibleFraction = (viewport.maxVisible / lineCount).clamp(0.0, 1.0);
    final thumbExtent = math.max(
      widget.scrollbarMinThumbExtent,
      trackHeight * visibleFraction,
    );
    final thumbTravel = math.max(0.0, trackHeight - thumbExtent);
    final thumbTop =
        trackTop +
        (maxOffset == 0
            ? thumbTravel
            : ((maxOffset - _scrollOffsetLines) / maxOffset) * thumbTravel);

    double fractionForDy(double dy, {bool centerThumb = false}) {
      final localY = dy - trackTop;
      final thumbAnchor = centerThumb ? thumbExtent / 2 : 0.0;
      final travelY = (localY - thumbAnchor).clamp(0.0, thumbTravel);
      if (thumbTravel <= 0) {
        return 0;
      }
      return travelY / thumbTravel;
    }

    void updateFraction(double fraction) {
      final nextOffset = ((1 - fraction.clamp(0.0, 1.0)) * maxOffset).round();
      _setScrollOffsetLines(nextOffset, size, metrics);
    }

    return Positioned(
      top: trackTop,
      right: 2,
      width: widget.scrollbarThickness,
      height: trackHeight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (details) => updateFraction(
          fractionForDy(details.localPosition.dy + trackTop, centerThumb: true),
        ),
        onVerticalDragDown: (details) => updateFraction(
          fractionForDy(details.localPosition.dy + trackTop, centerThumb: true),
        ),
        onVerticalDragUpdate: (details) => updateFraction(
          fractionForDy(details.localPosition.dy + trackTop, centerThumb: true),
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: widget.scrollbarTrackColor,
            borderRadius: BorderRadius.circular(widget.scrollbarThickness / 2),
          ),
          child: Stack(
            children: [
              Positioned(
                top: thumbTop - trackTop,
                left: 0,
                right: 0,
                height: thumbExtent,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: widget.scrollbarThumbColor,
                    borderRadius: BorderRadius.circular(
                      widget.scrollbarThickness / 2,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  GhosttyTerminalCellPosition? _positionForOffset(
    Offset localPosition,
    Size size,
    _TerminalMetrics metrics, {
    bool clampToViewport = false,
  }) {
    final viewport = _viewportFor(size, metrics);
    if (widget.controller.snapshot.lines.isEmpty) {
      return null;
    }

    final effPadding = _effectivePadding(size, metrics);
    final minX = effPadding.left;
    final maxX = size.width - effPadding.right;
    final minY = viewport.contentTop;
    final maxY = viewport.contentTop + viewport.contentHeight;
    if (!clampToViewport &&
        (localPosition.dx < minX ||
            localPosition.dx > maxX ||
            localPosition.dy < minY ||
            localPosition.dy > maxY)) {
      return null;
    }

    final resolvedX = clampToViewport
        ? localPosition.dx.clamp(minX, maxX)
        : localPosition.dx;
    final resolvedY = clampToViewport
        ? localPosition.dy.clamp(minY, maxY)
        : localPosition.dy;
    final lineIndex = ((resolvedY - viewport.contentTop) / metrics.linePixels)
        .floor();
    final maxRow = math.max(0, _scrollableLineCount() - 1);
    final row = (viewport.startLine + lineIndex).clamp(0, maxRow).toInt();
    final col = ((resolvedX - effPadding.left) / metrics.charWidth).floor();
    final maxCol = math.max(0, widget.controller.cols - 1);
    return GhosttyTerminalCellPosition(row: row, col: col.clamp(0, maxCol));
  }

  void _stopAutoScroll({
    bool clearLineSelectionAnchor = true,
    bool resetSelectionGestureState = true,
  }) {
    _autoScrollSession.stop();
    if (clearLineSelectionAnchor) {
      _selectionSession.clearLineSelectionAnchorRow();
    }
    if (resetSelectionGestureState) {
      _dragSelectionGranularity = _TerminalSelectionGranularity.cell;
      _wordSelectionAnchor = null;
      _selectionHandleDragEdge = null;
      _lastSelectionHandleDragPosition = null;
      _pendingSerialTapCount = 0;
    }
  }

  void _syncAutoScroll(
    Offset localPosition,
    Size size,
    _TerminalMetrics metrics,
  ) {
    _autoScrollSession
      ..updateDragPosition(localPosition)
      ..updateLayout(layoutSize: size, metrics: metrics);

    final viewport = _viewportFor(size, metrics);
    final edgeThreshold = widget.selectionAutoScrollEdgeInset;
    final topEdge = viewport.contentTop + edgeThreshold;
    final bottomEdge =
        viewport.contentTop + viewport.contentHeight - edgeThreshold;
    final shouldScrollUp = localPosition.dy < topEdge;
    final shouldScrollDown = localPosition.dy > bottomEdge;
    if (!shouldScrollUp && !shouldScrollDown) {
      _stopAutoScroll(
        clearLineSelectionAnchor: false,
        resetSelectionGestureState: false,
      );
      return;
    }

    _autoScrollSession.ensureTimer(
      const Duration(milliseconds: 50),
      _performAutoScrollTick,
    );
  }

  void _performAutoScrollTick() {
    final size = _autoScrollSession.layoutSize;
    final metrics = _autoScrollSession.metrics;
    final localPosition = _autoScrollSession.dragPosition;
    if (!mounted || size == null || metrics == null || localPosition == null) {
      _stopAutoScroll();
      return;
    }

    final viewport = _viewportFor(size, metrics);
    final edgeThreshold = widget.selectionAutoScrollEdgeInset;
    final topEdge = viewport.contentTop + edgeThreshold;
    final bottomEdge =
        viewport.contentTop + viewport.contentHeight - edgeThreshold;
    final direction = localPosition.dy < topEdge
        ? 1
        : (localPosition.dy > bottomEdge ? -1 : 0);
    if (direction == 0) {
      _stopAutoScroll(
        clearLineSelectionAnchor: false,
        resetSelectionGestureState: false,
      );
      return;
    }

    final nextOffset = (_scrollOffsetLines + direction).clamp(
      0,
      _maxScrollOffset(size, metrics),
    );
    if (nextOffset == _scrollOffsetLines) {
      _stopAutoScroll(
        clearLineSelectionAnchor: false,
        resetSelectionGestureState: false,
      );
      return;
    }
    final position = _positionForOffset(
      Offset(
        localPosition.dx,
        direction > 0
            ? viewport.contentTop + 1
            : viewport.contentTop + viewport.contentHeight - 1,
      ),
      size,
      metrics,
      clampToViewport: true,
    );
    if (position == null) {
      _stopAutoScroll();
      return;
    }

    final current = _selection;
    if (current == null) {
      _stopAutoScroll();
      return;
    }

    final lineSelectionAnchorRow = _lineSelectionAnchorRow;
    final nextSelection = _selectionHandleDragEdge == null
        ? switch (_dragSelectionGranularity) {
            _TerminalSelectionGranularity.word => _extendWordSelection(
              position,
            ),
            _TerminalSelectionGranularity.line =>
              lineSelectionAnchorRow == null
                  ? GhosttyTerminalSelection(
                      base: current.base,
                      extent: position,
                    )
                  : _resolveLineSelectionBetweenRows(
                      lineSelectionAnchorRow,
                      position.row,
                    ),
            _TerminalSelectionGranularity.cell =>
              lineSelectionAnchorRow == null
                  ? GhosttyTerminalSelection(
                      base: current.base,
                      extent: position,
                    )
                  : _resolveLineSelectionBetweenRows(
                      lineSelectionAnchorRow,
                      position.row,
                    ),
            _TerminalSelectionGranularity.visualRow =>
              lineSelectionAnchorRow == null
                  ? GhosttyTerminalSelection(
                      base: current.base,
                      extent: position,
                    )
                  : _resolveLineSelectionBetweenRows(
                      lineSelectionAnchorRow,
                      position.row,
                      walkWrapChain: false,
                    ),
          }
        : _selectionForHandleDragPosition(position);
    if (nextSelection == null) {
      _stopAutoScroll();
      return;
    }
    final previousSelection = _selection;
    setState(() {
      _scrollOffsetLines = nextOffset;
    });
    _driveEngineViewport(nextOffset);
    _selectionSession.updateSelection(nextSelection);
    ghosttyTerminalNotifySelectionChange<GhosttyTerminalSelection>(
      previousSelection: previousSelection,
      nextSelection: _selection,
      resolveText: _resolveSelectionText,
      onSelectionChanged: widget.onSelectionChanged,
      onSelectionContentChanged: widget.onSelectionContentChanged,
    );
  }

  void _updateHoveredHyperlink(
    Offset localPosition,
    Size size,
    _TerminalMetrics metrics,
  ) {
    final position = _positionForOffset(localPosition, size, metrics);
    if (!ghosttyTerminalUpdateHoveredLink<
      GhosttyTerminalCellPosition,
      GhosttyTerminalSelection
    >(
      session: _selectionSession,
      position: position,
      resolveUri: _resolveHyperlinkUriAt,
    )) {
      return;
    }
    setState(() {});
  }

  Future<void> _openHyperlink(String uri) async {
    await ghosttyTerminalOpenHyperlink(
      uri,
      onOpenHyperlink: widget.onOpenHyperlink,
    );
  }

  void _requestTerminalFocus() {
    if (widget.focusOnInteraction && !_focusNode.hasFocus) {
      FocusScope.of(context).requestFocus(_focusNode);
    }
    // Re-assert the soft keyboard on every interaction, not just focus-gain:
    // dismissing it (Android Back) closes the IME connection while the terminal
    // keeps focus, so a plain focus-change listener would never bring it back
    // on the next tap.
    if (_focusNode.hasFocus) {
      _softKeyboard?.show();
    }
  }

  bool _touchPointerShouldScroll(PointerEvent event) {
    return event.kind == PointerDeviceKind.touch &&
        widget.touchDragBehavior == GhosttyTerminalTouchDragBehavior.scroll &&
        !_terminalMouseReportingCapturesPointerKind(event.kind);
  }

  // Where a new touch gesture's arena outcome starts. In `scroll` drag-behavior
  // the vertical arena-claimer is installed and decides the outcome, so we begin
  // `unresolved` and forward nothing until it wins. In `selection` drag-behavior
  // no claimer exists — nothing to wait for — so begin `won`.
  _TouchArenaOutcome get _initialArenaOutcome =>
      widget.touchDragBehavior == GhosttyTerminalTouchDragBehavior.scroll
      ? _TouchArenaOutcome.unresolved
      : _TouchArenaOutcome.won;

  // The tracked gesture iff it matches this event's pointer and the expected
  // role, else null — the guard every touch handler opens with. (Selection
  // suppression via `_touchSelectionActive` is checked separately by the two
  // move handlers.)
  _TouchGesture? _activeFor(PointerEvent event, _TouchGestureRole role) {
    final gesture = _active;
    if (gesture == null ||
        gesture.pointer != event.pointer ||
        gesture.role != role) {
      return null;
    }
    return gesture;
  }

  // Drop the tracked gesture and reopen the selection guards. The single reset
  // for every gesture end (scroll or mouse-forward) and lifecycle teardown, so
  // the two never disagree on what "no active gesture" means.
  void _resetActiveGesture() {
    _active = null;
    _touchSelectionActive = false;
  }

  // --- Touch pinch-to-zoom ---
  // Runs off the raw Listener like the scroll/mouse-forward paths, NOT a
  // ScaleGestureRecognizer: a recognizer would enter the arena against the
  // view's own pan/long-press/vertical-drag recognizers and the host app's
  // horizontal pager, and any winner breaks somebody. The Listener sees both
  // fingers unconditionally, so a pinch can be derived without arena stakes.

  void _pinchZoomPointerDown(PointerDownEvent event) {
    if (widget.onZoomUpdate == null ||
        event.kind != PointerDeviceKind.touch) {
      return;
    }
    _zoomPointerPositions[event.pointer] = event.position;
    if (_pinchZoomActive || _zoomPointerPositions.length != 2) {
      return;
    }
    final ids = _zoomPointerPositions.keys.toList();
    final distance =
        (_zoomPointerPositions[ids[0]]! - _zoomPointerPositions[ids[1]]!)
            .distance;
    if (distance < _zoomMinInitialDistance) {
      return;
    }
    _zoomPinchPointers = (ids[0], ids[1]);
    _zoomPinchInitialDistance = distance;
    // The pinch owns both fingers now: drop the single-finger gesture the
    // first finger started (scroll or mouse-forward), abandon a long-press in
    // flight, and clear any selection so the pinch doesn't drag-extend it.
    _resetActiveGesture();
    _touchLongPressSelecting = false;
    _stopAutoScroll();
    _setSelection(null);
  }

  void _pinchZoomPointerMove(PointerMoveEvent event) {
    if (widget.onZoomUpdate == null ||
        event.kind != PointerDeviceKind.touch) {
      return;
    }
    if (!_zoomPointerPositions.containsKey(event.pointer)) {
      return;
    }
    _zoomPointerPositions[event.pointer] = event.position;
    final pinch = _zoomPinchPointers;
    if (pinch == null ||
        (event.pointer != pinch.$1 && event.pointer != pinch.$2)) {
      return;
    }
    final a = _zoomPointerPositions[pinch.$1];
    final b = _zoomPointerPositions[pinch.$2];
    if (a == null || b == null) {
      return;
    }
    final scale = (a - b).distance / _zoomPinchInitialDistance;
    if (!scale.isFinite) {
      return;
    }
    widget.onZoomUpdate!(scale);
  }

  void _pinchZoomPointerUpOrCancel(PointerEvent event) {
    if (event.kind != PointerDeviceKind.touch) {
      return;
    }
    _zoomPointerPositions.remove(event.pointer);
    final pinch = _zoomPinchPointers;
    if (pinch == null ||
        (event.pointer != pinch.$1 && event.pointer != pinch.$2)) {
      return;
    }
    _zoomPinchPointers = null;
    _zoomPinchInitialDistance = 0;
    widget.onZoomEnd?.call();
  }

  void _startTouchScroll(PointerDownEvent event) {
    // Single-finger: a second finger must not replace the tracked gesture.
    if (_active != null || !_touchPointerShouldScroll(event)) {
      return;
    }
    _active = _TouchGesture(
      pointer: event.pointer,
      role: _TouchGestureRole.scroll,
      start: event.localPosition,
      arenaOutcome: _initialArenaOutcome,
    );
    _touchSelectionActive = false;
  }

  void _updateTouchScroll(
    PointerMoveEvent event,
    Size size,
    _TerminalMetrics metrics,
  ) {
    final gesture = _activeFor(event, _TouchGestureRole.scroll);
    if (gesture == null || _touchSelectionActive) {
      return;
    }

    // Stop scrollback the moment the arena is lost to an ancestor horizontal
    // pager (diagonal swipe → page flip only). Local scrollback stays responsive
    // before the arena resolves — unlike the mouse-forward wheel path, a stray
    // line of local scroll never reaches the running program.
    final previous = gesture.lastPosition;
    gesture.lastPosition = event.localPosition;
    if (gesture.arenaOutcome == _TouchArenaOutcome.lost) {
      return;
    }

    final delta =
        event.localPosition.dy - previous.dy + gesture.scrollRemainder;
    final deltaLines = (delta / metrics.linePixels).truncate();
    gesture.scrollRemainder = delta - deltaLines * metrics.linePixels;
    if (deltaLines == 0) {
      return;
    }

    _setScrollOffsetLines(_scrollOffsetLines + deltaLines, size, metrics);
  }

  void _endTouchScroll(PointerEvent event) {
    if (_activeFor(event, _TouchGestureRole.scroll) == null) {
      return;
    }
    _resetActiveGesture();
  }

  // --- Touch → terminal-mouse forwarding ---
  // Active only while a running program has mouse reporting on (see
  // `_terminalMouseReportingCapturesPointerKind`). Otherwise these are no-ops
  // and the plain-scrollback path (`_startTouchScroll`) owns the finger.

  void _onTouchMousePointerDown(PointerDownEvent event) {
    if (!_terminalMouseReportingCapturesPointerKind(PointerDeviceKind.touch)) {
      return;
    }
    // Single-finger gesture: a second finger landing mid-swipe must not hijack
    // the tracked pointer (which would discard the in-progress wheel state).
    if (_active != null) {
      return;
    }
    _active = _TouchGesture(
      pointer: event.pointer,
      role: _TouchGestureRole.mouseForward,
      start: event.localPosition,
      arenaOutcome: _initialArenaOutcome,
      tapPending: true,
    );
  }

  void _onTouchMousePointerMove(
    PointerMoveEvent event,
    Size size,
    _TerminalMetrics metrics,
  ) {
    // Back off when this isn't our tracked mouse-forward finger, or a long-press
    // grabbed the selection.
    final gesture = _activeFor(event, _TouchGestureRole.mouseForward);
    if (gesture == null || _touchSelectionActive) {
      return;
    }
    // Resolve tap-vs-swipe by travel FIRST, before any arena short-circuit: a
    // finger past `kTouchSlop` is a swipe regardless of who won the arena.
    // Otherwise a horizontal page-flip swipe (which loses the arena) would keep
    // `tapPending` set and fire a phantom click on lift.
    if (gesture.tapPending) {
      if ((event.localPosition - gesture.start).distance <= kTouchSlop) {
        return; // still within tap slop — could resolve to a click
      }
      gesture.tapPending = false; // slop crossed → a swipe, not a tap
    }
    // Forward wheel only once the arena resolves in our favor: suppress while
    // unresolved (don't leak wheel before the axis is decided) and when lost (an
    // ancestor horizontal pager owns this swipe → page flip only).
    if (gesture.arenaOutcome != _TouchArenaOutcome.won) {
      return;
    }
    gesture.wheelRemainder += event.delta.dy;
    final steps = (gesture.wheelRemainder / metrics.linePixels).truncate();
    if (steps == 0) {
      return;
    }
    gesture.wheelRemainder -= steps * metrics.linePixels;
    // Finger down (positive dy) scrolls up into history → wheel button 4;
    // finger up → button 5.
    for (var i = 0; i < steps.abs(); i++) {
      _sendWheelStep(event, size, metrics, up: steps > 0);
    }
  }

  void _onTouchMousePointerUp(
    PointerUpEvent event,
    Size size,
    _TerminalMetrics metrics,
  ) {
    // Only the tracked finger's lift ends the gesture; a different finger
    // lifting must not reset our state (which would drop a pending click or
    // clear an active selection owned by the tracked finger).
    final gesture = _activeFor(event, _TouchGestureRole.mouseForward);
    if (gesture == null) {
      return;
    }
    final wasTap = gesture.tapPending && !_touchSelectionActive;
    // Capture before the reset nulls `_active`: the deferred click reports the
    // down cell.
    final downPosition = gesture.start;
    _resetActiveGesture();
    if (!wasTap ||
        !_terminalMouseReportingCapturesPointerKind(PointerDeviceKind.touch)) {
      return;
    }
    // Deferred click: press + release at the down cell (where the finger
    // landed), not the release cell — a tap may drift within `kTouchSlop`.
    _sendMouseEvent(
      GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_PRESS,
      event,
      size,
      metrics,
      positionOverride: downPosition,
    );
    _sendMouseEvent(
      GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_RELEASE,
      event,
      size,
      metrics,
      positionOverride: downPosition,
    );
  }

  void _onTouchMousePointerCancel(PointerCancelEvent event) {
    if (_activeFor(event, _TouchGestureRole.mouseForward) == null) {
      return;
    }
    _resetActiveGesture();
  }

  void _handleSerialTapUp(
    SerialTapUpDetails details,
    Size size,
    _TerminalMetrics metrics,
  ) {
    final tapCount = details.count;
    _pendingSerialTapCount = 0;
    switch (tapCount) {
      case 1:
        _handleTapUp(details.localPosition, size, metrics);
      case 2:
        _selectWord(details.localPosition, size, metrics);
      default:
        _beginLineSelection(details.localPosition, size, metrics);
    }
  }

  void _handleTapUp(Offset localPosition, Size size, _TerminalMetrics metrics) {
    widget.onTapTerminal?.call();
    _requestTerminalFocus();
    if (_currentPointerUsesTerminalMouse) {
      return;
    }
    final position = _positionForOffset(localPosition, size, metrics);
    final currentSelection = _selection;
    if ((HardwareKeyboard.instance.isShiftPressed ||
            HardwareKeyboard.instance.isLogicalKeyPressed(
              LogicalKeyboardKey.shiftLeft,
            ) ||
            HardwareKeyboard.instance.isLogicalKeyPressed(
              LogicalKeyboardKey.shiftRight,
            )) &&
        currentSelection != null &&
        position != null) {
      final nextSelection = _lineSelectionAnchorRow == null
          ? GhosttyTerminalSelection(
              base: currentSelection.base,
              extent: position,
            )
          : _resolveLineSelectionBetweenRows(
              _lineSelectionAnchorRow!,
              position.row,
            );
      if (nextSelection != null) {
        _setSelection(nextSelection);
      }
      return;
    }
    final resolution =
        ghosttyTerminalResolveTap<
          GhosttyTerminalCellPosition,
          GhosttyTerminalSelection
        >(
          session: _selectionSession,
          selection: _selection,
          position: position,
          resolveUri: _resolveHyperlinkUriAt,
        );
    if (resolution.hyperlink case final hyperlink?) {
      unawaited(_openHyperlink(hyperlink));
      return;
    }
    if (resolution.clearSelection) {
      _setSelection(null);
    }
  }

  void _beginSelection(
    Offset localPosition,
    Size size,
    _TerminalMetrics metrics,
  ) {
    // Pinch owns both fingers — a selection recognizer that limps through the
    // arena mid-pinch must not start a drag-select under them.
    if (_pinchZoomActive) {
      return;
    }
    if (_currentPointerUsesTerminalMouse) {
      return;
    }
    if (_pendingSerialTapCount >= 3) {
      _beginLineSelection(localPosition, size, metrics);
      return;
    }
    if (_pendingSerialTapCount == 2) {
      _beginWordSelectionDrag(localPosition, size, metrics);
      return;
    }
    if (_selection != null) {
      _selectionSession.resetIgnoreNextTapClear();
    }
    final position = _positionForOffset(localPosition, size, metrics);
    final selection = _gestureCoordinator.beginSelection(
      position: position,
      collapsedSelection: (position) =>
          GhosttyTerminalSelection(base: position, extent: position),
    );
    if (selection == null) {
      return;
    }
    _stopAutoScroll();
    _wordSelectionAnchor = null;
    _dragSelectionGranularity = _TerminalSelectionGranularity.cell;
    _requestTerminalFocus();
    _setSelection(selection, touchSelectionHandlesVisible: false);
  }

  void _beginWordSelectionDrag(
    Offset localPosition,
    Size size,
    _TerminalMetrics metrics,
  ) {
    final position = _positionForOffset(localPosition, size, metrics);
    final selection = _gestureCoordinator.selectWord(
      position: position,
      resolveWordSelection: _resolveWordSelectionAt,
    );
    if (selection == null) {
      return;
    }
    _stopAutoScroll();
    _wordSelectionAnchor = selection.normalized;
    _dragSelectionGranularity = _TerminalSelectionGranularity.word;
    _requestTerminalFocus();
    _setSelection(
      selection,
      touchSelectionHandlesVisible: _lastPointerKind == PointerDeviceKind.touch,
    );
    if (_lastPointerKind == PointerDeviceKind.touch) {
      _scheduleSelectionContextMenu(
        size: size,
        metrics: metrics,
        fallbackLocalPosition: localPosition,
      );
    }
  }

  void _updateSelection(
    Offset localPosition,
    Size size,
    _TerminalMetrics metrics,
  ) {
    // See `_beginSelection`: no selection updates while a pinch is active.
    if (_pinchZoomActive) {
      return;
    }
    // Extending a long-press selection stays local even in mouse mode (see
    // `_beginLineSelection`).
    if (_currentPointerUsesTerminalMouse && !_touchLongPressSelecting) {
      return;
    }
    final position = _positionForOffset(
      localPosition,
      size,
      metrics,
      clampToViewport: true,
    );
    final nextSelection = switch (_dragSelectionGranularity) {
      _TerminalSelectionGranularity.word => _extendWordSelection(position),
      _TerminalSelectionGranularity.line => _gestureCoordinator.updateSelection(
        currentSelection: _selection,
        position: position,
        extendSelection: (currentSelection, position) =>
            GhosttyTerminalSelection(
              base: currentSelection.base,
              extent: position,
            ),
        extendLineSelection: (anchorRow, position) =>
            _resolveLineSelectionBetweenRows(anchorRow, position.row),
      ),
      _TerminalSelectionGranularity.cell => _gestureCoordinator.updateSelection(
        currentSelection: _selection,
        position: position,
        extendSelection: (currentSelection, position) =>
            GhosttyTerminalSelection(
              base: currentSelection.base,
              extent: position,
            ),
        extendLineSelection: (anchorRow, position) =>
            _resolveLineSelectionBetweenRows(anchorRow, position.row),
      ),
      _TerminalSelectionGranularity.visualRow =>
        _gestureCoordinator.updateSelection(
          currentSelection: _selection,
          position: position,
          extendSelection: (currentSelection, position) =>
              GhosttyTerminalSelection(
                base: currentSelection.base,
                extent: position,
              ),
          extendLineSelection: (anchorRow, position) =>
              _resolveLineSelectionBetweenRows(
                anchorRow,
                position.row,
                walkWrapChain: false,
              ),
        ),
    };
    if (nextSelection == null) {
      return;
    }
    _setSelection(nextSelection);
    _syncAutoScroll(localPosition, size, metrics);
  }

  GhosttyTerminalSelection? _extendWordSelection(
    GhosttyTerminalCellPosition? position,
  ) {
    final anchor = _wordSelectionAnchor;
    if (anchor == null || position == null) {
      return null;
    }
    final current = _resolveWordSelectionAt(position);
    if (current == null) {
      return null;
    }
    final anchorNormalized = anchor.normalized;
    final currentNormalized = current.normalized;
    final start = anchorNormalized.start.compareTo(currentNormalized.start) <= 0
        ? anchorNormalized.start
        : currentNormalized.start;
    final end = anchorNormalized.end.compareTo(currentNormalized.end) >= 0
        ? anchorNormalized.end
        : currentNormalized.end;
    return GhosttyTerminalSelection(base: start, extent: end);
  }

  void _selectWord(Offset localPosition, Size size, _TerminalMetrics metrics) {
    if (_currentPointerUsesTerminalMouse) {
      return;
    }
    final position = _positionForOffset(localPosition, size, metrics);
    final selection = _gestureCoordinator.completeWordSelection(
      position: position,
      resolveWordSelection: _resolveWordSelectionAt,
    );
    if (selection == null) {
      return;
    }
    _stopAutoScroll();
    _wordSelectionAnchor = selection.normalized;
    _dragSelectionGranularity = _TerminalSelectionGranularity.word;
    _requestTerminalFocus();
    _setSelection(
      selection,
      touchSelectionHandlesVisible: _lastPointerKind == PointerDeviceKind.touch,
    );
  }

  // [granularity] is [_TerminalSelectionGranularity.line] for desktop
  // triple-click (walks the wrap chain → whole logical line) or `visualRow` for
  // touch long-press (stays on the pressed on-screen row, so a full-width TUI
  // row isn't expanded across the whole screen). Drag-extend then continues at
  // the same granularity.
  void _beginLineSelection(
    Offset localPosition,
    Size size,
    _TerminalMetrics metrics, {
    _TerminalSelectionGranularity granularity =
        _TerminalSelectionGranularity.line,
  }) {
    // See `_beginSelection`: a slow pinch can sit inside long-press slop long
    // enough for the recognizer to fire — swallow it while the pinch is live.
    if (_pinchZoomActive) {
      return;
    }
    // A long-press selects even while mouse mode captures touch — that gesture
    // is never claimed by the TUI, so it stays the local copy affordance.
    if (_currentPointerUsesTerminalMouse && !_touchLongPressSelecting) {
      return;
    }
    final walkWrapChain =
        granularity != _TerminalSelectionGranularity.visualRow;
    final position = _positionForOffset(localPosition, size, metrics);
    final selection = _gestureCoordinator.beginLineSelection(
      position: position,
      rowOfPosition: (position) => position.row,
      resolveLineSelection: (position) => _resolveLineSelectionBetweenRows(
        position.row,
        position.row,
        walkWrapChain: walkWrapChain,
      ),
    );
    if (selection == null) {
      return;
    }
    _stopAutoScroll();
    _wordSelectionAnchor = null;
    _dragSelectionGranularity = granularity;
    if (_lastPointerKind == PointerDeviceKind.touch) {
      _touchSelectionActive = true;
    }
    _requestTerminalFocus();
    _setSelection(
      selection,
      touchSelectionHandlesVisible: _lastPointerKind == PointerDeviceKind.touch,
    );
    if (_lastPointerKind == PointerDeviceKind.touch) {
      _scheduleSelectionContextMenu(
        size: size,
        metrics: metrics,
        fallbackLocalPosition: localPosition,
      );
    }
    _syncAutoScroll(localPosition, size, metrics);
  }

  Widget _buildPointerGestureLayer({
    required Size size,
    required _TerminalMetrics metrics,
    required Widget child,
  }) {
    Widget result = child;

    if (widget.touchDragBehavior == GhosttyTerminalTouchDragBehavior.scroll) {
      result = GestureDetector(
        supportedDevices: _touchPointerDevices,
        behavior: HitTestBehavior.opaque,
        // `_touchLongPressSelecting` opens the selection guards for the span of
        // the long-press so a finger can still select/copy while mouse mode is
        // forwarding taps and swipes to the TUI.
        onLongPressStart: (details) {
          _touchLongPressSelecting = true;
          _beginLineSelection(
            details.localPosition,
            size,
            metrics,
            granularity: _TerminalSelectionGranularity.visualRow,
          );
        },
        onLongPressMoveUpdate: (details) =>
            _updateSelection(details.localPosition, size, metrics),
        onLongPressEnd: (_) {
          _touchLongPressSelecting = false;
          _stopAutoScroll();
        },
        // Cancel must stop auto-scroll too: onLongPressStart may have entered an
        // edge band and armed the repeating auto-scroll timer, and cancel (arena
        // loss) fires instead of onLongPressEnd — without this the timer runs away.
        onLongPressCancel: () {
          _touchLongPressSelecting = false;
          _stopAutoScroll();
        },
        child: result,
      );
    }

    // RawGestureDetector (not GestureDetector) so the selection pan
    // recognizer can exclude `PointerDeviceKind.trackpad` from its
    // supported devices. Without the exclusion, trackpad two-finger scroll
    // (`PointerPanZoom*` events, kind=trackpad) is caught by Flutter's
    // default pan recognition and starts a drag-select. Trackpad scroll is
    // handled instead by the outer `Listener`'s `onPointerPanZoom*`
    // callbacks, which feed `_handlePointerPanZoomUpdate`. Regular tap/
    // drag on the touchpad arrives as kind=mouse and is unaffected.
    final selectionPanDevices = _selectionDragDevices
        .where((kind) => kind != PointerDeviceKind.trackpad)
        .toSet();
    final gestures = <Type, GestureRecognizerFactory>{
      LongPressGestureRecognizer:
          GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
            () => LongPressGestureRecognizer(
              supportedDevices: _selectionDragDevices,
            ),
            (recognizer) {
              // Touch long-press selects a single visual row; mouse long-press
              // keeps the wrap-walking logical-line selection (desktop unchanged).
              recognizer.onLongPressStart = (details) {
                if (_lastPointerKind == PointerDeviceKind.touch) {
                  // Mirror the scroll-mode detector above: open the selection
                  // guards for the span of the long-press so a touch can still
                  // select/copy while mouse mode forwards taps to the TUI. This
                  // path owns touch long-press in `selection` drag-behavior;
                  // without the flag, `_beginLineSelection`'s mouse-mode guard
                  // drops the selection.
                  _touchLongPressSelecting = true;
                  _beginLineSelection(
                    details.localPosition,
                    size,
                    metrics,
                    granularity: _TerminalSelectionGranularity.visualRow,
                  );
                } else {
                  _beginLineSelection(details.localPosition, size, metrics);
                }
              };
              recognizer.onLongPressMoveUpdate = (details) =>
                  _updateSelection(details.localPosition, size, metrics);
              recognizer.onLongPressEnd = (_) {
                _touchLongPressSelecting = false;
                _stopAutoScroll();
              };
              recognizer.onLongPressCancel = () {
                _touchLongPressSelecting = false;
                _stopAutoScroll();
              };
            },
          ),
      PanGestureRecognizer:
          GestureRecognizerFactoryWithHandlers<PanGestureRecognizer>(
            () => PanGestureRecognizer(supportedDevices: selectionPanDevices),
            (recognizer) {
              recognizer.onDown = (details) =>
                  _beginSelection(details.localPosition, size, metrics);
              recognizer.onUpdate = (details) =>
                  _updateSelection(details.localPosition, size, metrics);
              recognizer.onEnd = (_) => _stopAutoScroll();
              recognizer.onCancel = _stopAutoScroll;
            },
          ),
    };

    // Thin arena-claimer for touch: a dominantly-vertical touch drag must WIN the
    // gesture arena so an ancestor horizontal pager (the mobile PageView) is
    // rejected — otherwise scrolling the terminal also flips the page (the two
    // collide on diagonal swipes). Flutter's native axis disambiguation handles
    // the rest: a dominantly-horizontal drag never crosses this recognizer's
    // vertical slop, so it stays unclaimed and bubbles to the PageView. The
    // recognizer does no work — wheel/scrollback stays in the out-of-arena
    // `Listener` (onPointerMove) as the single source of motion truth; these
    // callbacks exist only to enter and win the arena. Touch-only via
    // `_touchPointerDevices`, so mouse/stylus/trackpad drags never reach it
    // (desktop drag-select, wheel, keyboard unchanged). Excluded in `selection`
    // drag-behavior, where the selection `PanGestureRecognizer` already claims
    // touch drags and a vertical claimer would fight it.
    if (widget.touchDragBehavior == GhosttyTerminalTouchDragBehavior.scroll) {
      gestures[VerticalDragGestureRecognizer] =
          GestureRecognizerFactoryWithHandlers<VerticalDragGestureRecognizer>(
            () => VerticalDragGestureRecognizer(
              supportedDevices: _touchPointerDevices,
            ),
            (recognizer) {
              // Winning the arena means this is a dominantly-vertical touch drag:
              // mark the gesture `won` so the out-of-arena `Listener` may forward
              // scroll/wheel. Losing means an ancestor horizontal pager claimed
              // the touch (a dominantly-horizontal swipe): mark it `lost` so a
              // diagonal swipe flips the page WITHOUT also scrolling the terminal.
              recognizer.onStart = (_) {
                _active?.arenaOutcome = _TouchArenaOutcome.won;
              };
              recognizer.onUpdate = (_) {};
              recognizer.onCancel = () {
                _active?.arenaOutcome = _TouchArenaOutcome.lost;
              };
            },
          );
    }

    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: gestures,
      child: result,
    );
  }

  @override
  Widget build(BuildContext context) {
    final metrics = _measureMetrics();

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        _lastMeasuredLinePixels = metrics.linePixels;
        _autoScrollSession.updateLayout(layoutSize: size, metrics: metrics);
        _syncGrid(size, metrics);
        final viewport = _viewportFor(size, metrics);
        _lastVisibleStartLine = viewport.startLine;

        return Focus(
          focusNode: _focusNode,
          autofocus: widget.autofocus,
          onKeyEvent: _handleKey,
          child: MouseRegion(
            cursor: _hoveredHyperlink == null
                ? SystemMouseCursors.text
                : SystemMouseCursors.click,
            onExit: (_) {
              if (ghosttyTerminalClearHoveredLink<GhosttyTerminalSelection>(
                session: _selectionSession,
              )) {
                setState(() {});
              }
            },
            onHover: (event) {
              if (!_terminalMouseReportingEnabled) {
                _updateHoveredHyperlink(event.localPosition, size, metrics);
              }
              _sendMouseEvent(
                GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_MOTION,
                event,
                size,
                metrics,
              );
            },
            child: Listener(
              onPointerDown: (event) {
                _lastPointerKind = event.kind;
                _startTouchScroll(event);
                _requestTerminalFocus();
                // Touch defers its PRESS to pointer-up (tap → click) or
                // converts drag into wheel scroll; only real mice press on down.
                if (event.kind == PointerDeviceKind.touch) {
                  _onTouchMousePointerDown(event);
                  // After the single-finger starters: a second finger promotes
                  // the gesture to a pinch, which resets whatever they tracked.
                  _pinchZoomPointerDown(event);
                } else {
                  _sendMouseEvent(
                    GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_PRESS,
                    event,
                    size,
                    metrics,
                  );
                }
              },
              onPointerMove: (event) {
                if (event.kind == PointerDeviceKind.touch) {
                  _pinchZoomPointerMove(event);
                  _updateTouchScroll(event, size, metrics);
                  _onTouchMousePointerMove(event, size, metrics);
                } else {
                  _sendMouseEvent(
                    GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_MOTION,
                    event,
                    size,
                    metrics,
                  );
                }
              },
              onPointerUp: (event) {
                if (event.kind == PointerDeviceKind.touch) {
                  _pinchZoomPointerUpOrCancel(event);
                  _endTouchScroll(event);
                  _onTouchMousePointerUp(event, size, metrics);
                } else {
                  _sendMouseEvent(
                    GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_RELEASE,
                    event,
                    size,
                    metrics,
                  );
                }
              },
              onPointerCancel: (event) {
                if (event.kind == PointerDeviceKind.touch) {
                  _pinchZoomPointerUpOrCancel(event);
                  _endTouchScroll(event);
                  _onTouchMousePointerCancel(event);
                } else {
                  _sendMouseEvent(
                    GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_RELEASE,
                    event,
                    size,
                    metrics,
                  );
                }
              },
              onPointerSignal: (event) =>
                  _handlePointerSignal(event, size, metrics),
              onPointerPanZoomStart: _handlePointerPanZoomStart,
              onPointerPanZoomUpdate: (event) =>
                  _handlePointerPanZoomUpdate(event, size, metrics),
              onPointerPanZoomEnd: _handlePointerPanZoomEnd,
              child: RawGestureDetector(
                behavior: HitTestBehavior.opaque,
                gestures: <Type, GestureRecognizerFactory>{
                  SerialTapGestureRecognizer:
                      GestureRecognizerFactoryWithHandlers<
                        SerialTapGestureRecognizer
                      >(SerialTapGestureRecognizer.new, (recognizer) {
                        recognizer.onSerialTapDown = _recordSerialTapDown;
                        recognizer.onSerialTapUp = (details) =>
                            _handleSerialTapUp(details, size, metrics);
                      }),
                },
                child: _buildPointerGestureLayer(
                  size: size,
                  metrics: metrics,
                  child: Stack(
                    children: [
                      if (widget.showHeader)
                        SizedBox(
                          key: const ValueKey('terminalHeader'),
                          height: _terminalHeaderHeight,
                        ),
                      _buildScrollLayer(size, metrics, viewport),
                      RepaintBoundary(
                        child: CustomPaint(
                          key: const ValueKey('terminalPainter'),
                          painter: _GhosttyTerminalPainter(
                            revision: widget.controller.revision,
                            title: widget.controller.title,
                            snapshot: widget.controller.snapshot,
                            renderSnapshot: widget.controller.renderSnapshot,
                            renderer: widget.renderer,
                            running: widget.controller.isRunning,
                            focused: _focusNode.hasFocus,
                            showFocusRing: widget.showFocusRing,
                            cols: widget.controller.cols,
                            rows: widget.controller.rows,
                            scrollOffsetLines: _scrollOffsetLines,
                            visibleStartLine: viewport.startLine,
                            charWidth: metrics.charWidth,
                            linePixels: metrics.linePixels,
                            backgroundColor: widget.backgroundColor,
                            foregroundColor: widget.foregroundColor,
                            chromeColor: widget.chromeColor,
                            cursorColor: widget.cursorColor,
                            selectionColor: widget.selectionColor,
                            hyperlinkColor: widget.hyperlinkColor,
                            minimumContrastRatio: widget.minimumContrastRatio,
                            contrastFloorCache: _contrastFloorCache,
                            fontSize: widget.fontSize,
                            fontFamily: widget.fontFamily ?? 'monospace',
                            fontFamilyFallback: widget.fontFamilyFallback,
                            fontPackage: widget.fontPackage,
                            letterSpacing: metrics.letterSpacing,
                            padding: _effectivePadding(size, metrics),
                            headerHeight: _headerHeight,
                            devicePixelRatio: MediaQuery.devicePixelRatioOf(
                              context,
                            ),
                            selection: _selection,
                            nativeRunPainterCache: _nativeRunPainterCache,
                            nativeRunIntrinsicWidthCache:
                                _nativeRunIntrinsicWidthCache,
                          ),
                          child: const SizedBox.expand(),
                        ),
                      ),
                      _buildSelectionHandleOverlay(size, metrics, viewport),
                      _buildScrollbarOverlay(size, metrics, viewport),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

String _renderSnapshotTextForSelection(
  GhosttyTerminalRenderSnapshot snapshot,
  GhosttyTerminalSelection selection, {
  required int viewportStartLine,
  required GhosttyTerminalCopyOptions options,
}) {
  if (!snapshot.hasViewportData) {
    return '';
  }

  final normalized = selection.normalized;
  final startRow = math.max(normalized.start.row, viewportStartLine);
  final endRow = math.min(
    normalized.end.row,
    viewportStartLine + snapshot.rowsData.length - 1,
  );
  if (endRow < startRow) {
    return '';
  }

  final buffer = StringBuffer();
  for (var row = startRow; row <= endRow; row++) {
    final localRow = row - viewportStartLine;
    final renderRow = snapshot.rowsData[localRow];
    final rowCellCount = renderRow.cells.fold<int>(
      0,
      (sum, cell) => sum + cell.width,
    );
    final startCol = row == startRow ? normalized.start.col : 0;
    final endCol = row == endRow ? normalized.end.col : rowCellCount - 1;
    if (rowCellCount > 0 && endCol >= startCol) {
      final text = _renderRowTextForCellRange(renderRow, startCol, endCol);
      buffer.write(options.trimTrailingSpaces ? text.trimRight() : text);
    }
    if (row != endRow) {
      final nextRow = snapshot.rowsData[localRow + 1];
      final joinsWrappedLine =
          options.joinWrappedLines &&
          renderRow.wrap &&
          nextRow.wrapContinuation;
      buffer.write(joinsWrappedLine ? options.wrappedLineJoiner : '\n');
    }
  }
  return buffer.toString();
}

String _renderRowTextForCellRange(
  GhosttyTerminalRenderRow row,
  int startCol,
  int endColInclusive,
) {
  if (endColInclusive < startCol) {
    return '';
  }

  final buffer = StringBuffer();
  var col = 0;
  for (final cell in row.cells) {
    final cellStart = col;
    final cellEnd = col + cell.width - 1;
    col += cell.width;
    if (cellEnd < startCol) {
      continue;
    }
    if (cellStart > endColInclusive) {
      break;
    }

    if (cell.text.isNotEmpty) {
      buffer.write(cell.text);
      continue;
    }

    final overlapStart = math.max(startCol, cellStart);
    final overlapEnd = math.min(endColInclusive, cellEnd);
    final overlapWidth = overlapEnd - overlapStart + 1;
    if (overlapWidth > 0) {
      buffer.write(' ' * overlapWidth);
    }
  }
  return buffer.toString();
}

String? _renderSnapshotHyperlinkAt(
  GhosttyTerminalRenderSnapshot snapshot,
  GhosttyTerminalCellPosition position, {
  required int viewportStartLine,
}) {
  if (!snapshot.hasViewportData) {
    return null;
  }

  final localRow = position.row - viewportStartLine;
  if (localRow < 0 || localRow >= snapshot.rowsData.length) {
    return null;
  }

  final segment = _renderSnapshotLogicalSegment(
    snapshot,
    localRow: localRow,
    viewportStartLine: viewportStartLine,
  );
  final targetSegmentCol = segment.rowCellOffsets[localRow]! + position.col;
  for (final match in _renderStateUrlPattern.allMatches(segment.text)) {
    final raw = match.group(0);
    if (raw == null || raw.isEmpty) {
      continue;
    }

    final trimmed = raw.replaceFirst(RegExp(r'[),.;:!?]+$'), '');
    if (trimmed.isEmpty) {
      continue;
    }

    final prefixCellCount = match.start;
    final linkCellCount = trimmed.length;
    final startCol = prefixCellCount;
    final endCol = startCol + linkCellCount - 1;
    if (targetSegmentCol >= startCol && targetSegmentCol <= endCol) {
      return trimmed;
    }
  }

  return null;
}

GhosttyTerminalSelection? _renderSnapshotWordSelectionAt(
  GhosttyTerminalRenderSnapshot snapshot,
  GhosttyTerminalCellPosition position, {
  required int viewportStartLine,
  required GhosttyTerminalWordBoundaryPolicy policy,
}) {
  if (!snapshot.hasViewportData) {
    return null;
  }

  final localRow = position.row - viewportStartLine;
  if (localRow < 0 || localRow >= snapshot.rowsData.length) {
    return null;
  }

  final segment = _renderSnapshotLogicalSegment(
    snapshot,
    localRow: localRow,
    viewportStartLine: viewportStartLine,
  );
  if (segment.cells.isEmpty) {
    return null;
  }

  final targetSegmentCol =
      (segment.rowCellOffsets[localRow] ?? 0) + position.col;
  final normalizedCol = targetSegmentCol.clamp(0, segment.cells.length - 1);
  final classification = _classifyRenderStateCharacter(
    segment.cells[normalizedCol],
    policy: policy,
  );
  var start = normalizedCol;
  var end = normalizedCol;
  while (start > 0 &&
      _classifyRenderStateCharacter(segment.cells[start - 1], policy: policy) ==
          classification) {
    start--;
  }
  while (end + 1 < segment.cells.length &&
      _classifyRenderStateCharacter(segment.cells[end + 1], policy: policy) ==
          classification) {
    end++;
  }

  final startPosition = _renderSnapshotSegmentPositionAtColumn(
    segment,
    segmentColumn: start,
    viewportStartLine: viewportStartLine,
  );
  final endPosition = _renderSnapshotSegmentPositionAtColumn(
    segment,
    segmentColumn: end,
    viewportStartLine: viewportStartLine,
  );
  if (startPosition == null || endPosition == null) {
    return null;
  }

  return GhosttyTerminalSelection(base: startPosition, extent: endPosition);
}

// When [walkWrapChain] is true (desktop line selection) the span grows to cover
// the whole soft-wrapped logical line; when false (touch visual-row selection)
// it stays on the pressed on-screen rows, so a full-width TUI row isn't expanded
// across the entire screen.
GhosttyTerminalSelection? _renderSnapshotLineSelectionBetweenRows(
  GhosttyTerminalRenderSnapshot snapshot,
  int baseRow,
  int extentRow, {
  required int viewportStartLine,
  bool walkWrapChain = true,
}) {
  if (!snapshot.hasViewportData || snapshot.rowsData.isEmpty) {
    return null;
  }

  final minRow = viewportStartLine;
  final maxRow = viewportStartLine + snapshot.rowsData.length - 1;
  final startRow = baseRow.clamp(minRow, maxRow);
  final endRow = extentRow.clamp(minRow, maxRow);
  var normalizedStart = math.min(startRow, endRow) - viewportStartLine;
  var normalizedEnd = math.max(startRow, endRow) - viewportStartLine;
  if (walkWrapChain) {
    while (normalizedStart > 0 &&
        snapshot.rowsData[normalizedStart].wrapContinuation) {
      normalizedStart--;
    }
    while (normalizedEnd + 1 < snapshot.rowsData.length &&
        snapshot.rowsData[normalizedEnd].wrap) {
      normalizedEnd++;
    }
  }
  final endCol = math.max(
    0,
    snapshot.rowsData[normalizedEnd].cells.fold<int>(
          0,
          (sum, cell) => sum + cell.width,
        ) -
        1,
  );
  return GhosttyTerminalSelection(
    base: GhosttyTerminalCellPosition(
      row: viewportStartLine + normalizedStart,
      col: 0,
    ),
    extent: GhosttyTerminalCellPosition(
      row: viewportStartLine + normalizedEnd,
      col: endCol,
    ),
  );
}

List<String> _renderRowWordCells(GhosttyTerminalRenderRow row) {
  final cells = <String>[];
  for (final cell in row.cells) {
    final text = cell.text.isNotEmpty ? cell.text : ' ';
    for (var i = 0; i < cell.width; i++) {
      cells.add(text);
    }
  }
  return cells;
}

_RenderSnapshotLogicalSegment _renderSnapshotLogicalSegment(
  GhosttyTerminalRenderSnapshot snapshot, {
  required int localRow,
  required int viewportStartLine,
}) {
  var start = localRow;
  while (start > 0 && snapshot.rowsData[start].wrapContinuation) {
    start--;
  }

  var end = localRow;
  while (end + 1 < snapshot.rowsData.length && snapshot.rowsData[end].wrap) {
    end++;
  }

  final buffer = StringBuffer();
  final cells = <String>[];
  final rowCellOffsets = <int, int>{};
  final rowCellCounts = <int, int>{};
  var runningOffset = 0;
  for (var row = start; row <= end; row++) {
    rowCellOffsets[row] = runningOffset;
    final rowCells = _renderRowWordCells(snapshot.rowsData[row]);
    rowCellCounts[row] = rowCells.length;
    for (final cell in rowCells) {
      buffer.write(cell);
      cells.add(cell);
    }
    runningOffset += rowCells.length;
  }

  return _RenderSnapshotLogicalSegment(
    text: buffer.toString(),
    cells: cells,
    rowCellOffsets: rowCellOffsets,
    rowCellCounts: rowCellCounts,
  );
}

GhosttyTerminalCellPosition? _renderSnapshotSegmentPositionAtColumn(
  _RenderSnapshotLogicalSegment segment, {
  required int segmentColumn,
  required int viewportStartLine,
}) {
  final orderedRows = segment.rowCellOffsets.keys.toList()..sort();
  for (final localRow in orderedRows) {
    final rowOffset = segment.rowCellOffsets[localRow] ?? 0;
    final rowCellCount = segment.rowCellCounts[localRow] ?? 0;
    if (rowCellCount <= 0) {
      continue;
    }
    if (segmentColumn >= rowOffset &&
        segmentColumn < rowOffset + rowCellCount) {
      return GhosttyTerminalCellPosition(
        row: viewportStartLine + localRow,
        col: segmentColumn - rowOffset,
      );
    }
  }
  return null;
}

_RenderStateCellClass _classifyRenderStateCharacter(
  String text, {
  required GhosttyTerminalWordBoundaryPolicy policy,
}) {
  if (text.trim().isEmpty) {
    return _RenderStateCellClass.whitespace;
  }
  if (_isRenderStateWordLikeCharacter(text, policy: policy)) {
    return _RenderStateCellClass.word;
  }
  return _RenderStateCellClass.other;
}

bool _isRenderStateWordLikeCharacter(
  String text, {
  required GhosttyTerminalWordBoundaryPolicy policy,
}) {
  final extra = policy.extraWordCharacters;
  for (final rune in text.runes) {
    if ((rune >= 0x30 && rune <= 0x39) ||
        (rune >= 0x41 && rune <= 0x5A) ||
        (rune >= 0x61 && rune <= 0x7A) ||
        extra.contains(String.fromCharCode(rune)) ||
        (policy.treatNonAsciiAsWord && rune > 0x7F)) {
      continue;
    }
    return false;
  }
  return true;
}

enum _RenderStateCellClass { whitespace, word, other }

final RegExp _renderStateUrlPattern = RegExp(
  r'''(https?:\/\/[^\s<>"']+|mailto:[^\s<>"']+)''',
);

final class _RenderSnapshotLogicalSegment {
  const _RenderSnapshotLogicalSegment({
    required this.text,
    required this.cells,
    required this.rowCellOffsets,
    required this.rowCellCounts,
  });

  final String text;
  final List<String> cells;
  final Map<int, int> rowCellOffsets;
  final Map<int, int> rowCellCounts;
}

class _TerminalSelectionHandlePainter extends CustomPainter {
  const _TerminalSelectionHandlePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final centerX = size.width / 2;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final strokePaint = Paint()
      ..color = color
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 2;
    final stemTop = _selectionHandleVisualRadius;
    final stemBottom = stemTop + _selectionHandleStemHeight;
    canvas.drawLine(
      Offset(centerX, stemTop),
      Offset(centerX, stemBottom),
      strokePaint,
    );
    canvas.drawCircle(
      Offset(centerX, stemBottom + _selectionHandleVisualRadius),
      _selectionHandleVisualRadius,
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _TerminalSelectionHandlePainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

class _GhosttyTerminalPainter extends CustomPainter {
  _GhosttyTerminalPainter({
    required this.revision,
    required this.title,
    required this.snapshot,
    required this.renderSnapshot,
    required this.renderer,
    required this.running,
    required this.focused,
    required this.showFocusRing,
    required this.cols,
    required this.rows,
    required this.scrollOffsetLines,
    required this.visibleStartLine,
    required this.charWidth,
    required this.linePixels,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.chromeColor,
    required this.cursorColor,
    required this.selectionColor,
    required this.hyperlinkColor,
    required this.minimumContrastRatio,
    required this.contrastFloorCache,
    required this.fontSize,
    required this.fontFamily,
    required this.fontFamilyFallback,
    required this.fontPackage,
    required this.letterSpacing,
    required this.padding,
    required this.headerHeight,
    required this.devicePixelRatio,
    required this.selection,
    required this.nativeRunPainterCache,
    required this.nativeRunIntrinsicWidthCache,
  });

  final int revision;
  final String title;
  final GhosttyTerminalSnapshot snapshot;
  final GhosttyTerminalRenderSnapshot? renderSnapshot;
  final GhosttyTerminalRendererMode renderer;
  final bool running;
  final bool focused;
  final bool showFocusRing;
  final int cols;
  final int rows;
  final int scrollOffsetLines;
  final int visibleStartLine;
  final double charWidth;
  final double linePixels;
  final Color backgroundColor;
  final Color foregroundColor;
  final Color chromeColor;
  final Color cursorColor;
  final Color selectionColor;
  final Color hyperlinkColor;
  final double? minimumContrastRatio;

  /// Shared with (and cleared by) the owning State — see `_contrastFloorCache`.
  final HashMap<(int, int), Color> contrastFloorCache;
  final double fontSize;
  final String fontFamily;
  final List<String>? fontFamilyFallback;
  final String? fontPackage;
  final double letterSpacing;
  final EdgeInsets padding;
  final double headerHeight;
  final double devicePixelRatio;
  final GhosttyTerminalSelection? selection;
  final _TerminalTextPainterCache nativeRunPainterCache;
  final _TerminalTextIntrinsicWidthCache nativeRunIntrinsicWidthCache;

  @override
  void paint(Canvas canvas, Size size) {
    final fullRect = Offset.zero & size;
    canvas.drawRect(fullRect, Paint()..color = backgroundColor);

    if (headerHeight > 0) {
      final headerRect = Rect.fromLTWH(0, 0, size.width, headerHeight);
      canvas.drawRect(headerRect, Paint()..color = chromeColor);

      final dotColor = running
          ? const Color(0xFF2BD576)
          : const Color(0xFFD65C5C);
      canvas.drawCircle(
        Offset(12, headerHeight / 2),
        4,
        Paint()..color = dotColor,
      );

      final titlePainter = TextPainter(
        text: TextSpan(
          text: title,
          style: TextStyle(
            color: foregroundColor.withValues(alpha: 0.95),
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '...',
      )..layout(maxWidth: size.width - 140);
      titlePainter.paint(canvas, Offset(22, (headerHeight - 14) / 2));

      final status = [
        '${cols}x$rows${scrollOffsetLines > 0 ? '  +$scrollOffsetLines' : ''}',
        _widgetModeLabel(renderer, renderSnapshot),
      ].join('  •  ');
      final statusPainter = TextPainter(
        text: TextSpan(
          text: status,
          style: TextStyle(
            color: foregroundColor.withValues(alpha: 0.68),
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout(maxWidth: size.width - 24);
      statusPainter.paint(
        canvas,
        Offset(size.width - statusPainter.width - 12, (headerHeight - 13) / 2),
      );
    }

    final contentTop = headerHeight + padding.top;
    final contentHeight = size.height - contentTop - padding.bottom;
    if (contentHeight <= 0) {
      return;
    }

    final contentRect = Rect.fromLTWH(
      padding.left,
      contentTop,
      size.width - padding.horizontal,
      contentHeight,
    );

    canvas.save();
    canvas.clipRect(contentRect);
    final nativeRender = renderSnapshot;
    if (renderer == GhosttyTerminalRendererMode.renderState &&
        nativeRender != null &&
        nativeRender.hasViewportData) {
      // Respect widget defaults for the viewport baseline while still mapping
      // native explicit colors against Ghostty's original defaults.
      canvas.drawRect(contentRect, Paint()..color = backgroundColor);
      _paintNativeRenderState(
        canvas,
        contentTop: contentTop,
        visibleStartLine: visibleStartLine,
        defaultForeground: foregroundColor,
        defaultBackground: backgroundColor,
        nativeDefaultForeground: nativeRender.foregroundColor,
        nativeDefaultBackground: nativeRender.backgroundColor,
        linePixels: linePixels,
        rowsData: nativeRender.rowsData,
      );
      _paintNativeCursor(
        canvas,
        contentTop: contentTop,
        linePixels: linePixels,
        visibleRows: nativeRender.rowsData.length,
        cursor: nativeRender.cursor,
        color: cursorColor,
      );
      canvas.restore();
      // Port of Ghostty's `window-padding-color=extend`: bleed the edge
      // cells' background into the padding gutters so a TUI whose bg differs
      // from the chrome (e.g. opencode's #0a0a0a vs our bgDeepest) doesn't
      // show a mismatched strip around the grid. Painted AFTER `restore()`
      // so it lands in the padding region (outside the content clip).
      _paintPaddingExtend(
        canvas,
        size: size,
        contentTop: contentTop,
        defaultForeground: foregroundColor,
        defaultBackground: backgroundColor,
        nativeDefaultForeground: nativeRender.foregroundColor,
        nativeDefaultBackground: nativeRender.backgroundColor,
        linePixels: linePixels,
        rowsData: nativeRender.rowsData,
      );
      if (focused && showFocusRing) {
        final focusPaint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = const Color(0xFF2A83FF);
        canvas.drawRect(fullRect.deflate(0.5), focusPaint);
      }
      return;
    }

    // The engine renderState path is the only renderer. A null/empty render
    // snapshot (e.g. web, which has no native engine) paints background only.
    canvas.drawRect(contentRect, Paint()..color = backgroundColor);
    canvas.restore();

    if (focused && showFocusRing) {
      final focusPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0xFF2A83FF);
      canvas.drawRect(fullRect.deflate(0.5), focusPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _GhosttyTerminalPainter oldDelegate) {
    return revision != oldDelegate.revision ||
        title != oldDelegate.title ||
        running != oldDelegate.running ||
        focused != oldDelegate.focused ||
        showFocusRing != oldDelegate.showFocusRing ||
        cols != oldDelegate.cols ||
        rows != oldDelegate.rows ||
        scrollOffsetLines != oldDelegate.scrollOffsetLines ||
        visibleStartLine != oldDelegate.visibleStartLine ||
        charWidth != oldDelegate.charWidth ||
        linePixels != oldDelegate.linePixels ||
        fontSize != oldDelegate.fontSize ||
        fontFamily != oldDelegate.fontFamily ||
        !listEquals(fontFamilyFallback, oldDelegate.fontFamilyFallback) ||
        fontPackage != oldDelegate.fontPackage ||
        letterSpacing != oldDelegate.letterSpacing ||
        padding != oldDelegate.padding ||
        headerHeight != oldDelegate.headerHeight ||
        devicePixelRatio != oldDelegate.devicePixelRatio ||
        backgroundColor != oldDelegate.backgroundColor ||
        foregroundColor != oldDelegate.foregroundColor ||
        chromeColor != oldDelegate.chromeColor ||
        cursorColor != oldDelegate.cursorColor ||
        selectionColor != oldDelegate.selectionColor ||
        hyperlinkColor != oldDelegate.hyperlinkColor ||
        minimumContrastRatio != oldDelegate.minimumContrastRatio ||
        selection != oldDelegate.selection ||
        renderer != oldDelegate.renderer ||
        !_renderSnapshotEquals(renderSnapshot, oldDelegate.renderSnapshot) ||
        !listEquals(snapshot.lines, oldDelegate.snapshot.lines) ||
        snapshot.cursor != oldDelegate.snapshot.cursor;
  }

  void _paintNativeRenderState(
    Canvas canvas, {
    required double contentTop,
    required int visibleStartLine,
    required Color defaultForeground,
    required Color defaultBackground,
    required Color nativeDefaultForeground,
    required Color nativeDefaultBackground,
    required double linePixels,
    required List<GhosttyTerminalRenderRow> rowsData,
  }) {
    for (var rowIndex = 0; rowIndex < rowsData.length; rowIndex++) {
      final row = rowsData[rowIndex];
      final rowBand = _rowBand(
        contentTop: contentTop,
        rowIndex: rowIndex,
        linePixels: linePixels,
        devicePixelRatio: devicePixelRatio,
      );
      final y = rowBand.top;
      final logicalRow = visibleStartLine + rowIndex;
      final runs = _collectNativeRuns(
        row.cells,
        defaultForeground: defaultForeground,
        defaultBackground: defaultBackground,
        nativeDefaultForeground: nativeDefaultForeground,
        nativeDefaultBackground: nativeDefaultBackground,
      );
      for (final run in runs) {
        if (run.width <= 0) {
          continue;
        }
        final width = run.width * charWidth;
        final rect = Rect.fromLTWH(
          padding.left + (run.startCol * charWidth),
          rowBand.top,
          width,
          rowBand.height,
        );
        if (run.background.a > 0) {
          canvas.drawRect(rect, Paint()..color = run.background);
        }
      }
      _paintNativeSelection(
        canvas,
        row: logicalRow,
        cellCount: row.cells.fold<int>(0, (sum, cell) => sum + cell.width),
        y: rowBand.top,
        rowHeight: rowBand.height,
      );
      for (final run in runs) {
        if (run.width <= 0) {
          continue;
        }
        final width = run.width * charWidth;
        final startCol = run.startCol;
        final rect = Rect.fromLTWH(
          padding.left + (startCol * charWidth),
          rowBand.top,
          width,
          rowBand.height,
        );
        if (run.hasRenderableText) {
          final foreground = _resolveNativeForeground(
            style: run.style,
            defaultForeground: defaultForeground,
            defaultBackground: defaultBackground,
            nativeDefaultForeground: nativeDefaultForeground,
            nativeDefaultBackground: nativeDefaultBackground,
            metadataColor: _resolveMetadataBackgroundColor(
              metadata: run.metadata,
              fallback: run.metadataBackground,
            ),
            hasHyperlink: run.hasHyperlink,
          );
          // _resolveNativeForeground already applies the hyperlink override
          // (and the contrast floor on top of it); re-deriving it here from
          // the raw hyperlinkColor would bypass the floor.
          final textForeground = foreground;
          final decorationColor = run.style.hasExplicitUnderlineColor
              ? run.style.underlineColor
              : textForeground;
          final textStyle = TextStyle(
            color: textForeground,
            fontFamily: fontFamily,
            fontFamilyFallback: fontFamilyFallback,
            package: fontPackage,
            fontSize: fontSize,
            height: linePixels / fontSize,
            letterSpacing: letterSpacing,
            fontWeight: run.style.bold ? FontWeight.w700 : FontWeight.w400,
            fontStyle: run.style.italic ? FontStyle.italic : FontStyle.normal,
            decoration: _nativeTextDecoration(
              style: run.style,
              hasHyperlink: run.hasHyperlink,
            ),
            decorationStyle: _nativeDecorationStyle(
              underline: run.style.underline,
              hasHyperlink: run.hasHyperlink,
            ),
            decorationColor: decorationColor,
          );
          final graphemes = _splitTerminalCells(
            run.text,
          ).toList(growable: false);
          if (graphemes.isNotEmpty) {
            final graphemeWidths =
                run.graphemeCellWidths.length == graphemes.length
                ? run.graphemeCellWidths
                : _measureTerminalCellWidths(run.text, run.width);
            final canPaintAsSingleRun =
                graphemes.length == run.width &&
                graphemeWidths.every((widthCells) => widthCells == 1) &&
                _isSafeSingleRunText(run.text) &&
                _shouldPaintTerminalRunAsSingleRun(
                  text: run.text,
                  width: run.width * charWidth,
                  fontWeight: run.style.bold
                      ? FontWeight.w700
                      : FontWeight.w400,
                  fontStyle: run.style.italic
                      ? FontStyle.italic
                      : FontStyle.normal,
                );
            if (canPaintAsSingleRun) {
              final painter = nativeRunPainterCache.resolve(
                _TerminalTextPainterKey(
                  text: run.text,
                  width: rect.width,
                  fontSize: fontSize,
                  lineHeight: linePixels / fontSize,
                  fontFamily: fontFamily,
                  fontFamilyFallback: fontFamilyFallback,
                  fontPackage: fontPackage,
                  letterSpacing: letterSpacing,
                  color: textForeground,
                  fontWeight: run.style.bold
                      ? FontWeight.w700
                      : FontWeight.w400,
                  fontStyle: run.style.italic
                      ? FontStyle.italic
                      : FontStyle.normal,
                  decoration: _nativeTextDecoration(
                    style: run.style,
                    hasHyperlink: run.hasHyperlink,
                  ),
                  decorationStyle: _nativeDecorationStyle(
                    underline: run.style.underline,
                    hasHyperlink: run.hasHyperlink,
                  ),
                  decorationColor: decorationColor,
                ),
              );
              canvas.save();
              canvas.clipRect(rect);
              painter.paint(canvas, Offset(rect.left, y));
              canvas.restore();
            } else {
              // Per-glyph fallback for runs that can't be painted as a single
              // run (wide cells, custom-painted glyphs, or text failing the
              // single-run safety checks). Mirror ghostty-web's model: clip to
              // the run, then place each glyph left-aligned on the shared row
              // baseline at its natural font size — exactly the single-run
              // path's `painter.paint(canvas, Offset(rect.left, rowBand.top))`,
              // where `textStyle.height` positions the baseline within the line
              // box. The previous `_centerGlyphInCell` centered glyphs on their
              // tight ink bounds, which distorted apparent width and pulled
              // glyphs off the baseline relative to their neighbors.
              // Relax the clip around the run. Oversized fallback-font symbols
              // (e.g. dingbats like U+273D pulled from a system symbol font)
              // carry a near-1em advance that is wider than the mono cell; left-
              // aligned and clipped to the run's right edge, the glyph's right
              // half gets shaved ("half" star). Allowing roughly a cell of
              // overflow on each side — paired with centering oversized glyphs
              // below — keeps the whole glyph visible, bleeding into the
              // adjacent (blank, for a spinner) cell rather than clipping. The
              // outer content-rect clip still bounds the paint. Glyphs that fit
              // (…, −) stay left-aligned on the baseline, exactly as before.
              canvas.save();
              canvas.clipRect(
                Rect.fromLTRB(
                  rect.left - charWidth,
                  rect.top - linePixels,
                  rect.right + charWidth,
                  rect.bottom + linePixels,
                ),
              );
              var textX = rect.left;
              for (var index = 0; index < graphemes.length; index++) {
                final character = graphemes[index];
                final widthCells = index < graphemeWidths.length
                    ? graphemeWidths[index]
                    : 1;
                final cellWidth = widthCells * charWidth;
                final cellRect = Rect.fromLTRB(
                  textX,
                  rowBand.top,
                  textX + cellWidth,
                  rowBand.bottom,
                );
                if (widthCells == 1 &&
                    _paintTerminalSpecialGlyph(
                      canvas,
                      character,
                      rect: cellRect,
                      color: textForeground,
                    )) {
                  textX += cellWidth;
                  continue;
                }
                _debugLogUnsupportedGlyph(character);
                final painter = TextPainter(
                  text: TextSpan(
                    text: character,
                    style: textStyle.copyWith(letterSpacing: 0),
                  ),
                  textDirection: TextDirection.ltr,
                  maxLines: 1,
                )..layout();
                // A glyph wider than its cell (oversized symbol-font fallback)
                // is centered so it overflows symmetrically into the relaxed
                // clip instead of being shaved on the right. Glyphs that fit
                // keep left-aligned baseline placement.
                final glyphX = painter.width > cellWidth
                    ? textX + (cellWidth - painter.width) / 2
                    : textX;
                painter.paint(canvas, Offset(glyphX, rowBand.top));
                textX += cellWidth;
              }
              canvas.restore();
            }
          }
        }
      }
    }
  }

  void _paintNativeCursor(
    Canvas canvas, {
    required double contentTop,
    required double linePixels,
    required int visibleRows,
    required GhosttyTerminalRenderCursor cursor,
    required Color color,
  }) {
    if (!cursor.visible ||
        !cursor.hasViewportPosition ||
        cursor.row == null ||
        cursor.col == null) {
      return;
    }
    if (cursor.row! < 0 || cursor.row! >= visibleRows) {
      return;
    }
    if (cursor.col! < 0 || cursor.col! >= cols) {
      return;
    }
    final widthCells = cursor.onWideTail ? 2 : 1;
    final startCol = cursor.onWideTail
        ? math.max(0, cursor.col! - 1)
        : cursor.col!;
    final rowBand = _rowBand(
      contentTop: contentTop,
      rowIndex: cursor.row!,
      linePixels: linePixels,
      devicePixelRatio: devicePixelRatio,
    );
    final cursorRect = Rect.fromLTWH(
      padding.left + (startCol * charWidth),
      rowBand.top,
      charWidth * widthCells,
      rowBand.height,
    );
    final snappedCursorLeft = _snapLogicalToPhysical(
      cursorRect.left,
      devicePixelRatio,
    );
    final snappedCursorWidth = _snapLogicalExtentToPhysical(
      cursorRect.width,
      devicePixelRatio,
    );
    final shouldShowCursorFill = focused || !cursor.blinking;
    final drawColor = color.withValues(
      alpha: cursor.passwordInput ? 0.95 : (focused ? 0.95 : 0.8),
    );
    final strokeColor = drawColor.withValues(alpha: 0.85);
    final fillPaint = Paint()..color = drawColor;
    final strokePaint = Paint()
      ..color = strokeColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(0.8, linePixels * 0.08);

    final barWidth = _snapLogicalExtentToPhysical(
      math.max(2.0, charWidth * 0.2),
      devicePixelRatio,
    );
    final underlineHeight = _snapLogicalExtentToPhysical(
      math.max(1.5, linePixels * 0.12),
      devicePixelRatio,
    );
    final shapeRect = switch (cursor.visualStyle) {
      GhosttyRenderStateCursorVisualStyle
          .GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR =>
        Rect.fromLTWH(snappedCursorLeft, rowBand.top, barWidth, rowBand.height),
      GhosttyRenderStateCursorVisualStyle
          .GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE =>
        Rect.fromLTWH(
          snappedCursorLeft,
          _snapLogicalToPhysical(
            cursorRect.bottom - underlineHeight,
            devicePixelRatio,
          ),
          snappedCursorWidth,
          underlineHeight,
        ),
      GhosttyRenderStateCursorVisualStyle
          .GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW =>
        cursorRect,
      _ => cursorRect,
    };

    switch (cursor.visualStyle) {
      case GhosttyRenderStateCursorVisualStyle
          .GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW:
        canvas.drawRect(
          shapeRect,
          Paint()
            ..color = drawColor.withValues(alpha: 0.22)
            ..style = PaintingStyle.fill,
        );
        if (shouldShowCursorFill) {
          canvas.drawRect(shapeRect.deflate(0.5), strokePaint);
        }
      case GhosttyRenderStateCursorVisualStyle
          .GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE:
      case GhosttyRenderStateCursorVisualStyle
          .GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR:
      case GhosttyRenderStateCursorVisualStyle
          .GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK:
        if (shouldShowCursorFill) {
          canvas.drawRect(shapeRect, fillPaint);
        }
        canvas.drawRect(shapeRect, strokePaint);
    }
  }

  /// Extends the background color of the grid's edge cells into the padding
  /// gutters, mirroring Ghostty's `window-padding-color=extend`. Without this,
  /// the padding is a flat [backgroundColor] strip that mismatches any TUI
  /// whose own background differs from the chrome.
  ///
  /// Horizontal gutters (left/right) always extend, per row, using that row's
  /// first/last cell background. Vertical gutters (top/bottom) extend
  /// all-or-nothing per edge row, gated by [_rowNeverExtendBg] — a faithful
  /// port of Ghostty's `renderer/row.zig:neverExtendBg` (skip semantic
  /// prompts, powerline glyphs, and any row touching the default background,
  /// since those look bad stretched). Default-background cells resolve to a
  /// transparent background here, so "don't extend default bg" falls out of
  /// the `alpha > 0` checks for free.
  void _paintPaddingExtend(
    Canvas canvas, {
    required Size size,
    required double contentTop,
    required Color defaultForeground,
    required Color defaultBackground,
    required Color nativeDefaultForeground,
    required Color nativeDefaultBackground,
    required double linePixels,
    required List<GhosttyTerminalRenderRow> rowsData,
  }) {
    if (rowsData.isEmpty) {
      return;
    }
    final hasHorizontal = padding.left > 0 || padding.right > 0;
    final hasVertical = padding.top > 0 || padding.bottom > 0;
    if (!hasHorizontal && !hasVertical) {
      return;
    }

    final gridRight = size.width - padding.right;

    Color backgroundOf(GhosttyTerminalRenderCell cell) =>
        _resolveNativeStyleColors(
          style: cell.style,
          defaultForeground: defaultForeground,
          defaultBackground: defaultBackground,
          nativeDefaultForeground: nativeDefaultForeground,
          nativeDefaultBackground: nativeDefaultBackground,
          metadataColor: _resolveMetadataBackgroundColor(
            metadata: cell.metadata,
            fallback: cell.metadata.backgroundColor,
          ),
        ).background;

    // Horizontal gutters — per row, always extend the edge cell's bg.
    if (hasHorizontal) {
      for (var rowIndex = 0; rowIndex < rowsData.length; rowIndex++) {
        final cells = rowsData[rowIndex].cells;
        if (cells.isEmpty) {
          continue;
        }
        final band = _rowBand(
          contentTop: contentTop,
          rowIndex: rowIndex,
          linePixels: linePixels,
          devicePixelRatio: devicePixelRatio,
        );
        if (padding.left > 0) {
          final color = backgroundOf(cells.first);
          if (color.a > 0) {
            canvas.drawRect(
              Rect.fromLTRB(0, band.top, padding.left, band.bottom),
              Paint()..color = color,
            );
          }
        }
        if (padding.right > 0) {
          final color = backgroundOf(cells.last);
          if (color.a > 0) {
            canvas.drawRect(
              Rect.fromLTRB(gridRight, band.top, size.width, band.bottom),
              Paint()..color = color,
            );
          }
        }
      }
    }

    // Vertical gutters — all-or-nothing per edge row, plus the four corners.
    if (hasVertical) {
      if (padding.top > 0) {
        _paintVerticalPaddingEdge(
          canvas,
          row: rowsData.first,
          backgroundOf: backgroundOf,
          stripTop: contentTop - padding.top,
          stripBottom: contentTop,
          size: size,
          gridRight: gridRight,
        );
      }
      if (padding.bottom > 0) {
        final lastBand = _rowBand(
          contentTop: contentTop,
          rowIndex: rowsData.length - 1,
          linePixels: linePixels,
          devicePixelRatio: devicePixelRatio,
        );
        _paintVerticalPaddingEdge(
          canvas,
          row: rowsData.last,
          backgroundOf: backgroundOf,
          stripTop: lastBand.bottom,
          stripBottom: size.height,
          size: size,
          gridRight: gridRight,
        );
      }
    }
  }

  /// Fills one vertical padding strip ([stripTop]..[stripBottom], full width)
  /// from an edge [row], per column, then extends the first/last column color
  /// into the corner squares. No-op when the row fails [_rowNeverExtendBg].
  void _paintVerticalPaddingEdge(
    Canvas canvas, {
    required GhosttyTerminalRenderRow row,
    required Color Function(GhosttyTerminalRenderCell) backgroundOf,
    required double stripTop,
    required double stripBottom,
    required Size size,
    required double gridRight,
  }) {
    final cells = row.cells;
    if (cells.isEmpty || _rowNeverExtendBg(row, backgroundOf)) {
      return;
    }
    var col = 0;
    for (final cell in cells) {
      final color = backgroundOf(cell);
      if (color.a > 0) {
        final x = padding.left + (col * charWidth);
        canvas.drawRect(
          Rect.fromLTRB(x, stripTop, x + (cell.width * charWidth), stripBottom),
          Paint()..color = color,
        );
      }
      col += cell.width;
    }
    // Corners: bleed the first/last column color into the side gutters so the
    // colored vertical strip meets the colored horizontal strips cleanly.
    if (padding.left > 0) {
      final color = backgroundOf(cells.first);
      if (color.a > 0) {
        canvas.drawRect(
          Rect.fromLTRB(0, stripTop, padding.left, stripBottom),
          Paint()..color = color,
        );
      }
    }
    if (padding.right > 0) {
      final color = backgroundOf(cells.last);
      if (color.a > 0) {
        canvas.drawRect(
          Rect.fromLTRB(gridRight, stripTop, size.width, stripBottom),
          Paint()..color = color,
        );
      }
    }
  }

  /// Whether an edge [row]'s background must NOT be extended into the vertical
  /// padding. Port of Ghostty's `renderer/row.zig:neverExtendBg`: never extend
  /// a semantic prompt row, a row containing a powerline glyph, or a row that
  /// touches the default background (transparent here).
  bool _rowNeverExtendBg(
    GhosttyTerminalRenderRow row,
    Color Function(GhosttyTerminalRenderCell) backgroundOf,
  ) {
    if (row.hasSemanticPrompt) {
      return true;
    }
    for (final cell in row.cells) {
      if (_isPowerlineGlyph(cell.metadata.codepoint)) {
        return true;
      }
      if (backgroundOf(cell).a == 0) {
        return true;
      }
    }
    return false;
  }

  /// Powerline glyphs (Ghostty's `renderer/row.zig` ranges). These are
  /// perfect-fit dividers that look wrong when their background is stretched.
  bool _isPowerlineGlyph(int codepoint) =>
      (codepoint >= 0xE0B0 && codepoint <= 0xE0C8) ||
      codepoint == 0xE0CA ||
      (codepoint >= 0xE0CC && codepoint <= 0xE0D2) ||
      codepoint == 0xE0D4;

  List<_NativeRenderRun> _collectNativeRuns(
    List<GhosttyTerminalRenderCell> cells, {
    required Color defaultForeground,
    required Color defaultBackground,
    required Color nativeDefaultForeground,
    required Color nativeDefaultBackground,
  }) {
    if (cells.isEmpty) {
      return const <_NativeRenderRun>[];
    }
    final runs = <_NativeRenderRun>[];
    var runStart = 0;
    var runStartCol = 0;
    var runWidth = 0;
    final runText = StringBuffer();
    final runGraphemeCellWidths = <int>[];
    void flushCurrentRun() {
      final firstCell = cells[runStart];
      final firstStyleColors = _resolveNativeStyleColors(
        style: firstCell.style,
        defaultForeground: defaultForeground,
        defaultBackground: defaultBackground,
        nativeDefaultForeground: nativeDefaultForeground,
        nativeDefaultBackground: nativeDefaultBackground,
        metadataColor: _resolveMetadataBackgroundColor(
          metadata: firstCell.metadata,
          fallback: firstCell.metadata.backgroundColor,
        ),
      );
      final firstBackground = firstStyleColors.background;
      final text = runText.toString();
      runs.add(
        _NativeRenderRun(
          style: firstCell.style,
          background: firstBackground,
          metadata: firstCell.metadata,
          metadataBackground: firstCell.metadata.backgroundColor,
          startCol: runStartCol,
          width: runWidth,
          text: text,
          graphemeCellWidths: List<int>.unmodifiable(runGraphemeCellWidths),
          hasHyperlink: firstCell.hasHyperlink,
          hasRenderableText: text.isNotEmpty,
        ),
      );
      runStartCol += runWidth;
      runWidth = 0;
      runText.clear();
      runGraphemeCellWidths.clear();
    }

    for (var index = 0; index < cells.length; index++) {
      final currentCell = cells[index];
      final shouldStartNewRun =
          index > runStart &&
          !_nativeRenderRunCanMerge(
            cells[index - 1],
            currentCell,
            defaultForeground: defaultForeground,
            defaultBackground: defaultBackground,
            nativeDefaultForeground: nativeDefaultForeground,
            nativeDefaultBackground: nativeDefaultBackground,
          );
      if (shouldStartNewRun) {
        flushCurrentRun();
        runStart = index;
      }

      runWidth += currentCell.width;
      if (currentCell.text.isNotEmpty) {
        runText.write(currentCell.text);
        runGraphemeCellWidths.add(currentCell.width);
      }

      if (index == cells.length - 1) {
        flushCurrentRun();
        break;
      }
    }
    return runs;
  }

  bool _nativeRenderRunCanMerge(
    GhosttyTerminalRenderCell previous,
    GhosttyTerminalRenderCell next, {
    required Color defaultForeground,
    required Color defaultBackground,
    required Color nativeDefaultForeground,
    required Color nativeDefaultBackground,
  }) {
    final previousHasRenderableText = previous.text.isNotEmpty;
    final nextHasRenderableText = next.text.isNotEmpty;
    if (previousHasRenderableText != nextHasRenderableText) {
      return false;
    }

    return _nativeRenderStyleEquals(previous.style, next.style) &&
        _resolvedNativeBackground(
              metadataColor: _resolveMetadataBackgroundColor(
                metadata: previous.metadata,
                fallback: previous.metadata.backgroundColor,
              ),
              style: previous.style,
              defaultForeground: defaultForeground,
              defaultBackground: defaultBackground,
              nativeDefaultForeground: nativeDefaultForeground,
              nativeDefaultBackground: nativeDefaultBackground,
            ) ==
            _resolvedNativeBackground(
              metadataColor: _resolveMetadataBackgroundColor(
                metadata: next.metadata,
                fallback: next.metadata.backgroundColor,
              ),
              style: next.style,
              defaultForeground: defaultForeground,
              defaultBackground: defaultBackground,
              nativeDefaultForeground: nativeDefaultForeground,
              nativeDefaultBackground: nativeDefaultBackground,
            ) &&
        previous.hasHyperlink == next.hasHyperlink;
  }

  Color _resolveNativeForeground({
    required GhosttyTerminalResolvedStyle style,
    required Color defaultForeground,
    required Color defaultBackground,
    required Color nativeDefaultForeground,
    required Color nativeDefaultBackground,
    Color? metadataColor,
    required bool hasHyperlink,
  }) {
    final resolved = _resolveNativeStyleColors(
      style: style,
      defaultForeground: defaultForeground,
      defaultBackground: defaultBackground,
      nativeDefaultForeground: nativeDefaultForeground,
      nativeDefaultBackground: nativeDefaultBackground,
      metadataColor: metadataColor,
    );
    if (hasHyperlink && !style.hasExplicitForeground) {
      final ratio = minimumContrastRatio;
      if (ratio == null || style.invisible) {
        return hyperlinkColor;
      }
      // The hyperlink override replaces the already-floored resolved
      // foreground, so it needs its own floor against the same cell bg.
      return _flooredForeground(
        hyperlinkColor,
        resolved.background == Colors.transparent
            ? defaultBackground
            : resolved.background,
        ratio,
      );
    }
    return resolved.foreground;
  }

  ({Color foreground, Color background}) _resolveNativeStyleColors({
    required GhosttyTerminalResolvedStyle style,
    required Color defaultForeground,
    required Color defaultBackground,
    required Color nativeDefaultForeground,
    required Color nativeDefaultBackground,
    Color? metadataColor,
  }) {
    final resolved = GhosttyTerminalResolvedStyle.resolveNativeStyleColors(
      style: style,
      defaultForeground: defaultForeground,
      defaultBackground: defaultBackground,
      metadataColor: metadataColor,
    );
    final foreground =
        !style.hasExplicitForeground &&
            style.foreground == nativeDefaultForeground
        ? defaultForeground
        : resolved.foreground;
    final background =
        metadataColor == null &&
            !style.hasExplicitBackground &&
            style.background == nativeDefaultBackground
        ? Colors.transparent
        : resolved.background;
    final ratio = minimumContrastRatio;
    if (ratio == null || style.invisible) {
      // Invisible is deliberate fg == bg (SGR 8) — flooring it would reveal
      // hidden text. Faint/dim text is NOT exempt: dim must stay readable.
      return (foreground: foreground, background: background);
    }
    // Floor against the CELL's effective background, not the widget default —
    // TUIs paint their own backgrounds, and a fg readable on the widget bg can
    // be unreadable on the cell's. Transparent means "widget default bg".
    return (
      foreground: _flooredForeground(
        foreground,
        background == Colors.transparent ? defaultBackground : background,
        ratio,
      ),
      background: background,
    );
  }

  /// Memoized [ensureMinimumContrast]. Clear-when-full beats LRU here: the
  /// working set (distinct on-screen fg/bg pairs) sits far below the cap and
  /// recomputation is cheap, so eviction bookkeeping isn't worth carrying.
  Color _flooredForeground(Color foreground, Color background, double ratio) {
    final key = (foreground.toARGB32(), background.toARGB32());
    final cached = contrastFloorCache[key];
    if (cached != null) {
      return cached;
    }
    final floored = ensureMinimumContrast(foreground, background, ratio);
    if (contrastFloorCache.length >= _contrastFloorCacheMaxEntries) {
      contrastFloorCache.clear();
    }
    contrastFloorCache[key] = floored;
    return floored;
  }

  Color _resolvedNativeBackground({
    Color? metadataColor,
    required GhosttyTerminalResolvedStyle style,
    required Color defaultForeground,
    required Color defaultBackground,
    required Color nativeDefaultForeground,
    required Color nativeDefaultBackground,
  }) {
    return _resolveNativeStyleColors(
      style: style,
      defaultForeground: defaultForeground,
      defaultBackground: defaultBackground,
      nativeDefaultForeground: nativeDefaultForeground,
      nativeDefaultBackground: nativeDefaultBackground,
      metadataColor: metadataColor,
    ).background;
  }

  Color? _resolveMetadataBackgroundColor({
    required GhosttyTerminalRenderCellMetadata metadata,
    Color? fallback,
  }) {
    return metadata.backgroundColor ?? fallback;
  }

  bool _nativeRenderStyleEquals(
    GhosttyTerminalResolvedStyle a,
    GhosttyTerminalResolvedStyle b,
  ) {
    return a.foreground == b.foreground &&
        a.background == b.background &&
        a.underlineColor == b.underlineColor &&
        a.hasExplicitUnderlineColor == b.hasExplicitUnderlineColor &&
        a.hasExplicitForeground == b.hasExplicitForeground &&
        a.hasExplicitBackground == b.hasExplicitBackground &&
        a.bold == b.bold &&
        a.italic == b.italic &&
        a.inverse == b.inverse &&
        a.invisible == b.invisible &&
        a.faint == b.faint &&
        a.blink == b.blink &&
        a.overline == b.overline &&
        a.strikethrough == b.strikethrough &&
        a.underline == b.underline;
  }

  TextDecoration _nativeTextDecoration({
    required GhosttyTerminalResolvedStyle style,
    required bool hasHyperlink,
  }) {
    final decorations = <TextDecoration>[];
    if (style.underline != GhosttySgrUnderline.GHOSTTY_SGR_UNDERLINE_NONE) {
      decorations.add(TextDecoration.underline);
    }
    if (hasHyperlink &&
        (style.underline == GhosttySgrUnderline.GHOSTTY_SGR_UNDERLINE_NONE)) {
      decorations.add(TextDecoration.underline);
    }
    if (style.overline) {
      decorations.add(TextDecoration.overline);
    }
    if (style.strikethrough) {
      decorations.add(TextDecoration.lineThrough);
    }
    return decorations.isEmpty
        ? TextDecoration.none
        : TextDecoration.combine(decorations);
  }

  TextDecorationStyle _nativeDecorationStyle({
    required GhosttySgrUnderline underline,
    required bool hasHyperlink,
  }) {
    if (hasHyperlink &&
        underline == GhosttySgrUnderline.GHOSTTY_SGR_UNDERLINE_NONE) {
      return TextDecorationStyle.solid;
    }
    return switch (underline) {
      GhosttySgrUnderline.GHOSTTY_SGR_UNDERLINE_DOUBLE =>
        TextDecorationStyle.double,
      GhosttySgrUnderline.GHOSTTY_SGR_UNDERLINE_CURLY =>
        TextDecorationStyle.wavy,
      GhosttySgrUnderline.GHOSTTY_SGR_UNDERLINE_DOTTED =>
        TextDecorationStyle.dotted,
      GhosttySgrUnderline.GHOSTTY_SGR_UNDERLINE_DASHED =>
        TextDecorationStyle.dashed,
      _ => TextDecorationStyle.solid,
    };
  }

  void _paintNativeSelection(
    Canvas canvas, {
    required int row,
    required int cellCount,
    required double y,
    required double rowHeight,
  }) {
    final selection = this.selection;
    if (selection == null || cellCount <= 0) {
      return;
    }
    final normalized = selection.normalized;
    if (row < normalized.start.row || row > normalized.end.row) {
      return;
    }

    final startCol = row == normalized.start.row ? normalized.start.col : 0;
    final endCol = row == normalized.end.row
        ? normalized.end.col
        : cellCount - 1;
    if (endCol < startCol) {
      return;
    }
    final left = padding.left + (startCol * charWidth);
    final width = (endCol - startCol + 1) * charWidth;
    canvas.drawRect(
      Rect.fromLTWH(left, y, width, rowHeight),
      Paint()..color = selectionColor,
    );
  }

  bool _shouldPaintTerminalRunAsSingleRun({
    required String text,
    required double width,
    required FontWeight fontWeight,
    required FontStyle fontStyle,
  }) {
    if (text.isEmpty) {
      return false;
    }

    final measuredWidth = nativeRunIntrinsicWidthCache.resolve(
      _TerminalIntrinsicWidthKey(
        text: text,
        fontSize: fontSize,
        lineHeight: linePixels / fontSize,
        fontFamily: fontFamily,
        fontFamilyFallback: fontFamilyFallback,
        fontPackage: fontPackage,
        letterSpacing: letterSpacing,
        fontWeight: fontWeight,
        fontStyle: fontStyle,
      ),
    );

    return (measuredWidth - width).abs() <= 0.75;
  }

  bool _paintTerminalSpecialGlyph(
    Canvas canvas,
    String text, {
    required Rect rect,
    required Color color,
  }) {
    return _paintTerminalBoxDrawingGlyph(
          canvas,
          text,
          rect: rect,
          color: color,
        ) ||
        _paintTerminalBlockGlyph(canvas, text, rect: rect, color: color) ||
        _paintTerminalBrailleGlyph(canvas, text, rect: rect, color: color) ||
        _paintTerminalGeometricGlyph(canvas, text, rect: rect, color: color) ||
        _paintTerminalRaisedTextGlyph(canvas, text, rect: rect, color: color) ||
        _paintTerminalSymbolGlyph(canvas, text, rect: rect, color: color);
  }

  bool _paintTerminalBoxDrawingGlyph(
    Canvas canvas,
    String text, {
    required Rect rect,
    required Color color,
  }) {
    final rune = text.runes.length == 1 ? text.runes.first : null;
    if (rune == null) {
      return false;
    }

    final spec = _terminalBoxDrawingSpec(rune);
    if (spec == null) {
      return false;
    }

    final horizontalStroke = _boxDrawingStrokeWidth(
      rect,
      heavy: spec.heavyHorizontal,
      devicePixelRatio: devicePixelRatio,
    );
    final verticalStroke = _boxDrawingStrokeWidth(
      rect,
      heavy: spec.heavyVertical,
      devicePixelRatio: devicePixelRatio,
    );
    final centerX = _pixelSnapAxis(
      rect.left + (rect.width / 2),
      verticalStroke,
      devicePixelRatio: devicePixelRatio,
    );
    final centerY = _pixelSnapAxis(
      rect.top + _boxDrawingCenterYOffset(rect, spec),
      horizontalStroke,
      devicePixelRatio: devicePixelRatio,
    );
    final left = _snapLogicalToPhysical(rect.left, devicePixelRatio);
    final right = _snapLogicalToPhysical(rect.right, devicePixelRatio);
    final top = _snapLogicalToPhysical(rect.top, devicePixelRatio);
    final bottom = _snapLogicalToPhysical(rect.bottom, devicePixelRatio);

    final horizontalPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = horizontalStroke
      ..strokeCap = StrokeCap.butt
      ..strokeJoin = StrokeJoin.miter
      ..isAntiAlias = false;
    final verticalPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = verticalStroke
      ..strokeCap = StrokeCap.butt
      ..strokeJoin = StrokeJoin.miter
      ..isAntiAlias = false;

    if (spec.rounded && ((spec.left || spec.right) && (spec.up || spec.down))) {
      final radius = math.min(rect.width, rect.height) * 0.45;
      final path = Path();
      if (spec.right && spec.down) {
        path
          ..moveTo(right, centerY)
          ..lineTo(centerX + radius, centerY)
          ..quadraticBezierTo(centerX, centerY, centerX, centerY + radius)
          ..lineTo(centerX, bottom);
      } else if (spec.left && spec.down) {
        path
          ..moveTo(left, centerY)
          ..lineTo(centerX - radius, centerY)
          ..quadraticBezierTo(centerX, centerY, centerX, centerY + radius)
          ..lineTo(centerX, bottom);
      } else if (spec.right && spec.up) {
        path
          ..moveTo(right, centerY)
          ..lineTo(centerX + radius, centerY)
          ..quadraticBezierTo(centerX, centerY, centerX, centerY - radius)
          ..lineTo(centerX, top);
      } else if (spec.left && spec.up) {
        path
          ..moveTo(left, centerY)
          ..lineTo(centerX - radius, centerY)
          ..quadraticBezierTo(centerX, centerY, centerX, centerY - radius)
          ..lineTo(centerX, top);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(horizontalStroke, verticalStroke)
          ..strokeCap = StrokeCap.butt
          ..strokeJoin = StrokeJoin.round
          ..isAntiAlias = true,
      );
      return true;
    }

    if ((spec.left || spec.right) && !(spec.up || spec.down)) {
      canvas.drawLine(
        Offset(spec.left ? left : centerX, centerY),
        Offset(spec.right ? right : centerX, centerY),
        horizontalPaint,
      );
      return true;
    }

    if ((spec.up || spec.down) && !(spec.left || spec.right)) {
      canvas.drawLine(
        Offset(centerX, spec.up ? top : centerY),
        Offset(centerX, spec.down ? bottom : centerY),
        verticalPaint,
      );
      return true;
    }

    if ((spec.left || spec.right) && (spec.up || spec.down)) {
      if (spec.left && !spec.right && spec.down && !spec.up) {
        canvas.drawLine(
          Offset(left, centerY),
          Offset(centerX, centerY),
          horizontalPaint,
        );
        canvas.drawLine(
          Offset(centerX, centerY),
          Offset(centerX, bottom),
          verticalPaint,
        );
        return true;
      }
      if (spec.right && !spec.left && spec.down && !spec.up) {
        canvas.drawLine(
          Offset(right, centerY),
          Offset(centerX, centerY),
          horizontalPaint,
        );
        canvas.drawLine(
          Offset(centerX, centerY),
          Offset(centerX, bottom),
          verticalPaint,
        );
        return true;
      }
      if (spec.left && !spec.right && spec.up && !spec.down) {
        canvas.drawLine(
          Offset(left, centerY),
          Offset(centerX, centerY),
          horizontalPaint,
        );
        canvas.drawLine(
          Offset(centerX, centerY),
          Offset(centerX, top),
          verticalPaint,
        );
        return true;
      }
      if (spec.right && !spec.left && spec.up && !spec.down) {
        canvas.drawLine(
          Offset(right, centerY),
          Offset(centerX, centerY),
          horizontalPaint,
        );
        canvas.drawLine(
          Offset(centerX, centerY),
          Offset(centerX, top),
          verticalPaint,
        );
        return true;
      }
    }

    if (spec.left || spec.right) {
      canvas.drawLine(
        Offset(spec.left ? left : centerX, centerY),
        Offset(spec.right ? right : centerX, centerY),
        horizontalPaint,
      );
    }
    if (spec.up || spec.down) {
      canvas.drawLine(
        Offset(centerX, spec.up ? top : centerY),
        Offset(centerX, spec.down ? bottom : centerY),
        verticalPaint,
      );
    }

    return true;
  }

  bool _paintTerminalGeometricGlyph(
    Canvas canvas,
    String text, {
    required Rect rect,
    required Color color,
  }) {
    final rune = text.runes.length == 1 ? text.runes.first : null;
    if (rune == null) {
      return false;
    }

    final spec = _terminalGeometricGlyphSpec(rune);
    if (spec == null) {
      return false;
    }

    final diameter = math.min(rect.width, rect.height) * spec.diameterScale;
    final glyphRect = Rect.fromCenter(
      center: Offset(
        rect.left + (rect.width / 2),
        rect.top + (rect.height / 2),
      ),
      width: diameter,
      height: diameter,
    );
    final paint = Paint()
      ..color = color
      ..style = spec.filled ? PaintingStyle.fill : PaintingStyle.stroke
      ..strokeWidth = spec.filled
          ? 0
          : math.max(1.0, diameter * spec.strokeScale)
      ..isAntiAlias = true;
    canvas.drawOval(glyphRect, paint);
    return true;
  }

  bool _paintTerminalRaisedTextGlyph(
    Canvas canvas,
    String text, {
    required Rect rect,
    required Color color,
  }) {
    final rune = text.runes.length == 1 ? text.runes.first : null;
    if (rune == null) {
      return false;
    }

    final spec = _terminalRaisedTextGlyphSpec(rune);
    if (spec == null) {
      return false;
    }

    final painter = TextPainter(
      text: TextSpan(
        text: spec.text,
        style: TextStyle(
          color: color,
          fontFamily: fontFamily,
          fontFamilyFallback: fontFamilyFallback,
          package: fontPackage,
          fontSize: fontSize * spec.fontScale,
          height: 1,
          letterSpacing: letterSpacing,
          fontWeight: FontWeight.w500,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();

    final dx = rect.left + _centeredGlyphOffset(rect.width, painter.width);
    final dy =
        rect.top +
        (rect.height * spec.topOffsetScale) +
        _centeredGlyphOffset(
          rect.height * spec.verticalSpaceScale,
          painter.height,
        );
    painter.paint(canvas, Offset(dx, dy));
    return true;
  }

  bool _paintTerminalSymbolGlyph(
    Canvas canvas,
    String text, {
    required Rect rect,
    required Color color,
  }) {
    final rune = text.runes.length == 1 ? text.runes.first : null;
    if (rune == null) {
      return false;
    }

    final spec = _terminalSymbolGlyphSpec(rune);
    if (spec == null) {
      return false;
    }

    final left = _snapLogicalToPhysical(rect.left, devicePixelRatio);
    final right = _snapLogicalToPhysical(rect.right, devicePixelRatio);
    final top = _snapLogicalToPhysical(rect.top, devicePixelRatio);
    final bottom = _snapLogicalToPhysical(rect.bottom, devicePixelRatio);
    final width = right - left;
    final height = bottom - top;
    final strokeWidth = math.max(
      1.0 / math.max(devicePixelRatio, 1.0),
      math.min(width, height) * spec.strokeScale,
    );
    final centerX = _pixelSnapAxis(
      rect.left + (rect.width / 2),
      strokeWidth,
      devicePixelRatio: devicePixelRatio,
    );
    final centerY = _pixelSnapAxis(
      rect.top + (rect.height / 2),
      strokeWidth,
      devicePixelRatio: devicePixelRatio,
    );
    final paint = Paint()
      ..color = color
      ..style = spec.filled ? PaintingStyle.fill : PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    switch (spec.kind) {
      case _TerminalSymbolGlyphKind.downTriangle:
        final path = Path()
          ..moveTo(centerX, top + (height * 0.8))
          ..lineTo(left + (width * 0.22), top + (height * 0.28))
          ..lineTo(right - (width * 0.22), top + (height * 0.28))
          ..close();
        canvas.drawPath(path, paint);
        return true;
      case _TerminalSymbolGlyphKind.upTriangle:
        final path = Path()
          ..moveTo(centerX, top + (height * 0.2))
          ..lineTo(left + (width * 0.22), bottom - (height * 0.28))
          ..lineTo(right - (width * 0.22), bottom - (height * 0.28))
          ..close();
        canvas.drawPath(path, paint);
        return true;
      case _TerminalSymbolGlyphKind.leftTriangle:
        final path = Path()
          ..moveTo(left + (width * 0.2), centerY)
          ..lineTo(right - (width * 0.28), top + (height * 0.22))
          ..lineTo(right - (width * 0.28), bottom - (height * 0.22))
          ..close();
        canvas.drawPath(path, paint);
        return true;
      case _TerminalSymbolGlyphKind.rightTriangle:
        final path = Path()
          ..moveTo(right - (width * 0.2), centerY)
          ..lineTo(left + (width * 0.28), top + (height * 0.22))
          ..lineTo(left + (width * 0.28), bottom - (height * 0.22))
          ..close();
        canvas.drawPath(path, paint);
        return true;
      case _TerminalSymbolGlyphKind.square:
        final insetX = width * 0.2;
        final insetY = height * 0.2;
        canvas.drawRect(
          Rect.fromLTRB(
            left + insetX,
            top + insetY,
            right - insetX,
            bottom - insetY,
          ),
          paint,
        );
        return true;
      case _TerminalSymbolGlyphKind.rightArrow:
        final startX = left + (width * 0.18);
        final endX = right - (width * 0.22);
        final arrowTopY = centerY - (height * 0.18);
        final arrowBottomY = centerY + (height * 0.18);
        canvas.drawLine(Offset(startX, centerY), Offset(endX, centerY), paint);
        canvas.drawLine(
          Offset(endX - (width * 0.18), arrowTopY),
          Offset(endX, centerY),
          paint,
        );
        canvas.drawLine(
          Offset(endX - (width * 0.18), arrowBottomY),
          Offset(endX, centerY),
          paint,
        );
        return true;
      case _TerminalSymbolGlyphKind.leftArrow:
        final startX = right - (width * 0.18);
        final endX = left + (width * 0.22);
        final arrowTopY = centerY - (height * 0.18);
        final arrowBottomY = centerY + (height * 0.18);
        canvas.drawLine(Offset(startX, centerY), Offset(endX, centerY), paint);
        canvas.drawLine(
          Offset(endX + (width * 0.18), arrowTopY),
          Offset(endX, centerY),
          paint,
        );
        canvas.drawLine(
          Offset(endX + (width * 0.18), arrowBottomY),
          Offset(endX, centerY),
          paint,
        );
        return true;
      case _TerminalSymbolGlyphKind.upArrow:
        final startY = bottom - (height * 0.18);
        final endY = top + (height * 0.22);
        final arrowLeftX = centerX - (width * 0.18);
        final arrowRightX = centerX + (width * 0.18);
        canvas.drawLine(Offset(centerX, startY), Offset(centerX, endY), paint);
        canvas.drawLine(
          Offset(arrowLeftX, endY + (height * 0.18)),
          Offset(centerX, endY),
          paint,
        );
        canvas.drawLine(
          Offset(arrowRightX, endY + (height * 0.18)),
          Offset(centerX, endY),
          paint,
        );
        return true;
      case _TerminalSymbolGlyphKind.downArrow:
        final startY = top + (height * 0.18);
        final endY = bottom - (height * 0.22);
        final arrowLeftX = centerX - (width * 0.18);
        final arrowRightX = centerX + (width * 0.18);
        canvas.drawLine(Offset(centerX, startY), Offset(centerX, endY), paint);
        canvas.drawLine(
          Offset(arrowLeftX, endY - (height * 0.18)),
          Offset(centerX, endY),
          paint,
        );
        canvas.drawLine(
          Offset(arrowRightX, endY - (height * 0.18)),
          Offset(centerX, endY),
          paint,
        );
        return true;
      case _TerminalSymbolGlyphKind.checkmark:
        final path = Path()
          ..moveTo(left + (width * 0.18), top + (height * 0.56))
          ..lineTo(left + (width * 0.42), top + (height * 0.78))
          ..lineTo(right - (width * 0.16), top + (height * 0.24));
        canvas.drawPath(path, paint);
        return true;
      case _TerminalSymbolGlyphKind.enterArrow:
        final midX = right - (width * 0.26);
        final hookY = centerY + (height * 0.18);
        canvas.drawLine(
          Offset(left + (width * 0.16), centerY),
          Offset(midX, centerY),
          paint,
        );
        canvas.drawLine(
          Offset(midX, top + (height * 0.22)),
          Offset(midX, hookY),
          paint,
        );
        canvas.drawLine(
          Offset(midX, hookY),
          Offset(midX - (width * 0.18), hookY - (height * 0.16)),
          paint,
        );
        canvas.drawLine(
          Offset(midX, hookY),
          Offset(midX - (width * 0.18), hookY + (height * 0.16)),
          paint,
        );
        return true;
      case _TerminalSymbolGlyphKind.emDash:
        canvas.drawLine(
          Offset(left + (width * 0.12), centerY),
          Offset(right - (width * 0.12), centerY),
          paint,
        );
        return true;
      case _TerminalSymbolGlyphKind.heavyRightArrow:
        // Heavy round-tipped rightwards arrow (➜ U+279C).
        // Drawn as a solid filled chevron: a left-indented pentagon centred
        // vertically in the cell — no stem, just the broad arrowhead.
        final path = Path()
          ..moveTo(right - (width * 0.18), centerY) // rightmost tip
          ..lineTo(left + (width * 0.28), top + (height * 0.18)) // top-left
          ..lineTo(left + (width * 0.48), centerY) // centre indent
          ..lineTo(
            left + (width * 0.28),
            bottom - (height * 0.18),
          ) // bottom-left
          ..close();
        canvas.drawPath(path, paint);
        return true;
    }
  }

  bool _paintTerminalBrailleGlyph(
    Canvas canvas,
    String text, {
    required Rect rect,
    required Color color,
  }) {
    final rune = text.runes.length == 1 ? text.runes.first : null;
    if (rune == null || rune < 0x2800 || rune > 0x28FF) {
      return false;
    }

    final dots = rune - 0x2800;
    if (dots == 0) {
      return true;
    }

    final left = rect.left;
    final top = rect.top;
    final width = rect.width;
    final height = rect.height;
    final dotRadius = math.max(
      0.8 / math.max(devicePixelRatio, 1.0),
      math.min(width * 0.12, height * 0.09),
    );
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    final xPositions = <double>[left + (width * 0.32), left + (width * 0.68)];
    final yPositions = <double>[
      top + (height * 0.16),
      top + (height * 0.38),
      top + (height * 0.60),
      top + (height * 0.82),
    ];
    const bitToDot = <({int bit, int col, int row})>[
      (bit: 0x01, col: 0, row: 0),
      (bit: 0x02, col: 0, row: 1),
      (bit: 0x04, col: 0, row: 2),
      (bit: 0x08, col: 1, row: 0),
      (bit: 0x10, col: 1, row: 1),
      (bit: 0x20, col: 1, row: 2),
      (bit: 0x40, col: 0, row: 3),
      (bit: 0x80, col: 1, row: 3),
    ];

    for (final dot in bitToDot) {
      if ((dots & dot.bit) == 0) {
        continue;
      }
      canvas.drawCircle(
        Offset(xPositions[dot.col], yPositions[dot.row]),
        dotRadius,
        paint,
      );
    }
    return true;
  }

  bool _paintTerminalBlockGlyph(
    Canvas canvas,
    String text, {
    required Rect rect,
    required Color color,
  }) {
    final rune = text.runes.length == 1 ? text.runes.first : null;
    if (rune == null) {
      return false;
    }

    final spec = _terminalBlockGlyphSpec(rune);
    if (spec == null) {
      return false;
    }

    final left = _snapLogicalToPhysical(rect.left, devicePixelRatio);
    final right = _snapLogicalToPhysical(rect.right, devicePixelRatio);
    final top = _snapLogicalToPhysical(rect.top, devicePixelRatio);
    final bottom = _snapLogicalToPhysical(rect.bottom, devicePixelRatio);
    final width = right - left;
    final height = bottom - top;

    final shadeAlpha = spec.shadeAlpha;
    final paint = Paint()
      ..color = shadeAlpha == null
          ? color
          : color.withValues(alpha: color.a * shadeAlpha)
      ..style = PaintingStyle.fill
      ..isAntiAlias = false;

    // Fill every sub-cell rect of the glyph, snapping each edge to a physical
    // pixel. Snapping shared fractional edges (e.g. the 0.5 cell midline used by
    // half-blocks and quadrants) means they land on the same pixel in this cell
    // and its neighbours, so the glyphs tile seamlessly — ghostty's model of
    // rounding fractions of the integer cell.
    for (final r in spec.rects) {
      canvas.drawRect(
        Rect.fromLTRB(
          _snapLogicalToPhysical(left + (width * r.left), devicePixelRatio),
          _snapLogicalToPhysical(top + (height * r.top), devicePixelRatio),
          _snapLogicalToPhysical(left + (width * r.right), devicePixelRatio),
          _snapLogicalToPhysical(top + (height * r.bottom), devicePixelRatio),
        ),
        paint,
      );
    }
    return true;
  }
}

double _centeredGlyphOffset(double availableExtent, double glyphExtent) {
  if (availableExtent <= glyphExtent) {
    return 0;
  }
  return (availableExtent - glyphExtent) / 2;
}

final Set<int> _loggedUnsupportedTerminalRunes = <int>{};

void _debugLogUnsupportedGlyph(String text) {
  assert(() {
    final runes = text.runes.toList(growable: false);
    if (runes.isEmpty) {
      return true;
    }
    if (runes.length == 1) {
      final rune = runes.first;
      if (rune <= 0x7E ||
          _terminalBoxDrawingSpec(rune) != null ||
          _terminalBlockGlyphSpec(rune) != null ||
          _terminalGeometricGlyphSpec(rune) != null ||
          _terminalRaisedTextGlyphSpec(rune) != null ||
          _terminalSymbolGlyphSpec(rune) != null ||
          (rune >= 0x2800 && rune <= 0x28FF)) {
        return true;
      }
      if (_loggedUnsupportedTerminalRunes.add(rune)) {
        debugPrint(
          'GhosttyTerminalView unsupported glyph fallback: '
          '"$text" U+${rune.toRadixString(16).toUpperCase().padLeft(4, '0')}',
        );
      }
      return true;
    }

    for (final rune in runes) {
      if (rune <= 0x7E) {
        continue;
      }
      if (_loggedUnsupportedTerminalRunes.add(rune)) {
        debugPrint(
          'GhosttyTerminalView unsupported grapheme fallback: '
          '"$text" contains U+${rune.toRadixString(16).toUpperCase().padLeft(4, '0')}',
        );
      }
    }
    return true;
  }());
}

_TerminalRowBand _rowBand({
  required double contentTop,
  required int rowIndex,
  required double linePixels,
  required double devicePixelRatio,
}) {
  final top = _snapLogicalToPhysical(
    contentTop + (rowIndex * linePixels),
    devicePixelRatio,
  );
  final bottom = _snapLogicalToPhysical(
    contentTop + ((rowIndex + 1) * linePixels),
    devicePixelRatio,
  );
  final minHeight = devicePixelRatio <= 0 ? 1.0 : (1 / devicePixelRatio);
  return _TerminalRowBand(top: top, bottom: math.max(top + minHeight, bottom));
}

double _snapLogicalToPhysical(double value, double devicePixelRatio) {
  if (devicePixelRatio <= 0) {
    return value;
  }
  return (value * devicePixelRatio).roundToDouble() / devicePixelRatio;
}

double _snapLogicalExtentToPhysical(double value, double devicePixelRatio) {
  if (devicePixelRatio <= 0) {
    return value;
  }
  return math.max(
    1 / devicePixelRatio,
    (value * devicePixelRatio).roundToDouble() / devicePixelRatio,
  );
}

double _boxDrawingStrokeWidth(
  Rect rect, {
  required bool heavy,
  required double devicePixelRatio,
}) {
  final onePhysicalPixel = devicePixelRatio <= 0 ? 1.0 : 1.0 / devicePixelRatio;
  if (!heavy) {
    return onePhysicalPixel;
  }

  final heavyStroke = rect.width * 0.2;
  return math.max(onePhysicalPixel, heavyStroke);
}

double _pixelSnapAxis(
  double center,
  double strokeWidth, {
  required double devicePixelRatio,
}) {
  if (devicePixelRatio <= 0) {
    final rounded = center.roundToDouble();
    if (strokeWidth <= 1.0) {
      return rounded + 0.5;
    }
    return rounded;
  }

  final physicalCenter = center * devicePixelRatio;
  final onePhysicalPixel = 1.0 / devicePixelRatio;
  if (strokeWidth <= onePhysicalPixel) {
    return ((physicalCenter - 0.5).roundToDouble() + 0.5) / devicePixelRatio;
  }
  return physicalCenter.roundToDouble() / devicePixelRatio;
}

double _boxDrawingCenterYOffset(Rect rect, _TerminalBoxDrawingSpec spec) {
  final opticalOffset = spec.up && !spec.down
      ? -0.5
      : spec.down && !spec.up
      ? 0.5
      : 0.0;
  return (rect.height / 2) + opticalOffset;
}

bool _renderSnapshotEquals(
  GhosttyTerminalRenderSnapshot? a,
  GhosttyTerminalRenderSnapshot? b,
) {
  if (identical(a, b)) {
    return true;
  }
  if (a == null || b == null) {
    return false;
  }
  return a.cols == b.cols &&
      a.rows == b.rows &&
      a.backgroundColor == b.backgroundColor &&
      a.foregroundColor == b.foregroundColor &&
      a.cursor == b.cursor &&
      listEquals(a.rowsData, b.rowsData);
}

String _widgetModeLabel(
  GhosttyTerminalRendererMode mode,
  GhosttyTerminalRenderSnapshot? renderSnapshot,
) {
  if (renderSnapshot == null || !renderSnapshot.hasViewportData) {
    return 'renderState (no data)';
  }
  return 'renderState';
}

class _TerminalMetrics {
  const _TerminalMetrics({
    required this.charWidth,
    required this.linePixels,
    required this.letterSpacing,
  });

  final double charWidth;
  final double linePixels;

  /// Letter spacing to apply to painted text so a run of N characters advances
  /// exactly `N * charWidth`, even though [charWidth] is snapped to a whole
  /// physical pixel and the font's natural monospace advance is fractional.
  /// Without this, text would drift off the integer cell grid.
  final double letterSpacing;
}

// `visualRow` selects a single on-screen row; `line` walks the wrap chain to
// cover the whole logical line. Touch long-press uses `visualRow` so a full-width
// TUI row isn't expanded across the entire screen (see _beginLineSelection's
// `granularity` param).
enum _TerminalSelectionGranularity { cell, word, line, visualRow }

// A touch gesture forwards to either scrollback (`scroll`) or, when a running
// program has mouse reporting on, to the TUI as wheel/click (`mouseForward`).
// The two are mutually exclusive for a given gesture — mouse reporting decides
// which — so one active-gesture object with a role field serves both.
enum _TouchGestureRole { scroll, mouseForward }

// Gesture-arena outcome for a touch drag. Starts `unresolved`; the in-arena
// vertical claimer (see `_buildPointerGestureLayer`) marks it `won` when this is
// a dominantly-vertical drag, or `lost` when an ancestor horizontal pager claims
// the touch. Scroll/wheel forwarding waits for `won`, so a diagonal swipe never
// both scrolls the terminal and flips the page — and nothing leaks before the
// axis is decided. In `selection` drag-behavior no claimer is installed, so
// there's nothing to wait for and gestures begin `won` (see
// `_initialArenaOutcome`).
enum _TouchArenaOutcome { unresolved, won, lost }

// Per-gesture touch state. One finger at a time: a second finger is ignored
// while this is non-null, so its down/up can't corrupt the tracked finger's
// arena outcome, tap-pending flag, or scroll/wheel remainder (the single global
// bools this replaces did leak across fingers).
class _TouchGesture {
  _TouchGesture({
    required this.pointer,
    required this.role,
    required this.start,
    required this.arenaOutcome,
    this.tapPending = false,
  }) : lastPosition = start;

  final int pointer;
  final _TouchGestureRole role;
  final Offset start;
  _TouchArenaOutcome arenaOutcome;
  Offset lastPosition;
  double scrollRemainder = 0;
  double wheelRemainder = 0;
  // Mouse-forward only: the button PRESS is deferred to pointer-up so a swipe
  // becomes wheel scroll instead of a click-drag. Cleared once the finger
  // travels past `kTouchSlop` (a swipe, not a tap).
  bool tapPending;
}

class _TerminalViewport {
  const _TerminalViewport({
    required this.startLine,
    required this.contentTop,
    required this.contentHeight,
    required this.maxVisible,
  });

  final int startLine;
  final double contentTop;
  final double contentHeight;
  final int maxVisible;
}

final class _TerminalRowBand {
  const _TerminalRowBand({required this.top, required this.bottom});

  final double top;
  final double bottom;

  double get height => bottom - top;
}

final class _NativeRenderRun {
  const _NativeRenderRun({
    required this.style,
    required this.background,
    required this.metadata,
    required this.metadataBackground,
    required this.startCol,
    required this.width,
    required this.text,
    required this.graphemeCellWidths,
    required this.hasRenderableText,
    required this.hasHyperlink,
  });

  final GhosttyTerminalResolvedStyle style;
  final Color background;
  final GhosttyTerminalRenderCellMetadata metadata;
  final Color? metadataBackground;
  final int startCol;
  final int width;
  final String text;
  final List<int> graphemeCellWidths;
  final bool hasRenderableText;
  final bool hasHyperlink;
}

final class _TerminalTextPainterKey {
  const _TerminalTextPainterKey({
    required this.text,
    required this.width,
    required this.fontSize,
    required this.lineHeight,
    required this.fontFamily,
    required this.fontFamilyFallback,
    required this.fontPackage,
    required this.letterSpacing,
    required this.color,
    required this.fontWeight,
    required this.fontStyle,
    required this.decoration,
    required this.decorationStyle,
    required this.decorationColor,
  });

  final String text;
  final double width;
  final double fontSize;
  final double lineHeight;
  final String fontFamily;
  final List<String>? fontFamilyFallback;
  final String? fontPackage;
  final double letterSpacing;
  final Color color;
  final FontWeight fontWeight;
  final FontStyle fontStyle;
  final TextDecoration decoration;
  final TextDecorationStyle decorationStyle;
  final Color decorationColor;

  @override
  bool operator ==(Object other) {
    return other is _TerminalTextPainterKey &&
        text == other.text &&
        width == other.width &&
        fontSize == other.fontSize &&
        lineHeight == other.lineHeight &&
        fontFamily == other.fontFamily &&
        listEquals(fontFamilyFallback, other.fontFamilyFallback) &&
        fontPackage == other.fontPackage &&
        letterSpacing == other.letterSpacing &&
        color == other.color &&
        fontWeight == other.fontWeight &&
        fontStyle == other.fontStyle &&
        decoration == other.decoration &&
        decorationStyle == other.decorationStyle &&
        decorationColor == other.decorationColor;
  }

  @override
  int get hashCode => Object.hash(
    text,
    width,
    fontSize,
    lineHeight,
    fontFamily,
    Object.hashAll(fontFamilyFallback ?? const <String>[]),
    fontPackage,
    letterSpacing,
    color,
    fontWeight,
    fontStyle,
    decoration,
    decorationStyle,
    decorationColor,
  );
}

final class _TerminalTextPainterCache {
  _TerminalTextPainterCache({required this.maxEntries});

  final int maxEntries;
  final Map<_TerminalTextPainterKey, TextPainter> _painters =
      <_TerminalTextPainterKey, TextPainter>{};

  TextPainter resolve(_TerminalTextPainterKey key) {
    final cached = _painters.remove(key);
    if (cached != null) {
      _painters[key] = cached;
      return cached;
    }

    final painter = TextPainter(
      text: TextSpan(
        text: key.text,
        style: TextStyle(
          color: key.color,
          fontFamily: key.fontFamily,
          fontFamilyFallback: key.fontFamilyFallback,
          package: key.fontPackage,
          fontSize: key.fontSize,
          height: key.lineHeight,
          letterSpacing: key.letterSpacing,
          fontWeight: key.fontWeight,
          fontStyle: key.fontStyle,
          decoration: key.decoration,
          decorationStyle: key.decorationStyle,
          decorationColor: key.decorationColor,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: key.width);

    _painters[key] = painter;
    if (_painters.length > maxEntries) {
      _painters.remove(_painters.keys.first);
    }
    return painter;
  }
}

final class _TerminalIntrinsicWidthKey {
  const _TerminalIntrinsicWidthKey({
    required this.text,
    required this.fontSize,
    required this.lineHeight,
    required this.fontFamily,
    required this.fontFamilyFallback,
    required this.fontPackage,
    required this.letterSpacing,
    required this.fontWeight,
    required this.fontStyle,
  });

  final String text;
  final double fontSize;
  final double lineHeight;
  final String fontFamily;
  final List<String>? fontFamilyFallback;
  final String? fontPackage;
  final double letterSpacing;
  final FontWeight fontWeight;
  final FontStyle fontStyle;

  @override
  bool operator ==(Object other) {
    return other is _TerminalIntrinsicWidthKey &&
        text == other.text &&
        fontSize == other.fontSize &&
        lineHeight == other.lineHeight &&
        fontFamily == other.fontFamily &&
        listEquals(fontFamilyFallback, other.fontFamilyFallback) &&
        fontPackage == other.fontPackage &&
        letterSpacing == other.letterSpacing &&
        fontWeight == other.fontWeight &&
        fontStyle == other.fontStyle;
  }

  @override
  int get hashCode => Object.hash(
    text,
    fontSize,
    lineHeight,
    fontFamily,
    Object.hashAll(fontFamilyFallback ?? const <String>[]),
    fontPackage,
    letterSpacing,
    fontWeight,
    fontStyle,
  );
}

final class _TerminalTextIntrinsicWidthCache {
  _TerminalTextIntrinsicWidthCache({required this.maxEntries});

  final int maxEntries;
  final Map<_TerminalIntrinsicWidthKey, double> _widths =
      <_TerminalIntrinsicWidthKey, double>{};

  double resolve(_TerminalIntrinsicWidthKey key) {
    final cached = _widths.remove(key);
    if (cached != null) {
      _widths[key] = cached;
      return cached;
    }

    final painter = TextPainter(
      text: TextSpan(
        text: key.text,
        style: TextStyle(
          fontFamily: key.fontFamily,
          fontFamilyFallback: key.fontFamilyFallback,
          package: key.fontPackage,
          fontSize: key.fontSize,
          height: key.lineHeight,
          letterSpacing: key.letterSpacing,
          fontWeight: key.fontWeight,
          fontStyle: key.fontStyle,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();

    final width = painter.width;
    _widths[key] = width;
    if (_widths.length > maxEntries) {
      _widths.remove(_widths.keys.first);
    }
    return width;
  }
}

bool _containsBoxDrawingCharacters(String text) {
  for (final rune in text.runes) {
    if (_terminalBoxDrawingSpec(rune) != null) {
      return true;
    }
  }
  return false;
}

bool _isSafeSingleRunText(String text) {
  if (text.isEmpty || _containsBoxDrawingCharacters(text)) {
    return false;
  }

  for (final rune in text.runes) {
    if (rune < 0x20 || rune > 0x7E) {
      return false;
    }
  }
  return true;
}

_TerminalBoxDrawingSpec? _terminalBoxDrawingSpec(int rune) => switch (rune) {
  0x2574 => const _TerminalBoxDrawingSpec(left: true),
  0x2575 => const _TerminalBoxDrawingSpec(up: true),
  0x2576 => const _TerminalBoxDrawingSpec(right: true),
  0x2577 => const _TerminalBoxDrawingSpec(down: true),
  0x2578 => const _TerminalBoxDrawingSpec(left: true, heavyHorizontal: true),
  0x2579 => const _TerminalBoxDrawingSpec(up: true, heavyVertical: true),
  0x257A => const _TerminalBoxDrawingSpec(right: true, heavyHorizontal: true),
  0x257B => const _TerminalBoxDrawingSpec(down: true, heavyVertical: true),
  0x256D => const _TerminalBoxDrawingSpec(
    right: true,
    down: true,
    rounded: true,
  ),
  0x256E => const _TerminalBoxDrawingSpec(
    left: true,
    down: true,
    rounded: true,
  ),
  0x2570 => const _TerminalBoxDrawingSpec(right: true, up: true, rounded: true),
  0x256F => const _TerminalBoxDrawingSpec(left: true, up: true, rounded: true),
  0x2500 ||
  0x2504 ||
  0x2508 ||
  0x2509 => const _TerminalBoxDrawingSpec(left: true, right: true),
  0x2501 || 0x2505 => const _TerminalBoxDrawingSpec(
    left: true,
    right: true,
    heavyHorizontal: true,
  ),
  0x2502 ||
  0x2506 ||
  0x250A ||
  0x250B => const _TerminalBoxDrawingSpec(up: true, down: true),
  0x2503 || 0x2507 => const _TerminalBoxDrawingSpec(
    up: true,
    down: true,
    heavyVertical: true,
  ),
  0x250C ||
  0x250D ||
  0x250E ||
  0x250F => const _TerminalBoxDrawingSpec(right: true, down: true),
  0x2510 ||
  0x2511 ||
  0x2512 ||
  0x2513 => const _TerminalBoxDrawingSpec(left: true, down: true),
  0x2514 ||
  0x2515 ||
  0x2516 ||
  0x2517 => const _TerminalBoxDrawingSpec(right: true, up: true),
  0x2518 ||
  0x2519 ||
  0x251A ||
  0x251B => const _TerminalBoxDrawingSpec(left: true, up: true),
  0x251C ||
  0x251D ||
  0x251E ||
  0x251F ||
  0x2520 ||
  0x2521 ||
  0x2522 ||
  0x2523 => const _TerminalBoxDrawingSpec(up: true, down: true, right: true),
  0x2524 ||
  0x2525 ||
  0x2526 ||
  0x2527 ||
  0x2528 ||
  0x2529 ||
  0x252A ||
  0x252B => const _TerminalBoxDrawingSpec(up: true, down: true, left: true),
  0x252C ||
  0x252D ||
  0x252E ||
  0x252F ||
  0x2530 ||
  0x2531 ||
  0x2532 ||
  0x2533 => const _TerminalBoxDrawingSpec(left: true, right: true, down: true),
  0x2534 ||
  0x2535 ||
  0x2536 ||
  0x2537 ||
  0x2538 ||
  0x2539 ||
  0x253A ||
  0x253B => const _TerminalBoxDrawingSpec(left: true, right: true, up: true),
  0x253C ||
  0x253D ||
  0x253E ||
  0x253F ||
  0x2540 ||
  0x2541 ||
  0x2542 ||
  0x2543 ||
  0x2544 ||
  0x2545 ||
  0x2546 ||
  0x2547 ||
  0x2548 ||
  0x2549 ||
  0x254A ||
  0x254B => const _TerminalBoxDrawingSpec(
    up: true,
    down: true,
    left: true,
    right: true,
  ),
  _ => null,
};

final class _TerminalBoxDrawingSpec {
  const _TerminalBoxDrawingSpec({
    this.up = false,
    this.down = false,
    this.left = false,
    this.right = false,
    this.heavyHorizontal = false,
    this.heavyVertical = false,
    this.rounded = false,
  });

  final bool up;
  final bool down;
  final bool left;
  final bool right;
  final bool heavyHorizontal;
  final bool heavyVertical;
  final bool rounded;
}

_TerminalGeometricGlyphSpec? _terminalGeometricGlyphSpec(int rune) =>
    switch (rune) {
      0x00B0 => const _TerminalGeometricGlyphSpec(
        diameterScale: 0.42,
        strokeScale: 0.12,
      ),
      0x25CB || 0x25EF => const _TerminalGeometricGlyphSpec(
        diameterScale: 0.88,
        strokeScale: 0.12,
      ),
      0x25E6 => const _TerminalGeometricGlyphSpec(
        diameterScale: 0.4,
        strokeScale: 0.14,
      ),
      0x25CF || 0x25C9 => const _TerminalGeometricGlyphSpec(
        filled: true,
        diameterScale: 0.58,
      ),
      _ => null,
    };

final class _TerminalGeometricGlyphSpec {
  const _TerminalGeometricGlyphSpec({
    this.filled = false,
    required this.diameterScale,
    this.strokeScale = 0.14,
  });

  final bool filled;
  final double diameterScale;
  final double strokeScale;
}

_TerminalRaisedTextGlyphSpec? _terminalRaisedTextGlyphSpec(int rune) =>
    switch (rune) {
      0x2070 => const _TerminalRaisedTextGlyphSpec(text: '0'),
      0x00B9 => const _TerminalRaisedTextGlyphSpec(text: '1'),
      0x00B2 => const _TerminalRaisedTextGlyphSpec(text: '2'),
      0x00B3 => const _TerminalRaisedTextGlyphSpec(text: '3'),
      0x2075 => const _TerminalRaisedTextGlyphSpec(text: '5'),
      0x2076 => const _TerminalRaisedTextGlyphSpec(text: '6'),
      0x2077 => const _TerminalRaisedTextGlyphSpec(text: '7'),
      0x2078 => const _TerminalRaisedTextGlyphSpec(text: '8'),
      0x2079 => const _TerminalRaisedTextGlyphSpec(text: '9'),
      0x207A => const _TerminalRaisedTextGlyphSpec(text: '+'),
      0x207B => const _TerminalRaisedTextGlyphSpec(text: '-'),
      0x2074 => const _TerminalRaisedTextGlyphSpec(text: '4'),
      _ => null,
    };

final class _TerminalRaisedTextGlyphSpec {
  const _TerminalRaisedTextGlyphSpec({required this.text});

  final String text;
  final double fontScale = 0.7;
  final double topOffsetScale = 0.02;
  final double verticalSpaceScale = 0.72;
}

_TerminalSymbolGlyphSpec? _terminalSymbolGlyphSpec(int rune) => switch (rune) {
  0x25C0 => const _TerminalSymbolGlyphSpec(
    kind: _TerminalSymbolGlyphKind.leftTriangle,
    filled: true,
    strokeScale: 0.1,
  ),
  0x25B6 => const _TerminalSymbolGlyphSpec(
    kind: _TerminalSymbolGlyphKind.rightTriangle,
    filled: true,
    strokeScale: 0.1,
  ),
  0x25B2 => const _TerminalSymbolGlyphSpec(
    kind: _TerminalSymbolGlyphKind.upTriangle,
    filled: true,
    strokeScale: 0.1,
  ),
  0x25BC => const _TerminalSymbolGlyphSpec(
    kind: _TerminalSymbolGlyphKind.downTriangle,
    filled: true,
    strokeScale: 0.1,
  ),
  0x25A0 => const _TerminalSymbolGlyphSpec(
    kind: _TerminalSymbolGlyphKind.square,
    filled: true,
    strokeScale: 0.1,
  ),
  0x2190 => const _TerminalSymbolGlyphSpec(
    kind: _TerminalSymbolGlyphKind.leftArrow,
    strokeScale: 0.12,
  ),
  0x2192 => const _TerminalSymbolGlyphSpec(
    kind: _TerminalSymbolGlyphKind.rightArrow,
    strokeScale: 0.12,
  ),
  0x2191 => const _TerminalSymbolGlyphSpec(
    kind: _TerminalSymbolGlyphKind.upArrow,
    strokeScale: 0.12,
  ),
  0x2193 => const _TerminalSymbolGlyphSpec(
    kind: _TerminalSymbolGlyphKind.downArrow,
    strokeScale: 0.12,
  ),
  0x21B5 => const _TerminalSymbolGlyphSpec(
    kind: _TerminalSymbolGlyphKind.enterArrow,
    strokeScale: 0.12,
  ),
  0x2713 => const _TerminalSymbolGlyphSpec(
    kind: _TerminalSymbolGlyphKind.checkmark,
    strokeScale: 0.14,
  ),
  0x2014 => const _TerminalSymbolGlyphSpec(
    kind: _TerminalSymbolGlyphKind.emDash,
    strokeScale: 0.1,
  ),
  // Heavy round-tipped rightwards arrow (U+279C) — common in zsh prompts.
  0x279C => const _TerminalSymbolGlyphSpec(
    kind: _TerminalSymbolGlyphKind.heavyRightArrow,
    filled: true,
    strokeScale: 0.1,
  ),
  _ => null,
};

enum _TerminalSymbolGlyphKind {
  upTriangle,
  downTriangle,
  leftTriangle,
  rightTriangle,
  square,
  leftArrow,
  rightArrow,
  upArrow,
  downArrow,
  enterArrow,
  checkmark,
  emDash,
  heavyRightArrow,
}

final class _TerminalSymbolGlyphSpec {
  const _TerminalSymbolGlyphSpec({
    required this.kind,
    required this.strokeScale,
    this.filled = false,
  });

  final _TerminalSymbolGlyphKind kind;
  final double strokeScale;
  final bool filled;
}

// The four cell quadrants as fraction rects, reused by the quadrant block
// glyphs (U+2596…U+259F). Sharing the exact 0.5 midline fractions is what lets
// quadrants tile seamlessly with the half-blocks (which also split at 0.5).
const _quadTopLeft = _CellFractionRect(right: 0.5, bottom: 0.5);
const _quadTopRight = _CellFractionRect(left: 0.5, bottom: 0.5);
const _quadBottomLeft = _CellFractionRect(top: 0.5, right: 0.5);
const _quadBottomRight = _CellFractionRect(left: 0.5, top: 0.5);

_TerminalBlockGlyphSpec? _terminalBlockGlyphSpec(int rune) => switch (rune) {
  // Partial blocks — a single rect filling some fraction from one cell edge.
  0x2580 => const _TerminalBlockGlyphSpec([
    _CellFractionRect(bottom: 0.5),
  ]), // ▀
  0x2581 => const _TerminalBlockGlyphSpec([_CellFractionRect(top: 7 / 8)]), // ▁
  0x2582 => const _TerminalBlockGlyphSpec([_CellFractionRect(top: 6 / 8)]), // ▂
  0x2583 => const _TerminalBlockGlyphSpec([_CellFractionRect(top: 5 / 8)]), // ▃
  0x2584 => const _TerminalBlockGlyphSpec([_CellFractionRect(top: 0.5)]), // ▄
  0x2585 => const _TerminalBlockGlyphSpec([_CellFractionRect(top: 3 / 8)]), // ▅
  0x2586 => const _TerminalBlockGlyphSpec([_CellFractionRect(top: 2 / 8)]), // ▆
  0x2587 => const _TerminalBlockGlyphSpec([_CellFractionRect(top: 1 / 8)]), // ▇
  0x2588 => const _TerminalBlockGlyphSpec([_fullCell]), // █ full block
  0x2589 => const _TerminalBlockGlyphSpec([
    _CellFractionRect(right: 7 / 8),
  ]), // ▉
  0x258A => const _TerminalBlockGlyphSpec([
    _CellFractionRect(right: 6 / 8),
  ]), // ▊
  0x258B => const _TerminalBlockGlyphSpec([
    _CellFractionRect(right: 5 / 8),
  ]), // ▋
  0x258C => const _TerminalBlockGlyphSpec([_CellFractionRect(right: 0.5)]), // ▌
  0x258D => const _TerminalBlockGlyphSpec([
    _CellFractionRect(right: 3 / 8),
  ]), // ▍
  0x258E => const _TerminalBlockGlyphSpec([
    _CellFractionRect(right: 2 / 8),
  ]), // ▎
  0x258F => const _TerminalBlockGlyphSpec([
    _CellFractionRect(right: 1 / 8),
  ]), // ▏
  0x2590 => const _TerminalBlockGlyphSpec([_CellFractionRect(left: 0.5)]), // ▐
  // Shade blocks — full cell filled at a fraction of the foreground alpha.
  0x2591 => const _TerminalBlockGlyphSpec([_fullCell], shadeAlpha: 0.25), // ░
  0x2592 => const _TerminalBlockGlyphSpec([_fullCell], shadeAlpha: 0.5), // ▒
  0x2593 => const _TerminalBlockGlyphSpec([_fullCell], shadeAlpha: 0.75), // ▓
  0x2594 => const _TerminalBlockGlyphSpec([
    _CellFractionRect(bottom: 1 / 8),
  ]), // ▔
  0x2595 => const _TerminalBlockGlyphSpec([
    _CellFractionRect(left: 7 / 8),
  ]), // ▕
  // Quadrant blocks (U+2596…U+259F) — the 2×2 sub-cell mosaic TUIs use for
  // pixel-art banners/logos. Each fills one or more of the four quadrants.
  0x2596 => const _TerminalBlockGlyphSpec([_quadBottomLeft]), // ▖
  0x2597 => const _TerminalBlockGlyphSpec([_quadBottomRight]), // ▗
  0x2598 => const _TerminalBlockGlyphSpec([_quadTopLeft]), // ▘
  0x2599 => const _TerminalBlockGlyphSpec([
    _quadTopLeft,
    _quadBottomLeft,
    _quadBottomRight,
  ]), // ▙
  0x259A => const _TerminalBlockGlyphSpec([
    _quadTopLeft,
    _quadBottomRight,
  ]), // ▚
  0x259B => const _TerminalBlockGlyphSpec([
    _quadTopLeft,
    _quadTopRight,
    _quadBottomLeft,
  ]), // ▛
  0x259C => const _TerminalBlockGlyphSpec([
    _quadTopLeft,
    _quadTopRight,
    _quadBottomRight,
  ]), // ▜
  0x259D => const _TerminalBlockGlyphSpec([_quadTopRight]), // ▝
  0x259E => const _TerminalBlockGlyphSpec([
    _quadTopRight,
    _quadBottomLeft,
  ]), // ▞
  0x259F => const _TerminalBlockGlyphSpec([
    _quadTopRight,
    _quadBottomLeft,
    _quadBottomRight,
  ]), // ▟
  _ => null,
};

/// A rectangle within a cell, expressed as fractions [0, 1] of the cell's width
/// and height. The fields are fill BOUNDS, not a side: `(0, 0, 1, 1)` (the
/// default, [_fullCell]) is the whole cell; `_CellFractionRect(bottom: 0.5)` is
/// the top half; `_CellFractionRect(left: 0.5)` is the right half.
class _CellFractionRect {
  const _CellFractionRect({
    this.left = 0,
    this.top = 0,
    this.right = 1,
    this.bottom = 1,
  });

  final double left;
  final double top;
  final double right;
  final double bottom;
}

const _fullCell = _CellFractionRect();

final class _TerminalBlockGlyphSpec {
  const _TerminalBlockGlyphSpec(this.rects, {this.shadeAlpha});

  /// Sub-cell rectangles to fill. Most block glyphs are a single rect; quadrant
  /// glyphs (U+2596…U+259F) use up to four disjoint rects. A unified list keeps
  /// half-blocks, eighths, full/shade blocks, and quadrants on one painting
  /// path (mirrors ghostty's block.zig, which models all of U+2580…259F).
  final List<_CellFractionRect> rects;

  /// When set, [rects] are filled at this fraction of the foreground alpha
  /// (the shade blocks ░▒▓).
  final double? shadeAlpha;
}

Iterable<String> _splitTerminalCells(String text) sync* {
  if (text.isEmpty) {
    return;
  }
  yield* text.characters;
}

/// Returns `true` if [rune] is a Unicode "wide" character that occupies two
/// terminal columns (East Asian Wide / Fullwidth, wide emoji, etc.).
bool _isWideRune(int rune) {
  // Zero-width joiner — always narrow (combines preceding/following characters).
  if (rune == 0x200D) return false;
  // Variation selectors (U+FE00–U+FE0F) — narrow combining characters that
  // select a presentation variant; must not be counted as wide.
  if (rune >= 0xFE00 && rune <= 0xFE0F) return false;
  // Regional Indicator Symbols (U+1F1E6–U+1F1FF) — pairs form flag emoji and
  // each symbol occupies two terminal columns.
  if (rune >= 0x1F1E6 && rune <= 0x1F1FF) return true;
  // Hangul Jamo
  if (rune >= 0x1100 && rune <= 0x115F) return true;
  // CJK Radicals Supplement … CJK Unified Ideographs Extension A
  if (rune >= 0x2E80 && rune <= 0x303E) return true;
  // Hiragana … Yi Radicals (covers Katakana, Bopomofo, CJK Unified Ideographs…)
  if (rune >= 0x3040 && rune <= 0xA4CF) return true;
  // Hangul Syllables
  if (rune >= 0xAC00 && rune <= 0xD7A3) return true;
  // CJK Compatibility Ideographs
  if (rune >= 0xF900 && rune <= 0xFAFF) return true;
  // Vertical forms
  if (rune >= 0xFE10 && rune <= 0xFE1F) return true;
  // CJK Compatibility Forms … Small Form Variants
  if (rune >= 0xFE30 && rune <= 0xFE6F) return true;
  // Fullwidth Latin / Halfwidth and Fullwidth Forms (fullwidth block)
  if (rune >= 0xFF01 && rune <= 0xFF60) return true;
  // Fullwidth cent / pound / yen / won / fullwidth macron
  if (rune >= 0xFFE0 && rune <= 0xFFE6) return true;
  // Wide emoji / pictographs (plane 1 wide blocks)
  if (rune >= 0x1F004 && rune <= 0x1F9FF) return true;
  // CJK Unified Ideographs Extension B–F and Compatibility Supplement
  if (rune >= 0x20000 && rune <= 0x2FA1F) return true;
  return false;
}

/// Assigns a display-cell width to each grapheme cluster in [text] using
/// Unicode display-width rules, cross-checked against [totalCells].
///
/// Each grapheme cluster is assigned width 2 if its first rune is a "wide"
/// Unicode character (East Asian Wide / Fullwidth), and width 1 otherwise.
/// If the resulting sum disagrees with [totalCells] (e.g. because the terminal
/// uses a different width table), the excess or deficit is distributed across
/// graphemes as a fallback.
List<int> _measureTerminalCellWidths(String text, int totalCells) {
  final graphemes = _splitTerminalCells(text).toList(growable: false);
  if (graphemes.isEmpty) {
    return const <int>[];
  }

  if (totalCells <= 0) {
    return List<int>.filled(graphemes.length, 1, growable: false);
  }

  // Assign widths based on Unicode display-width of the first rune.
  final widths = <int>[
    for (final g in graphemes)
      g.isNotEmpty && _isWideRune(g.runes.first) ? 2 : 1,
  ];

  // Cross-check against totalCells and adjust if they disagree.
  var delta = totalCells - widths.fold<int>(0, (sum, v) => sum + v);
  if (delta > 0) {
    // More cells than we accounted for — distribute extra cells to trailing
    // graphemes first so that ambiguous-width glyphs (e.g. emoji sequences
    // that the terminal counts as wide) absorb the surplus before leading
    // narrow characters do.
    for (var i = widths.length - 1; delta > 0 && i >= 0; i--) {
      widths[i]++;
      delta--;
    }
  } else if (delta < 0) {
    // Fewer cells than we accounted for — shrink wide graphemes first.
    for (var i = 0; delta < 0 && i < widths.length; i++) {
      if (widths[i] > 1) {
        widths[i]--;
        delta++;
      }
    }
  }

  return widths;
}

/// Bridges the platform soft keyboard (IME) to terminal stdin on touch
/// devices (Android/iOS).
///
/// A terminal has no editable document, so there is nothing for a normal
/// `EditableText` to edit — yet the on-screen keyboard on mobile only appears
/// when *some* widget attaches a text-input client to the platform. A bare
/// [FocusNode] gaining focus wires up `HardwareKeyboard` (physical/Bluetooth
/// keys) but never attaches such a client, so without this bridge mobile users
/// can focus the terminal but never raise a keyboard to type.
///
/// Input is consumed via Flutter's **delta model** ([DeltaTextInputClient],
/// opted in with `enableDeltaModel: true`): the platform reports each change as
/// a typed [TextEditingDelta] carrying an explicit *composing* region. That
/// region is the whole reason to prefer deltas here — while it is active the
/// IME is mid-word (CJK candidates, glide typing), and forwarding that
/// provisional text would leak half-typed guesses to the shell. So a delta's
/// text is forwarded only once its composing region has settled: insertions and
/// committed replacements become PTY writes, deletions become backspaces, and
/// embedded newlines become Enter. Between settled events the hidden field is
/// re-anchored to a fixed zero-width seed so it never empties — an empty field
/// can't report the *next* backspace (the platform sends no deletion when there
/// is nothing to delete) — while never surfacing visible text.
///
/// The delta path is deliberately incremental — each emission reads the change
/// the platform described (`textInserted`/`textDeleted`), never a diff of the
/// local mirror. Re-anchoring is asynchronous, so a keystroke racing an
/// in-flight re-anchor arrives measured against the IME's older text; trusting
/// the reported change stays correct there, whereas diffing the whole value
/// against the seed would read the stale offsets as deletions and backspace
/// real shell content.
class _GhosttyTerminalSoftKeyboard with DeltaTextInputClient {
  _GhosttyTerminalSoftKeyboard({
    required this.onInsert,
    required this.onBackspace,
    required this.onEnter,
  });

  /// Called with printable text the IME inserted (never contains newlines —
  /// those are split out to [onEnter]).
  final void Function(String text) onInsert;

  /// Called once per character the IME deleted.
  final void Function() onBackspace;

  /// Called when the user commits a line (Return / Go / Send / Done).
  final void Function() onEnter;

  TextInputConnection? _connection;

  // Zero-width seed: a run of invisible characters kept before the caret as
  // "deletion fuel". An empty field reports no deletion, so without content a
  // backspace on an already-empty line is silently dropped. The run is
  // deliberately generous (not 1-2 chars) so a single frame that batches
  // several deletions \u2014 a keyboard word-delete or a held-backspace burst \u2014
  // still yields one backspace per removed char instead of bottoming out at the
  // field start. The field is re-seeded every settled frame, so this length is
  // only the *per-frame* bound; a delete larger than the seed is still capped.
  static const int _seedRune = 0x200b; // zero-width space
  static const int _seedLength = 64;
  static final String _seed = String.fromCharCode(_seedRune) * _seedLength;
  static final TextEditingValue _seedValue = TextEditingValue(
    text: _seed,
    selection: const TextSelection.collapsed(offset: _seedLength),
  );

  /// Local mirror of the hidden field, advanced by each delta's `apply` so the
  /// re-anchor decision can read the settled composing region.
  TextEditingValue _value = _seedValue;

  bool get _isAttached => _connection?.attached ?? false;

  /// Whether the IME bridge currently owns input (attached to the platform).
  /// Read by the view's raw-key handler to avoid double-applying keys the IME
  /// also delivers.
  bool get isActive => _isAttached;

  /// Whether [range] denotes an active composing span (valid and non-empty).
  static bool _isComposing(TextRange range) =>
      range.isValid && !range.isCollapsed;

  void show() {
    final wasAttached = _isAttached;
    if (!wasAttached) {
      _connection = TextInput.attach(
        this,
        const TextInputConfiguration(
          // Structured per-change deltas with explicit composing regions —
          // required for the composing-aware forwarding below.
          enableDeltaModel: true,
          // Terminals must see raw keystrokes: kill autocorrect, suggestions,
          // autocapitalization, and smart dashes/quotes so nothing rewrites
          // what the user typed before it reaches the shell. Multiline keeps a
          // Return key (translated to Enter) rather than a Go/Done button.
          inputType: TextInputType.multiline,
          inputAction: TextInputAction.newline,
          autocorrect: false,
          enableSuggestions: false,
          smartDashesType: SmartDashesType.disabled,
          smartQuotesType: SmartQuotesType.disabled,
          textCapitalization: TextCapitalization.none,
          keyboardAppearance: Brightness.dark,
        ),
      );
    }
    // Seed the field only on a fresh attach or when nothing is being composed.
    // show() is re-invoked on every terminal tap (to re-raise a Back-dismissed
    // keyboard); re-seeding then would clear an in-progress composing region —
    // e.g. tapping to scroll mid-pinyin would drop the candidate word.
    if (!wasAttached || !_isComposing(_value.composing)) {
      _value = _seedValue;
      _connection!.setEditingState(_seedValue);
    }
    _connection!.show();
  }

  void hide() {
    _connection?.close();
    _connection = null;
  }

  @override
  TextEditingValue? get currentTextEditingValue => _value;

  @override
  void updateEditingValueWithDeltas(List<TextEditingDelta> deltas) {
    for (final delta in deltas) {
      final priorComposing = _value.composing;
      _value = delta.apply(_value);

      // Selection/caret-only change (handle drag, cursor move): normally no
      // bytes. But an IME can *commit* a composition by merely clearing its
      // composing region with no accompanying insertion/replacement — the
      // provisional text was inserted earlier (and held) and is now simply
      // accepted as-is. When this clear ends an active composition, that text
      // is final and no other delta will carry it, so emit it here or it is
      // lost. (A commit that also *changes* the text arrives as a replacement,
      // handled below.)
      if (delta is TextEditingDeltaNonTextUpdate) {
        if (_isComposing(priorComposing) && !_isComposing(delta.composing)) {
          _emitText(priorComposing.textInside(delta.oldText));
        }
        continue;
      }
      // Mid-composition (CJK, glide typing, candidate list): the text is still
      // provisional. Hold — it is emitted once the composing region settles.
      if (_isComposing(delta.composing)) {
        continue;
      }

      if (delta is TextEditingDeltaInsertion) {
        // An insertion whose composing region is (already) empty is committed
        // per the input protocol, so it is emitted immediately. Known
        // limitation: an IME that opens its composing region only on the
        // *second* keystroke would leak the first character to the shell. We
        // can't tell "committed" from "about to compose" without deferring
        // every keystroke by a frame — unacceptable typing latency — so we
        // accept it. Disabling suggestions/autocorrect (see the config in
        // show()) removes the usual trigger for late composing, and CJK IMEs
        // open composing on keystroke 1, so both common cases are unaffected.
        _emitText(delta.textInserted);
      } else if (delta is TextEditingDeltaReplacement) {
        // A settled replacement is a committed IME word / suggestion; the
        // provisional text was never forwarded, so emit only the final text.
        _emitText(delta.replacementText);
      } else if (delta is TextEditingDeltaDeletion) {
        // Count seed runes only, not String.length. Two reasons:
        //  - String.length is UTF-16 code units, so an astral char (emoji, CJK
        //    ext) would over-count and send an extra backspace.
        //  - Only seed chars stand in for already-committed terminal text.
        //    Deleting provisional/composing text (non-seed, never forwarded)
        //    must send nothing — else we'd backspace real shell content.
        var count = 0;
        for (final rune in delta.textDeleted.runes) {
          if (rune == _seedRune) count++;
        }
        for (var i = 0; i < count; i++) {
          onBackspace();
        }
      }
    }

    // Re-anchor to the seed once composition has fully settled so the field
    // never empties and offsets stay trivial between events. Leaving it alone
    // mid-composition keeps the IME's provisional region intact.
    if (_isAttached && !_isComposing(_value.composing)) {
      _value = _seedValue;
      _connection!.setEditingState(_seedValue);
    }
  }

  /// Whole-value fallback: required by [TextInputClient], and reached only if
  /// an engine ignores `enableDeltaModel` and pushes complete editing values.
  /// No shipping target does — the bridge attaches on Android/iOS only, and
  /// both implement the delta channel — so this is defensive: it degrades to
  /// unstructured input rather than silently dropping every keystroke.
  ///
  /// Diffs against the seed by common prefix/suffix, holding provisional text
  /// on the same rule as the delta path.
  @override
  void updateEditingValue(TextEditingValue value) {
    // Mid-composition the text is provisional, so hold it and leave the field
    // untouched — re-anchoring here would destroy the IME's composing region.
    // The settled value carries the committed text, and it is diffed from the
    // same seed, so nothing is lost by waiting.
    if (_isComposing(value.composing)) {
      _value = value;
      return;
    }

    final next = value.text;
    var prefix = 0;
    final maxPrefix = math.min(_seed.length, next.length);
    while (prefix < maxPrefix &&
        _seed.codeUnitAt(prefix) == next.codeUnitAt(prefix)) {
      prefix++;
    }
    var suffix = 0;
    final maxSuffix = math.min(_seed.length - prefix, next.length - prefix);
    while (suffix < maxSuffix &&
        _seed.codeUnitAt(_seed.length - 1 - suffix) ==
            next.codeUnitAt(next.length - 1 - suffix)) {
      suffix++;
    }
    final removed = _seed.length - prefix - suffix;
    final inserted = next.substring(prefix, next.length - suffix);

    for (var i = 0; i < removed; i++) {
      onBackspace();
    }
    if (inserted.isNotEmpty) {
      _emitText(inserted);
    }

    // Re-anchor so the following value is measured from the same seed.
    _value = _seedValue;
    _connection?.setEditingState(_seedValue);
  }

  void _emitText(String text) {
    final buffer = StringBuffer();
    void flush() {
      if (buffer.isNotEmpty) {
        onInsert(buffer.toString());
        buffer.clear();
      }
    }

    for (final rune in text.runes) {
      // Soft-keyboard Return arrives as a newline inside the inserted text
      // under multiline input; forward it as a real Enter key press.
      if (rune == 0x0a || rune == 0x0d) {
        flush();
        onEnter();
      } else {
        buffer.writeCharCode(rune);
      }
    }
    flush();
  }

  @override
  void performAction(TextInputAction action) {
    switch (action) {
      // `newline` is intentionally absent: under multiline input Return arrives
      // as a newline insertion delta (handled in _emitText); firing onEnter
      // here too would double it. These are the single-line action variants.
      case TextInputAction.done:
      case TextInputAction.go:
      case TextInputAction.send:
      case TextInputAction.next:
      case TextInputAction.search:
        onEnter();
      default:
        break;
    }
  }

  @override
  void connectionClosed() {
    _connection = null;
  }

  // Remaining TextInputClient surface is inert: a terminal has no document
  // model, floating cursor, autofill scope, placeholder, or toolbar.
  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void insertTextPlaceholder(Size size) {}

  @override
  void removeTextPlaceholder() {}

  @override
  void showToolbar() {}

  @override
  void performSelector(String selectorName) {}

  @override
  void didChangeInputControl(
    TextInputControl? oldControl,
    TextInputControl? newControl,
  ) {}

  @override
  void insertContent(KeyboardInsertedContent content) {}

  @override
  bool onFocusReceived() => false;
}
