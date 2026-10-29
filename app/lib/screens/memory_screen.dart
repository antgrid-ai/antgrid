import 'dart:async';

import 'package:flutter/material.dart' show Scaffold;
import 'package:flutter/services.dart'
    show KeyDownEvent, KeyRepeatEvent, LogicalKeyboardKey;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants/breakpoints.dart';
import '../design/ab_colors.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_empty_state.dart';
import '../design/widgets/ab_inline_banner.dart';
import '../design/widgets/ab_loading.dart';
import '../design/widgets/ab_menu.dart';
import '../design/widgets/ab_scrollbar.dart';
import '../design/widgets/ab_separator.dart';
import '../design/widgets/ab_toast.dart';
import '../models/memory.dart';
import '../providers/control_plane.dart'
    show RefreshRef, retryMachineControlPlane;
import '../providers/memory.dart';
import '../providers/memory_route_targets.dart';
import '../services/memory_service.dart';
import '../util/detached.dart';
import '../widgets/file_download.dart';
import '../widgets/memory/memory_detail_pane.dart';
import '../widgets/memory/memory_error.dart';
import '../widgets/memory/memory_format.dart';
import '../widgets/memory/memory_header.dart';
import '../widgets/memory/memory_list.dart';
import '../widgets/memory/memory_off_state.dart';
import '../widgets/memory/memory_problems.dart';
import '../widgets/memory/memory_record_details.dart';
import '../widgets/memory/memory_settings_dialog.dart';
import '../widgets/memory/memory_toolbar.dart';

/// [projectId] presets the Project filter, which is how a project's own entry
/// opens the one machine-wide screen.
Future<void> openMemoryScreen(
  BuildContext context,
  MemoryTarget target, {
  String? projectId,
}) async {
  final route = PageRouteBuilder<void>(
    pageBuilder: (_, _, _) =>
        MemoryScreen(target: target, initialProjectId: projectId),
  );
  final container = ProviderScope.containerOf(context, listen: false);
  final machineId = target.machineId;
  final release = machineId == null
      ? null
      : container.read(memoryRouteTargetsProvider.notifier).retain(machineId);
  try {
    // push's future only yields the pop result; it can outlive a disposed
    // Navigator. completed covers both teardown and the dismissal animation.
    unawaited(Navigator.of(context).push<void>(route));
    await route.completed;
  } finally {
    release?.call();
    // Edits and settings made in here move the drawer's counts.
    container.invalidate(memoryDrawerSummaryProvider);
  }
}

class MemoryScreen extends ConsumerStatefulWidget {
  const MemoryScreen({super.key, required this.target, this.initialProjectId});
  final MemoryTarget target;
  final String? initialProjectId;
  @override
  ConsumerState<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends ConsumerState<MemoryScreen> {
  late MemoryFilter _filter = MemoryFilter(projectId: widget.initialProjectId);
  int _pages = 1;
  String? _selectedId;
  bool _pinned = false;

  // Forgotten ids never return, so the reload that lags a forget cannot
  // resurrect the row as the default selection.
  final Set<String> _forgottenIds = {};

  /// Keys the detail pane so an open edit or confirm never survives a filter
  /// change.
  int _epoch = 0;
  bool _busy = false;
  String? _actionError;
  String? _offError;

  // The only owner of the search text, shared by the wide and compact toolbars
  // so resizing across the breakpoint keeps what was typed.
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _screenFocus = FocusNode();
  final _paneFocus = FocusNode(
    canRequestFocus: false,
    skipTraversal: true,
    debugLabel: 'memory detail pane',
  );
  final _detailScroll = ScrollController();

  bool? _lastWide;

  // Written by build so the key handlers act on exactly what is on screen.
  List<MemoryRecord> _visible = const [];
  String? _effectiveId;

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    _screenFocus.dispose();
    _paneFocus.dispose();
    _detailScroll.dispose();
    super.dispose();
  }

  MemoryTarget get _target => widget.target;

  /// Every filter change goes through here so paging, pinning and the detail
  /// pane's identity reset together.
  void _setFilter(MemoryFilter next) => setState(() {
    _filter = next;
    _pages = 1;
    _pinned = false;
    _epoch++;
    _actionError = null;
  });

  /// With search broken the backend throws SEARCH_UNAVAILABLE for every search
  /// request, and the problems line promises the user can still browse. The
  /// query and the controller text are kept so search resumes with the same
  /// words after Rebuild search.
  MemoryFilter _applied(MemoryStatus status) =>
      status.searchReady ? _filter : _filter.browse();

