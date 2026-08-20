import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/styles/vs2015.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/ab_colors.dart';
import '../design/widgets/ab_empty_state.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_loading.dart';
import '../design/widgets/ab_search_field.dart';
import '../design/widgets/ab_toolbar.dart';
import '../models/file_tree_models.dart';
import '../providers/providers.dart';
import 'code_syntax.dart';
import 'send_to_agent_button.dart';
import 'send_to_agent_comment.dart';
import 'viewer_support.dart';

/// A widget that displays file content with syntax highlighting,
/// loading states, and error handling.
class FileContentViewer extends ConsumerStatefulWidget {
  final FileContent? fileContent;
  final bool isLoading;
  final String? selectedFilePath;
  final bool fileWasModified;
  final VoidCallback? onRefreshContent;
  final VoidCallback? onClose;
  final int? searchLine;
  final String? searchQuery;

  /// When non-null, the header shows a button to return to a rendered preview
  /// (used by markdown/svg viewers in source mode).
  final VoidCallback? onShowPreview;

  const FileContentViewer({
    super.key,
    this.fileContent,
    this.isLoading = false,
    this.selectedFilePath,
    this.fileWasModified = false,
    this.onRefreshContent,
    this.onClose,
    this.searchLine,
    this.searchQuery,
    this.onShowPreview,
  });

  @override
  ConsumerState<FileContentViewer> createState() => _FileContentViewerState();
}

