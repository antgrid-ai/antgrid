import 'dart:async' show TimeoutException;

import 'package:flutter/material.dart' show Scaffold;
import 'package:flutter/services.dart'
    show KeyDownEvent, KeyRepeatEvent, LogicalKeyboardKey;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants/breakpoints.dart';
import '../demo/demo_identity.dart' show kDemoEntryLabel, kDemoMachineName;
import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_adaptive_sheet.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_empty_state.dart';
import '../design/widgets/ab_inline_banner.dart';
import '../design/widgets/ab_loading.dart';
import '../design/widgets/ab_menu.dart';
import '../design/widgets/ab_scrollbar.dart';
import '../design/widgets/ab_separator.dart';
import '../design/widgets/ab_toast.dart';
import '../models/memory.dart';
import '../providers/account_machines.dart';
import '../providers/control_plane.dart'
    show RefreshRef, retryMachineControlPlane;
import '../navigation/nav_controller.dart';
import '../navigation/nav_location.dart';
import '../providers/demo_mode.dart';
import '../providers/memory.dart';
import '../providers/memory_surface.dart';
import '../providers/ui_attention_providers.dart';
import '../services/memory_service.dart';
import '../util/detached.dart';
import '../utils/platform_utils.dart';
import '../widgets/file_download.dart';
import '../widgets/machine_selector_button.dart';
import '../widgets/memory/memory_detail_pane.dart';
import '../widgets/memory/memory_error.dart';
import '../widgets/memory/memory_format.dart';
import '../widgets/memory/memory_header.dart';
import '../widgets/memory/memory_list.dart';
import '../widgets/memory/memory_mutation.dart';
import '../widgets/memory/memory_off_state.dart';
import '../widgets/memory/memory_problems.dart';
import '../widgets/memory/memory_record_details.dart';
import '../widgets/memory/memory_restart_sheet.dart';
import '../widgets/memory/memory_settings_dialog.dart';
import '../widgets/memory/memory_toolbar.dart';

/// A null [target] follows the machine selector. [projectId] presets the
/// Project filter, which is how a project's own entry opens the one
/// machine-wide screen.
void openMemoryScreen(
  BuildContext context,
  MemoryTarget? target, {
  String? projectId,
}) {
  assert(projectId == null || target != null);
  final container = ProviderScope.containerOf(context, listen: false);
  container
      .read(memoryViewProvider.notifier)
      .set(
        target == null
            ? MemoryView.selected()
            : MemoryView(target, projectId: projectId),
      );
  container
      .read(workbenchSurfaceProvider.notifier)
      .set(WorkbenchSurface.memory);
  container
      .read(navControllerProvider.notifier)
      .commit(const NavLocation(surface: WorkbenchSurface.memory));
}

/// The Memory workbench surface, beside the drawer like the Scheduler.
class MemorySurface extends ConsumerWidget {
  const MemorySurface({super.key, this.onOpenDrawer});