  MemoryPageQuery _pageQuery(MemoryFilter applied, int index) => (
    target: _target,
    filter: applied,
    offset: index * kMemoryPageSize,
  );

  void _invalidatePages(MemoryStatus status) {
    final applied = _applied(status);
    for (var i = 0; i < _pages; i++) {
      ref.invalidate(memoryPageProvider(_pageQuery(applied, i)));
    }
  }

  void _showMore(MemoryStatus status) {
    // Refetching every loaded page together keeps their ordering and total
    // in agreement.
    _invalidatePages(status);
    setState(() => _pages++);
  }

  void _clearFilters() {
    _search.clear();
    _setFilter(MemoryFilter(versions: _filter.versions));
  }

  /// A settled dial failure is cached by the provider chain, so invalidating
  /// alone would replay it; the connection has to be redialled first.
  Future<void> _retry() async {
    final machineId = _target.machineId;
    if (machineId != null) {
      await retryMachineControlPlane(RefreshRef.of(ref), machineId);
    }
    if (!mounted) return;
    ref.invalidate(memoryStatusProvider(_target));
  }

  Future<bool> _send(
    Map<String, dynamic> request, {
    void Function(Object error)? onError,
  }) async {
    if (_busy) return false;
    final send = ref.read(memoryRequestProvider(_target));
    setState(() {
      _busy = true;
      _actionError = null;
    });
    try {
      await send(request);
      if (!mounted) return false;
      invalidateMemoryViews(ref, _target);
      return true;
    } catch (error) {
      if (mounted) {
        if (onError != null) {
          onError(error);
        } else {
          setState(() => _actionError = memoryErrorCopy(error, mutation: true));
        }
      }
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _repair({required bool announce}) async {
    final ok = await _send({'op': 'repair'});
    if (ok && announce && mounted) showAbToast(context, 'Search rebuilt');
  }

  Future<void> _turnOn() async {
    setState(() => _offError = null);
    await _send({
      'op': 'settings',
      'enabled': true,
    }, onError: (e) => setState(() => _offError = memoryErrorCopy(e, mutation: true)));
  }

  Future<void> _export({String? projectId}) async {
    if (_busy) return;
    final route = ModalRoute.of(context);
    bool isActive() => mounted && (route?.isActive ?? true);
    final request = ref.read(memoryRequestProvider(_target));
    setState(() {
      _busy = true;
      _actionError = null;
    });
    try {
      final bytes = await collectMemoryExport(
        request,
        isActive: isActive,
        projectId: projectId,
      );
      if (!mounted || route?.isActive == false || bytes == null) return;
      await downloadFileBytes(
        context,
        name: projectId == null
            ? 'antgrid-memory.json'
            : 'antgrid-memory-$projectId.json',
        mimeType: 'application/json',
        bytes: bytes,
      );
      if (mounted) showAbToast(context, 'Memories exported');
    } catch (error) {
      if (!mounted || route?.isActive == false) return;
      setState(() => _actionError = memoryErrorCopy(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openMore(BuildContext anchor) async {
    final rect = abMenuAnchorRect(anchor);
    if (rect == null) return;
    final picked = await showAbMenu<String>(
      context: anchor,
      anchorRect: rect,
      entries: const [
        AbMenuItem(label: 'Export memories', value: 'export'),
        AbMenuItem(label: 'Rebuild search', value: 'repair'),
      ],
    );
    if (!mounted) return;
    switch (picked) {
      case 'export':
        await _export(projectId: _filter.projectId);
      case 'repair':
        await _repair(announce: true);
    }
  }

  Future<void> _openSettings() => showMemorySettings(
    context,
    target: _target,
    onExportAll: () => _export(),
  );

  Future<void> _openRecord(String id) async {
    await Navigator.of(context).push<void>(
      PageRouteBuilder<void>(
        pageBuilder: (_, _, _) => MemoryRecordDetails(target: _target, id: id),
      ),
    );
    if (mounted) invalidateMemoryViews(ref, _target);
  }

  bool get _textFieldFocused =>
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<EditableText>() !=
      null;

  void _select(String id) {
    setState(() {
      _selectedId = id;
      _pinned = false;
    });
    // A mouse click on a row takes no focus, which would leave the arrow keys
    // dead.
    if (!_textFieldFocused && !_paneFocus.hasFocus) _screenFocus.requestFocus();
  }

  void _moveSelection(int delta) {
    if (_textFieldFocused || _visible.isEmpty) return;
    final current = _visible.indexWhere((r) => r.id == _effectiveId);
    final next = (current + delta).clamp(0, _visible.length - 1);
    if (next == current) return;
    setState(() {
      _selectedId = _visible[next].id;
      _pinned = false;
    });
  }

  void _onSaved(String id) {
    setState(() {
      _selectedId = id;
      _pinned = true;
    });
    invalidateMemoryViews(ref, _target);
  }

  void _onForgotten() {
    final gone = _effectiveId;
    setState(() {
      if (gone != null) _forgottenIds.add(gone);
      _selectedId = null;
      _pinned = false;
      _epoch++;
    });
    invalidateMemoryViews(ref, _target);
  }

  /// The race where a status fetched before a forget still offered Show memory.
  void _onGone() {
    if (!_pinned) return;
    setState(() {
      _selectedId = null;
      _pinned = false;
    });
    ref.invalidate(memoryStatusProvider(_target));
    showAbToast(context, 'This memory was forgotten.');
  }

  Future<void> _showMemory(MemoryFailure failure, {required bool wide}) async {
    try {
      await ref.read(memoryRequestProvider(_target))({
        'op': 'dismiss',
        'target_id': failure.targetId,
      });
    } catch (_) {
      // Acknowledging is best effort; the memory is still worth showing.
    }
    if (!mounted) return;
    _search.clear();
    _setFilter(const MemoryFilter());
    invalidateMemoryViews(ref, _target);
    if (wide) {
      setState(() {
        _selectedId = failure.showId;
        _pinned = true;
      });
    } else {
      await _openRecord(failure.showId);
    }
  }

  Widget _frame({
    required Widget header,
    List<Widget> above = const [],
    required Widget body,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      header,
      ...above,
      if (_actionError case final error?)
        AbInlineBanner(text: error, color: context.antgrid.error),
      Expanded(child: body),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final statusAsync = ref.watch(memoryStatusProvider(_target));
    final status = statusAsync.value;
    return Scaffold(
      backgroundColor: context.antgrid.bgDeepest,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= kMediumBreakpoint;
            void close() => Navigator.of(context).pop();
            Widget bareHeader() => wide
                ? MemoryHeader(target: _target, onClose: close)
                : MemoryHeader.compact(onBack: close);
            if (status == null) {
              if (statusAsync.isLoading) {
                return _frame(
                  header: bareHeader(),
                  body: const Center(child: AbLoading()),
                );
              }
              return _frame(
                header: bareHeader(),
                body: AbEmptyState.error(
                  title: 'Memory unavailable',
                  subtitle: memoryErrorCopy(statusAsync.error!),
                  action: AbButton(
                    label: _target.machineId != null
                        ? 'Reconnect and retry'
                        : 'Retry',
                    onTap: () =>
                        detached('Memory', 'reconnect failed', _retry),
                  ),
                ),
              );
            }
            if (!status.available) {
              return _frame(
                header: bareHeader(),
                body: AbEmptyState.error(
                  title: 'Memory unavailable',
                  subtitle:
                      "Memory storage couldn't be opened. Saved memories stay on disk.",
                  action: AbButton(
                    label: 'Retry store recovery',
                    onTap: _busy
                        ? null
                        : () => detached(
                            'Memory',
                            'recovery failed',
                            () => _repair(announce: false),
                          ),
                  ),
                ),
              );
            }
            if (!status.enabled) {
              return _frame(
                header: bareHeader(),
                body: MemoryOffState(
                  busy: _busy,
                  error: _offError,
                  onTurnOn: () => detached('Memory', 'enable failed', _turnOn),
                ),
              );
            }
            return _full(status, wide: wide, close: close);
          },
        ),
      ),
    );
  }

  Widget _full(
    MemoryStatus status, {
    required bool wide,
    required VoidCallback close,
  }) {
    final colors = context.antgrid;
    final projects = ref.watch(memoryProjectsProvider(_target)).value;
    final applied = _applied(status);
    final pages = [
      for (var i = 0; i < _pages; i++)
        ref.watch(memoryPageProvider(_pageQuery(applied, i))),
    ];
    final visible = concatMemoryPages(
      pages.map((p) => p.value).nonNulls,
    ).where((r) => !_forgottenIds.contains(r.id)).toList();
    final total = pages.first.value?.total;
    final selected =
        _selectedId != null &&
            (_pinned || visible.any((r) => r.id == _selectedId))
        ? _selectedId
        : visible.firstOrNull?.id;
    _visible = visible;
    _effectiveId = wide ? selected : null;

    // The search field is disposed with its debounce pending when the layout
    // crosses the breakpoint, so text typed in that window is only in the
    // controller.
    if (_lastWide != null && _lastWide != wide) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _search.text == _filter.query) return;
        _setFilter(
          MemoryFilter(
            versions: _filter.versions,
            projectId: _filter.projectId,
            memoryType: _filter.memoryType,
            query: _search.text,
          ),
        );
      });
    }
    _lastWide = wide;

    final projectId = _filter.projectId;
    final projectPaused =
        projectId != null && (projects?[projectId]?.paused ?? false);
    final word = memoryStatusWord(status, projectPaused: projectPaused).word;
    final problems = MemoryProblems(
      status: status,
      busy: _busy,
      onRepair: () => detached(
        'Memory',
        'repair failed',
        () => _repair(announce: !status.searchReady),
      ),
      onShowMemory: (f) => detached(
        'Memory',
        'show memory failed',
        () => _showMemory(f, wide: wide),
      ),
    );
    final listPane = MemoryListPane(
      filter: applied,
      pages: pages,
      visible: visible,
      selectedId: wide ? selected : null,
      projects: projects,
      compact: !wide,
      onSelect: wide
          ? _select
          : (id) => detached('Memory', 'open failed', () => _openRecord(id)),
      onShowMore: () => _showMore(status),
      onClearFilters: _clearFilters,
      onRetry: () => _invalidatePages(status),
    );

    if (!wide) {
      return _frame(
        header: MemoryHeader.compact(
          onBack: close,
          onSettings: () =>
              detached('Memory', 'settings failed', _openSettings),
        ),
        above: [
          problems,
          MemoryToolbar(
            compact: true,
            filter: _filter,
            projects: projects,
            searchReady: status.searchReady,
            searchController: _search,
            searchFocus: _searchFocus,
            onChanged: _setFilter,
            countLine: total == null
                ? null
                : '${memoryCountLabel(total)}  ·  ${word.toLowerCase()}',
          ),
        ],
        body: listPane,
      );
    }

    final Widget detail = selected == null
        ? Padding(
            padding: const EdgeInsets.only(
              top: 40,
              left: AbTokens.space24,
              right: AbTokens.space24,
            ),
            child: Text(
              'Select a memory to see where it came from.',
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontMd,
                color: colors.textMuted,
              ),
            ),
          )
        : AbScrollbar(
            controller: _detailScroll,
            child: SingleChildScrollView(
              controller: _detailScroll,
              padding: const EdgeInsets.all(AbTokens.space24),
              child: Align(
                alignment: Alignment.topLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: AbTokens.transcriptMaxWidth,
                  ),
                  child: MemoryDetailPane(
                    key: ValueKey((selected, _epoch)),
                    target: _target,
                    id: selected,
                    onSaved: _onSaved,
                    onForgotten: _onForgotten,
                    onGone: _onGone,
                  ),
                ),
              ),
            ),
          );

    void findInList() => _searchFocus.requestFocus();
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            findInList,
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true): findInList,
      },
      child: Focus(
        focusNode: _screenFocus,
        autofocus: true,
        // Not a CallbackShortcuts binding: that reports handled even when the
        // callback declines, which would keep the arrows from text fields.
        onKeyEvent: (_, event) {
          if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
            return KeyEventResult.ignored;
          }
          final key = event.logicalKey;
          if (_textFieldFocused ||
              (key != LogicalKeyboardKey.arrowDown &&
                  key != LogicalKeyboardKey.arrowUp)) {
            return KeyEventResult.ignored;
          }
          _moveSelection(key == LogicalKeyboardKey.arrowDown ? 1 : -1);
          return KeyEventResult.handled;
        },
        child: _frame(
          header: MemoryHeader(
            target: _target,
            status: status,
            projectPaused: projectPaused,
            onClose: close,
            onSettings: () =>
                detached('Memory', 'settings failed', _openSettings),
            onMore: (anchor) =>
                detached('Memory', 'menu failed', () => _openMore(anchor)),
          ),
          above: [
            problems,
            MemoryToolbar(
              filter: _filter,
              projects: projects,
              searchReady: status.searchReady,
              searchController: _search,
              searchFocus: _searchFocus,
              onChanged: _setFilter,
            ),
          ],
          body: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 400,
                child: Semantics(
                  container: true,
                  label: 'Memories',
                  child: listPane,
                ),
              ),
              const AbSeparator.vertical(),
              Expanded(
                child: Semantics(
                  container: true,
                  label: 'Selected memory',
                  child: Focus(focusNode: _paneFocus, child: detail),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