class _FileContentViewerState extends ConsumerState<FileContentViewer>
    with SingleTickerProviderStateMixin {
  CodeLineEditingController? _controller;
  CodeScrollController? _scrollController;
  CodeFindController? _findController;
  String? _loadedContent;
  bool _hasSelection = false;
  int? _lastScrolledLine;
  bool _editorReady = false;
  bool _editorReadyScheduled = false;
  int _syncGeneration = 0;
  Timer? _editorReadyTimer;
  bool _showSearch = false;
  final FocusNode _searchFocusNode = FocusNode();

  // Edge auto-scroll
  late final Ticker _scrollTicker;
  Duration _lastTick = Duration.zero;
  Offset? _dragPosition;
  CodeLineSelection? _dragStartSelection;
  Size _editorSize = Size.zero;
  static const _edgeZone = 40.0;
  static const _maxSpeed = 1200.0; // px/s at edge

  /// Detects when re_editor's highlight isolate finishes by checking for
  /// colored child spans. Only schedules one callback per layout pass.
  TextSpan _onSpanBuild({
    required BuildContext context,
    required int index,
    required CodeLine codeLine,
    required TextSpan textSpan,
    required TextStyle style,
  }) {
    if (!_editorReady &&
        !_editorReadyScheduled &&
        textSpan.children != null &&
        textSpan.children!.isNotEmpty) {
      _editorReadyScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_editorReady) setState(() => _editorReady = true);
      });
    }
    return textSpan;
  }

  void _onSelectionChanged() {
    final hasSelection =
        _controller != null && !_controller!.selection.isCollapsed;
    if (hasSelection != _hasSelection) {
      setState(() => _hasSelection = hasSelection);
    }
  }

  void _syncController() {
    final text = widget.fileContent?.content;
    if (text == _loadedContent) return;
    _loadedContent = text;
    _controller?.removeListener(_onSelectionChanged);
    _findController?.dispose();
    _controller?.dispose();
    _scrollController?.dispose();
    if (text != null) {
      _controller = CodeLineEditingController(
        codeLines: text.codeLines,
        spanBuilder: _onSpanBuild,
      );
      _controller!.addListener(_onSelectionChanged);
      _findController = CodeFindController(_controller!);
    } else {
      _controller = null;
      _findController = null;
    }
    _scrollController = text != null ? CodeScrollController() : null;
    _hasSelection = false;
    _lastScrolledLine = null;
    // Keep editor hidden until the highlight isolate finishes (detected via
    // _onSpanBuild). For files without a known language, show immediately.
    // Fallback timeout ensures the editor is always revealed even if the
    // spanBuilder never sees highlighted children (e.g. empty files).
    _editorReady =
        text == null || codeLanguageForPath(widget.fileContent?.path) == null;
    _editorReadyScheduled = false;
    if (!_editorReady) {
      final generation = ++_syncGeneration;
      _editorReadyTimer?.cancel();
      _editorReadyTimer = Timer(const Duration(seconds: 2), () {
        if (mounted && generation == _syncGeneration && !_editorReady) {
          setState(() => _editorReady = true);
        }
      });
    }
    final line = widget.searchLine;
    if (text != null && line != null) {
      _lastScrolledLine = line;
      _scrollToSearchLine(line);
    }
    _applySearchHighlight();
  }

  void _applySearchHighlight() {
    final query = widget.searchQuery;
    if (_findController == null || query == null || query.isEmpty) {
      // Clear any existing highlights.
      if (_findController?.value != null) {
        _findController!.close();
      }
      return;
    }
    // Programmatically trigger the find. We must set a non-null value first
    // so that _onFindPatternChanged (the listener) doesn't bail out.
    _findController!.value = CodeFindValue(
      option: CodeFindOption(
        pattern: query,
        caseSensitive: false,
        regex: false,
      ),
      replaceMode: false,
    );
    _findController!.findInputController.text = query;
  }

  void _scrollToSearchLine(int line) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final sc = _scrollController?.verticalScroller;
      if (sc == null || !sc.hasClients) return;
      final viewportHeight = sc.position.viewportDimension;
      final offset =
          (line - 1) * kCodeLineHeight - (viewportHeight / 2) + kCodeLineHeight;
      sc.animateTo(
        offset.clamp(sc.position.minScrollExtent, sc.position.maxScrollExtent),
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _onSendToAgent() async {
    final controller = _controller;
    if (controller == null) return;
    final text = controller.selectedText;
    if (text.isEmpty) return;

    final fileName = viewerBasename(widget.fileContent?.path ?? 'unknown');
    final sourceLabel = '[from file: $fileName]';
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
    controller.cancelSelection();
    setState(() => _hasSelection = false);
    showSentToAgentSnackBar(context);
  }

  @override
  void initState() {
    super.initState();
    _scrollTicker = createTicker(_onScrollTick);
    _syncController();
  }

  @override
  void didUpdateWidget(covariant FileContentViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncController();
    // Scroll when searchLine changes and content is already loaded.
    final line = widget.searchLine;
    if (line != null && line != _lastScrolledLine && _loadedContent != null) {
      _lastScrolledLine = line;
      _scrollToSearchLine(line);
    }
    // Update highlight when searchQuery changes.
    if (widget.searchQuery != oldWidget.searchQuery) {
      _applySearchHighlight();
    }
  }

  void _toggleSearch() {
    setState(() {
      _showSearch = !_showSearch;
      if (_showSearch) {
        // findMode() seeds a non-null CodeFindValue (and autofills from a
        // single-line selection); without it, CodeFindController.value stays
        // null and its findInputController listener no-ops on every
        // keystroke, so typing into the field never actually searched.
        _findController?.findMode();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _searchFocusNode.requestFocus();
        });
      } else {
        _findController?.close();
      }
    });
  }

  @override
  void dispose() {
    _editorReadyTimer?.cancel();
    _searchFocusNode.dispose();
    _scrollTicker.dispose();
    _controller?.removeListener(_onSelectionChanged);
    _findController?.dispose();
    _controller?.dispose();
    _scrollController?.dispose();
    super.dispose();
  }

  /// Sends a sideways-dominant scroll to the horizontal axis, whatever it
  /// landed on. A pointer signal goes to the FIRST interested registrant in
  /// hit-test order (innermost out), so this only works from a node below the
  /// scrollable it is taking the event away from.
  void _claimSidewaysScroll(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final delta = event.scrollDelta;
    if (delta.dx.abs() <= delta.dy.abs()) return;
    final scroller = _scrollController?.horizontalScroller;
    if (scroller == null || !scroller.hasClients) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      final position = scroller.position;
      scroller.jumpTo(
        (position.pixels + delta.dx).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
    });
  }

  void _onPointerDown(PointerDownEvent event) {
    _dragStartSelection = _controller?.selection;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!event.down || event.buttons == 0) return;
    // Edge auto-scroll is for a SELECTION drag reaching past the viewport —
    // never for a plain pan. Reading a long line means dragging sideways
    // across it, and near the top or bottom that put the drag inside the edge
    // zone: the file scrolled vertically under a gesture that asked to go
    // sideways. A selection drag is the one that CHANGES the selection, so
    // that (not merely having one, which survives from an earlier select) is
    // what arms this.
    if (!_isSelectionDrag) {
      _onPointerUp(event);
      return;
    }
    _dragPosition = event.localPosition;
    if (!_scrollTicker.isActive) {
      _lastTick = Duration.zero;
      _scrollTicker.start();
    }
  }

  bool get _isSelectionDrag {
    final selection = _controller?.selection;
    return selection != null &&
        !selection.isCollapsed &&
        selection != _dragStartSelection;
  }

  void _onPointerUp(PointerEvent event) {
    _dragPosition = null;
    if (_scrollTicker.isActive) _scrollTicker.stop();
  }

  void _onScrollTick(Duration elapsed) {
    final pos = _dragPosition;
    final sc = _scrollController;
    if (pos == null || sc == null) return;

    final dt = _lastTick == Duration.zero
        ? 1 / 60
        : (elapsed - _lastTick).inMicroseconds / Duration.microsecondsPerSecond;
    _lastTick = elapsed;

    final vy = _edgeSpeed(pos.dy, _editorSize.height);
    final vx = _edgeSpeed(pos.dx, _editorSize.width);

    if (vy == 0 && vx == 0) {
      _scrollTicker.stop();
      return;
    }

    if (vy != 0) {
      _jumpScroller(sc.verticalScroller, vy * dt);
    }
    if (vx != 0) {
      _jumpScroller(sc.horizontalScroller, vx * dt);
    }
  }

  static void _jumpScroller(ScrollController sc, double delta) {
    if (!sc.hasClients) return;
    final pos = sc.position;
    sc.jumpTo(
      (pos.pixels + delta).clamp(pos.minScrollExtent, pos.maxScrollExtent),
    );
  }

  /// Returns scroll speed in px/s. Negative = toward start, positive = toward end.
  /// Quadratic ramp: speed grows with square of penetration into edge zone.
  static double _edgeSpeed(double pos, double extent) {
    if (pos < _edgeZone) {
      final t = ((_edgeZone - pos) / _edgeZone).clamp(0.0, 1.0);
      return -_maxSpeed * t * t;
    }
    final far = extent - _edgeZone;
    if (pos > far) {
      final t = ((pos - far) / _edgeZone).clamp(0.0, 1.0);
      return _maxSpeed * t * t;
    }
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isLoading) {
      return const AbLoading();
    }

    if (widget.fileContent == null) {
      return const AbEmptyState(
        icon: AbIcons.files,
        title: 'Select a file to view',
      );
    }

    final content = widget.fileContent!;

    if (content.error != null) {
      return _buildError(content.error!);
    }

    if (_controller == null) {
      return Center(
        child: Text(
          'No content',
          style: AbTokens.sansStyle(color: context.antgrid.textMuted),
        ),
      );
    }

    final fileName = viewerBasename(content.path);
    final lang = codeLanguageForPath(content.path);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(fileName),
        if (_showSearch) _buildSearchBar(),
        if (widget.fileWasModified)
          ViewerModifiedBanner(onRefresh: widget.onRefreshContent),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              _editorSize = constraints.biggest;
              final agentTab = ref.watch(agentTerminalProvider);
              final showSendButton = _hasSelection && agentTab != null;
              return Stack(
                children: [
                  Visibility(
                    visible: _editorReady,
                    maintainState: true,
                    maintainAnimation: true,
                    maintainSize: true,
                    child: Listener(
                      onPointerDown: _onPointerDown,
                      onPointerMove: _onPointerMove,
                      onPointerUp: _onPointerUp,
                      onPointerCancel: _onPointerUp,
                      child: CodeEditor(
                        controller: _controller,
                        scrollController: _scrollController,
                        findController: _findController,
                        readOnly: true,
                        wordWrap: false,
                        showCursorWhenReadOnly: true,
                        style: CodeEditorStyle(
                          fontSize: kCodeFontSize,
                          fontFamily: AbTokens.fontMono,
                          fontFamilyFallback: AbTokens.fontMonoFallbacks,
                          fontHeight: kCodeFontHeight,
                          backgroundColor: context.antgrid.bgDeepest,
                          codeTheme: lang != null
                              ? CodeHighlightTheme(
                                  languages: {
                                    lang.key: CodeHighlightThemeMode(
                                      mode: lang.mode,
                                    ),
                                  },
                                  theme: vs2015Theme,
                                )
                              : null,
                        ),
                        indicatorBuilder:
                            (
                              context,
                              editingController,
                              chunkController,
                              notifier,
                            ) {
                              // The gutter is built inside the editor's
                              // VERTICAL scrollable but outside its
                              // horizontal one, so a sideways scroll landing
                              // on it has only the vertical axis to go to
                              // and drags the file up or down instead. This
                              // listener is a descendant of that scrollable,
                              // which is the only place a pointer signal can
                              // be taken from it — see [_claimSidewaysScroll].
                              return Listener(
                                onPointerSignal: _claimSidewaysScroll,
                                child: DefaultCodeLineNumber(
                                  controller: editingController,
                                  notifier: notifier,
                                ),
                              );
                            },
                        chunkAnalyzer: const DefaultCodeChunkAnalyzer(),
                      ),
                    ),
                  ),
                  if (!_editorReady)
                    Container(
                      color: context.antgrid.bgDeepest,
                      child: const AbLoading(),
                    ),
                  if (showSendButton)
                    SendToAgentButton(onPressed: _onSendToAgent),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildHeader(String fileName) {
    return AbToolbar.actions(
      center: Text(
        fileName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AbTokens.monoStyle(
          fontWeight: FontWeight.w600,
          fontSize: AbTokens.fontMd,
        ),
      ),
      trailing: [
        AbIconButton(
          icon: AbIcons.search,
          tone: _showSearch ? AbIconButtonTone.accent : AbIconButtonTone.normal,
          onTap: _toggleSearch,
          tooltip: 'Search in file',
        ),
        if (widget.onShowPreview != null)
          AbIconButton(
            icon: AbIcons.preview,
            onTap: widget.onShowPreview,
            tooltip: 'Show preview',
          ),
        AbIconButton(
          icon: AbIcons.close,
          onTap: widget.onClose,
          tooltip: 'Close file',
        ),
      ],
    );
  }

  Widget _buildSearchBar() {
    final fc = _findController;
    if (fc == null) return const SizedBox.shrink();

    return AbToolbar.actions(
      center: AbSearchField(
        controller: fc.findInputController,
        focusNode: _searchFocusNode,
        hint: 'Find...',
        prefixIcon: null,
        showClearButton: false,
        debounce: null,
        // No onChanged needed — CodeFindController already listens
        // to its own findInputController and triggers search internally.
        onSubmitted: (_) => fc.nextMatch(),
      ),
      trailing: [
        ValueListenableBuilder<CodeFindValue?>(
          valueListenable: fc,
          builder: (context, value, _) {
            final result = value?.result;
            if (result == null || result.matches.isEmpty) {
              final hasQuery = (value?.option.pattern ?? '').isNotEmpty;
              return SizedBox(
                width: 56,
                child: Text(
                  hasQuery ? '0/0' : '',
                  textAlign: TextAlign.center,
                  style: AbTokens.monoStyle(
                    fontSize: AbTokens.fontXs,
                    color: hasQuery
                        ? context.antgrid.error
                        : context.antgrid.textDisabled,
                  ),
                ),
              );
            }
            return SizedBox(
              width: 56,
              child: Text(
                '${result.index + 1}/${result.matches.length}',
                textAlign: TextAlign.center,
                style: AbTokens.monoStyle(
                  fontSize: AbTokens.fontXs,
                  color: context.antgrid.textSecondary,
                ),
              ),
            );
          },
        ),
        AbIconButton(
          icon: AbIcons.arrowUp,
          onTap: () => fc.previousMatch(),
          tooltip: 'Previous match',
        ),
        AbIconButton(
          icon: AbIcons.arrowDown,
          onTap: () => fc.nextMatch(),
          tooltip: 'Next match',
        ),
        AbIconButton(
          icon: AbIcons.close,
          onTap: _toggleSearch,
          tooltip: 'Close search',
        ),
      ],
    );
  }

  Widget _buildError(String error) {
    final errorLower = error.toLowerCase();
    if (errorLower.contains('not found') || errorLower.contains('deleted')) {
      return AbEmptyState(
        icon: AbIcons.close,
        title: 'This file was deleted',
        action: GestureDetector(
          onTap: widget.onClose,
          child: Text(
            'Close',
            style: AbTokens.sansStyle(color: context.antgrid.accent),
          ),
        ),
      );
    }
    // Boxed error variant \u2014 intentionally not AbEmptyState (only site).
    return Center(
      child: Container(
        margin: const EdgeInsets.all(24), // 24px non-ladder error card margin
        padding: const EdgeInsets.all(AbTokens.space16),
        decoration: BoxDecoration(
          color: context.antgrid.bgSurface,
          border: Border.all(color: context.antgrid.borderDefault),
          borderRadius: AbTokens.borderRadius8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '!',
              style: TextStyle(
                fontSize: AbTokens.fontDisplayMd,
                color: context.antgrid.error,
              ),
            ),
            const SizedBox(height: AbTokens.space12),
            Text(
              error,
              style: AbTokens.monoStyle(
                fontSize: AbTokens.fontBody,
                color: context.antgrid.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