  /// Set only where the drawer is an overlay; see [MemoryScreen.onOpenDrawer].
  final VoidCallback? onOpenDrawer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final demo = ref.watch(demoModeProvider);
    final view = ref.watch(memoryViewProvider);
    final target = ref.watch(memoryTargetProvider);
    if (target == null) {
      return _MemoryPlaceholder(
        onOpenDrawer: onOpenDrawer,
        body: ref.watch(machinesSettlingProvider)
            ? const Center(child: AbLoading())
            : AbEmptyState(
                icon: AbIcons.lightbulb,
                title: 'Connect a machine to manage memories',
                subtitle:
                    'Memory lives on your computer, in the Antgrid desktop app. Connect it to read, edit and export what your agents saved.',
                action: AbButton(
                  label: kDemoEntryLabel,
                  onTap: () => enterDemoMemory(ref.container),
                ),
              ),
      );
    }
    final machines = demo
        ? const {kLocalMachineKey: kDemoMachineName}
        : ref.watch(accountMachinesProvider);
    final id = target.machineId ?? kLocalMachineKey;
    final name =
        machines[id] ??
        (target.machineId == null ? kLocalMachineName : 'Remote machine');
    // The offline copy and reconnect handling are remote-only; a local host
    // that is down already surfaces through the status error.
    final connected =
        target.machineId == null ||
        ref.watch(machineConnectedProvider(target.machineId));
    if (view.target == null && isMobilePlatform && target.machineId != null) {
      final pick = ref.watch(machinePickProvider);
      if (pick == null || !machines.containsKey(pick)) {
        // A machine reached for the first time is upserted as the newest
        // recent, which would otherwise retarget this open screen.
        final container = ProviderScope.containerOf(context, listen: false);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (container.read(demoModeProvider)) return;
          final now = container.read(machinePickProvider);
          if (now != null &&
              container.read(accountMachinesProvider).containsKey(now)) {
            return;
          }
          container.read(machinePickProvider.notifier).set(target.machineId);
        });
      }
    }
    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= kMediumBreakpoint;
        final selector = machines.isEmpty
            ? null
            : MachineSelectorButton(
                machines: machines,
                currentId: id,
                name: name,
                connected: connected,
                wide: wide,
                onPicked: (picked) {
                  if (picked == id) return;
                  ref.read(machinePickProvider.notifier).set(picked);
                  ref
                      .read(memoryViewProvider.notifier)
                      .set(MemoryView.selected());
                },
              );
        // A new open remounts, and so does a change of followed machine or a
        // step into or out of the sample. MemoryView compares by identity, so
        // the record changes on every new open as well.
        return MemoryScreen(
          key: ValueKey((view, target.machineId, demo)),
          target: target,
          // The sample is named so its copy never claims to be this device.
          machineName: target.machineId == null && !demo ? null : name,
          connected: connected,
          machineSelector: selector,
          initialProjectId: view.projectId,
          onOpenDrawer: onOpenDrawer,
        );
      },
    );
  }
}

/// The surface's header over a message, for when there is no machine to show.
class _MemoryPlaceholder extends StatelessWidget {
  const _MemoryPlaceholder({this.onOpenDrawer, required this.body});
  final VoidCallback? onOpenDrawer;
  final Widget body;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: context.antgrid.bgDeepest,
    child: LayoutBuilder(
      builder: (context, c) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          c.maxWidth >= kMediumBreakpoint
              ? const MemoryHeader()
              : MemoryHeader.compact(onOpenDrawer: onOpenDrawer),
          Expanded(child: body),
        ],
      ),
    ),
  );
}

class MemoryScreen extends ConsumerStatefulWidget {
  const MemoryScreen({
    super.key,
    required this.target,
    this.machineName,
    this.connected = true,
    this.machineSelector,
    this.initialProjectId,
    this.onOpenDrawer,
  });
  final MemoryTarget target;

  /// Null names the local machine, which keeps the machine-less copy.
  final String? machineName;
  final bool connected;
  final Widget? machineSelector;
  final String? initialProjectId;

  /// The compact header's way to the drawer when the drawer is an overlay,
  /// because the surface itself has no back.
  final VoidCallback? onOpenDrawer;
  @override
  ConsumerState<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends ConsumerState<MemoryScreen>
    with MemoryMutation<MemoryScreen> {
  late MemoryFilter _filter = MemoryFilter(projectId: widget.initialProjectId);
  int _pages = 1;
  String? _selectedId;
  bool _pinned = false;
  bool _exporting = false;
  bool _offlineShown = false;

  // Forgotten ids never return, so the reload that lags a forget cannot
  // resurrect the row as the default selection.
  final Set<String> _forgottenIds = {};

  /// Keys the detail pane so an open edit or confirm never survives a filter
  /// change.
  int _epoch = 0;
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

  @override
  MemoryTarget get mutationTarget => _target;

  @override
  String? get mutationMachineName => widget.machineName;

  @override
  void didUpdateWidget(MemoryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.connected ||
        !widget.connected ||
        _target.machineId == null) {
      return;
    }
    // Post-frame: invalidating a provider during build is an error.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final statusAsync = ref.read(memoryStatusProvider(_target));
      if (statusAsync.hasError) {
        detached('Memory', 'reconnect failed', _retry);
      } else if (_offlineShown) {
        _offlineShown = false;
        ref.invalidate(memoryStatusProvider(_target));
        ref.invalidate(memoryProjectsProvider(_target));
        if (statusAsync.value case final status?) _invalidatePages(status);
      }
      // memoryDetailProvider is left alone: an open edit may be sitting on it.
    });
  }

  /// Every filter change goes through here so paging, pinning and the detail
  /// pane's identity reset together.
  void _setFilter(MemoryFilter next) => setState(() {
    _filter = next;
    _pages = 1;
    _pinned = false;
    _epoch++;
    mutationError = null;
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

  Future<void> _repair({required bool announce}) async {
    final ok = await sendMutation({'op': 'repair'});
    if (ok && announce && mounted) showAbToast(context, 'Search rebuilt');
  }

  Future<void> _turnOn() async {
    setState(() => _offError = null);
    await sendMutation({
      'op': 'settings',
      'enabled': true,
    }, onError: (e) => setState(() => _offError = memoryErrorCopy(e, mutation: true, machine: widget.machineName)));
  }

  Future<void> _reviewSessions(List<MemorySessionWithoutMemory> rows) async {
    await showAbAdaptiveSheet<void>(
      context,
      maxWidth: 560,
      child: MemoryRestartSheet(target: _target, sessions: rows),
    );
    if (mounted) invalidateMemoryViews(ref, _target);
  }

  Future<void> _export({String? projectId}) async {
    if (busy) return;
    final request = ref.read(memoryRequestProvider(_target));
    setState(() {
      busy = true;
      _exporting = true;
      mutationError = null;
    });
    try {
      final bytes = await collectMemoryExport(
        request,
        isActive: () => mounted,
        projectId: projectId,
      );
      if (!mounted || bytes == null) return;
      await downloadFileBytes(
        context,
        name: projectId == null
            ? 'antgrid-memory.json'
            : 'antgrid-memory-$projectId.json',
        mimeType: 'application/json',
        bytes: bytes,
      );
    } catch (error) {
      if (!mounted) return;
      setState(
        () => mutationError = memoryErrorCopy(
          error,
          machine: widget.machineName,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          _exporting = false;
        });
      }
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
    machineName: widget.machineName,
    onExportAll: () => _export(),
  );

  Future<void> _openRecord(String id) async {
    await Navigator.of(context).push<void>(
      PageRouteBuilder<void>(
        pageBuilder: (_, _, _) => MemoryRecordDetails(
          target: _target,
          id: id,
          machineName: widget.machineName,
        ),
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
      if (mutationError case final error?)
        AbInlineBanner(text: error, color: context.antgrid.error),
      Expanded(child: body),
    ],
  );

  List<Widget> _banners(MemoryStatus? status) {
    final name = widget.machineName;
    final offline = status != null && !widget.connected && name != null;
    if (offline) _offlineShown = true;
    final muted = context.antgrid.textMuted;
    return [
      if (offline)
        AbInlineBanner(
          text: memoryOfflineBannerCopy(name),
          color: muted,
        ),
      if (_exporting)
        AbInlineBanner(
          text: name == null
              ? 'Exporting memories…'
              : 'Exporting memories from $name…',
          color: muted,
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final statusAsync = ref.watch(memoryStatusProvider(_target));
    final status = statusAsync.value;
    final banners = _banners(status);
    // The Scaffold is the Material ancestor the search field needs; the
    // surface's host provides the safe area.
    return Scaffold(
      backgroundColor: context.antgrid.bgDeepest,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= kMediumBreakpoint;
          Widget bareHeader() => wide
              ? MemoryHeader(machine: widget.machineSelector)
              : MemoryHeader.compact(
                  onOpenDrawer: widget.onOpenDrawer,
                  machine: widget.machineSelector,
                );
          final Widget body;
          if (status == null) {
            final error = statusAsync.error;
            final code = error == null ? '' : memoryErrorCode(error);
            final offline =
                widget.machineName != null &&
                (!widget.connected || code == 'NOT_CONNECTED');
            // A machine that answered with a refusal is reachable, so offering
            // to reconnect would point at the wrong fix.
            final unreachable =
                _target.machineId != null &&
                (!widget.connected ||
                    error is TimeoutException ||
                    const {
                      'NOT_CONNECTED',
                      'E_TIMEOUT',
                      'TIMEOUT',
                      'TRANSPORT',
                      'TRANSPORT_ERROR',
                    }.contains(code));
            body = statusAsync.isLoading
                ? const Center(child: AbLoading())
                : AbEmptyState.error(
                    title: offline
                        ? '${widget.machineName} is offline'
                        : 'Memory unavailable',
                    subtitle: offline
                        ? 'Open Antgrid on that computer, then reconnect to see its memories.'
                        : memoryErrorCopy(error!, machine: widget.machineName),
                    action: AbButton(
                      label: unreachable ? 'Reconnect and retry' : 'Retry',
                      onTap: () =>
                          detached('Memory', 'reconnect failed', _retry),
                    ),
                  );
          } else if (!status.available) {
            body = AbEmptyState.error(
              title: 'Memory unavailable',
              subtitle:
                  "Memory storage couldn't be opened. Saved memories stay on disk.",
              action: AbButton(
                label: 'Retry store recovery',
                onTap: busy
                    ? null
                    : () => detached(
                        'Memory',
                        'recovery failed',
                        () => _repair(announce: false),
                      ),
              ),
            );
          } else if (!status.enabled) {
            body = MemoryOffState(
              machineName: widget.machineName,
              busy: busy,
              error: _offError,
              onTurnOn: () => detached('Memory', 'enable failed', _turnOn),
            );
          } else {
            return _full(status, wide: wide, banners: banners);
          }
          return _frame(header: bareHeader(), above: banners, body: body);
        },
      ),
    );
  }

  Widget _full(
    MemoryStatus status, {
    required bool wide,
    required List<Widget> banners,
  }) {
    final colors = context.antgrid;
    final projects =
        ref.watch(memoryProjectsProvider(_target)).value ?? MemoryProjects.empty;
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
        _setFilter(_filter.copyWith(query: _search.text));
      });
    }
    _lastWide = wide;

    final projectId = _filter.projectId;
    final projectPaused =
        projectId != null && (projects[projectId]?.paused ?? false);
    final problems = MemoryProblems(
      status: status,
      busy: busy,
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
      onReviewSessions: () => detached(
        'Memory',
        'review sessions failed',
        () => _reviewSessions(status.sessionsWithoutMemory),
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

    final toolbar = MemoryToolbar(
      compact: !wide,
      filter: _filter,
      projects: projects,
      searchReady: status.searchReady,
      searchController: _search,
      searchFocus: _searchFocus,
      onChanged: _setFilter,
      countLine: wide || total == null
          ? null
          : '${memoryCountLabel(total)}  ·  ${memoryStatusWord(status, projectPaused: projectPaused).word.toLowerCase()}',
    );

    if (!wide) {
      return _frame(
        header: MemoryHeader.compact(
          onOpenDrawer: widget.onOpenDrawer,
          machine: widget.machineSelector,
          onSettings: () =>
              detached('Memory', 'settings failed', _openSettings),
          onMore: (anchor) =>
              detached('Memory', 'menu failed', () => _openMore(anchor)),
        ),
        above: [...banners, problems, toolbar],
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
            machine: widget.machineSelector,
            status: status,
            projectPaused: projectPaused,
            onSettings: () =>
                detached('Memory', 'settings failed', _openSettings),
            onMore: (anchor) =>
                detached('Memory', 'menu failed', () => _openMore(anchor)),
          ),
          above: [...banners, problems, toolbar],
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
