import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../analytics/events.dart';
import '../models/file_tree_models.dart';
import '../navigation/back_intent.dart';
import '../providers/agent_transport.dart';
import '../providers/analytics.dart';
import '../providers/providers.dart';
import '../providers/sessions.dart';
import '../providers/visible_surface.dart';
import '../widgets/workspace_tab_bar.dart';
import '../services/file_service.dart';
import '../services/tree_interest.dart';
import '../providers/ui_attention_providers.dart';
import '../constants/breakpoints.dart';
import '../widgets/file_tree_view.dart';
import '../widgets/file_viewer_router.dart';
import '../widgets/search_result_list.dart';
import '../models/search_models.dart';
import '../services/search_service.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/ab_colors.dart';
import '../design/widgets/ab_chip.dart';
import '../design/widgets/ab_empty_state.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_list_row.dart';
import '../design/widgets/ab_loading.dart';
import '../design/widgets/ab_search_field.dart';
import '../design/widgets/ab_separator.dart';
import '../design/widgets/ab_toolbar.dart';
import '../keyboard/app_command_registry.dart';
import '../keyboard/app_shortcuts.dart';
import '../util/detached.dart';
import '../widgets/file_search_bar.dart';

/// The main file explorer screen with an inline search panel that can be
/// toggled via a search icon. When search is inactive, shows the file tree.
/// When active, search input + results replace the tree.
class FileExplorerScreen extends ConsumerStatefulWidget {
  const FileExplorerScreen({super.key});

  @override
  ConsumerState<FileExplorerScreen> createState() => _FileExplorerScreenState();
}

class _FileExplorerScreenState extends ConsumerState<FileExplorerScreen> {
  final _treeInterest = TreeInterest();
  final _filterFocus = FocusNode(debugLabel: 'file-filter');
  final _searchPanelKey = GlobalKey<_SearchPanelState>();

  @override
  void dispose() {
    _treeInterest.dispose();
    _filterFocus.dispose();
    super.dispose();
  }

  void _revealFiles() =>
      ref.read(workspaceMenuControlProvider)?.reveal(WorkspaceView.files);

  /// [AppCommand.goToFile]: the tree's name filter, taking the keyboard. In the
  /// compact layout an open file replaces the tree, filter and all, so the file
  /// is closed first — the chord names the tree, so it has to be on screen.
  void _goToFile() {
    _revealFiles();
    if (_searchOpen) setState(() => _searchOpen = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_filterFocus.context != null) {
        _filterFocus.requestFocus();
        return;
      }
      focusedCheckoutServiceOrNull(
        ref.container,
        (s) => s.fileService,
      )?.clearViewingFile();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _filterFocus.requestFocus();
      });
    });
  }

  /// [AppCommand.searchInFiles]: opens the content search, or puts the
  /// keyboard back in its field when it is already open. A freshly opened
  /// panel focuses itself.
  void _searchInFiles() {
    _revealFiles();
    if (!_searchOpen) {
      setState(() => _searchOpen = true);
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchPanelKey.currentState?.focusField();
    });
  }

  bool _searchOpen = false;

  // The tree's name filter (D-A1: a real filter box, backed by `file:find`,
  // reading the tree's OWN includeIgnored setting rather than a constant —
  // A5's amendment — because it filters the tree and must keep agreeing with
  // what the tree shows even after the "Hide git-ignored files" override
  // flips it. Null/empty means "browsing normally"; anything else swaps the
  // tree for a flat, bridge-ranked results list. Lives here rather than in
  // [_FileExplorerBody] because that widget is stateless (a plain
  // [ConsumerWidget]) and a debounced async search needs somewhere to keep
  // its in-flight generation.
  String? _filterQuery;
  List<FileFindEntry> _filterResults = const [];
  bool _filterLoading = false;
  String? _filterError;
  int _filterGen = 0;

  /// Stops this surface's spinner when the reply it was waiting for will
  /// never arrive. Guarded on the generation so a stale closure cannot clear
  /// the flag a newer keystroke just set.
  void _endFilterWait(int gen, {String? error}) {
    if (!mounted || gen != _filterGen) return;
    setState(() {
      _filterLoading = false;
      _filterError = error;
    });
  }

  void _onFilterQueryChanged(String? query) {
    final active = query != null && query.isNotEmpty;
    setState(() {
      _filterQuery = query;
      _filterResults = const [];
      _filterError = null;
      _filterLoading = active;
    });
    if (!active) return;
    final gen = ++_filterGen;
    detached('FileExplorerScreen', 'filter files by name', () async {
      // Resolved fresh rather than captured from build(): this runs outside
      // it, and the façade throws while the focused project's session is
      // unresolved (see focusedCheckoutServiceOrNull's doc).
      final fileService = focusedCheckoutServiceOrNull(
        ref.container,
        (s) => s.fileService,
      );
      if (fileService == null) {
        _endFilterWait(gen);
        return;
      }
      FileFindResultMessage result;
      try {
        // Tracks the tree's effective setting — unlike the @-mention path
        // (agent_transcript_view.dart), which always passes false and is
        // deliberately not downstream of this toggle.
        result = await fileService.find(
          query,
          includeIgnored: fileService.includeIgnoredInTree,
        );
      } on FileFindSuperseded {
        // NOT always a keystroke of our own: the @-mention panel resolves the
        // same FileService, [FileService.find] keeps one wanted call for the
        // whole service, and both surfaces are mounted at once on desktop. A
        // bare return left this spinner up for good when the composer was the
        // one that superseded us.
        _endFilterWait(gen);
        return;
      } catch (_) {
        _endFilterWait(gen, error: 'Search failed');
        return;
      }
      if (!mounted || gen != _filterGen) return;
      setState(() {
        _filterResults = result.entries;
        _filterLoading = false;
        // A killed or timed-out listing also answers with zero entries —
        // without this it reads as "this file does not exist".
        _filterError = result.error;
      });
    });
  }

  @override
  void initState() {
    super.initState();
    // Fire once when the explorer UI actually mounts — not in the
    // ProjectSession constructor, which runs for every warmed/background
    // session the user never views.
    ref
        .read(analyticsServiceProvider)
        ?.track(AnalyticsEvents.fileExplorerOpened);
  }

  @override
  Widget build(BuildContext context) {
    final fileService = serviceWhenReady(ref, fileServiceProvider);
    // Read BEFORE the lease below, and that order is load-bearing: taking the
    // lease registers the tree hydrator, which on an established transport
    // fires its root request immediately. `fileTreeStateProvider`'s build is
    // what applies the "Hide git-ignored files" setting to this FileService,
    // so a lease taken first sends that request under the wrong flag and the
    // setting then re-lists the whole tree to correct it.
    final treeStateAsync = ref.watch(fileTreeStateProvider);
    _treeInterest.update(
      fileService,
      ref.watch(visibleWorkspaceViewProvider) == WorkspaceView.files &&
          ref.watch(appLifecycleStateProvider) == AppLifecycleState.resumed,
    );
    // Watched rather than listened to, because this is also the retry trigger:
    // a launch-time link reaches this screen before the project's FileService
    // exists, and the rebuild that finally lands the service is the frame the
    // drain has to run on. Deferred a frame so neither the clear nor the
    // selection writes provider state during build.
    final pendingFilePath = ref.watch(pendingFilePathProvider);
    if (fileService != null && pendingFilePath != null && _checkoutSettled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _drainPendingFilePath();
      });
    }
    if (fileService == null) {
      return const AbLoading(message: 'loading files...');
    }
    // watch, not the `ref.read` in [_onScreen]: the registered `active` flags
    // below have to be recomputed when this tab goes on or off screen.
    final onScreen =
        ref.watch(visibleWorkspaceViewProvider) == WorkspaceView.files;

    return AppCommandHandlers(
      handlers: {
        AppCommand.goToFile: _goToFile,
        AppCommand.searchInFiles: _searchInFiles,
      },
      child: BackHandler(
        priority: BackPriority.fileViewer,
        active:
            onScreen && treeStateAsync.value?.files.selectedFilePath != null,
        onBack: _backFromViewer,
        child: BackHandler(
          priority: BackPriority.fileSearch,
          active: onScreen && _searchOpen,
          onBack: _backFromSearch,
          child: treeStateAsync.when(
            loading: () => const AbLoading(message: 'loading files...'),
            error: (error, _) =>
                AbEmptyState.error(title: 'Error loading files: $error'),
            data: (state) => _FileExplorerBody(
              state: state,
              fileService: fileService,
              searchOpen: _searchOpen,
              onToggleSearch: () => setState(() => _searchOpen = !_searchOpen),
              onCloseSearch: () => setState(() => _searchOpen = false),
              filterQuery: _filterQuery,
              filterResults: _filterResults,
              filterLoading: _filterLoading,
              filterError: _filterError,
              onFilterQueryChanged: _onFilterQueryChanged,
              filterFocus: _filterFocus,
              searchPanelKey: _searchPanelKey,
            ),
          ),
        ),
      ),
    );
  }

  /// Whether [focusedCheckoutIdProvider] can be believed yet.
  ///
  /// It derives the checkout from the ACTIVE SESSION, and answers `main` both
  /// while the project's session list is still in flight and while a session id
  /// a navigation asked for is still queued for `_bootstrapSessions`. Draining
  /// in either window opens the path in the project's main tree — the one thing
  /// a checkout-relative path must never do. Watched in `build`, so the frame
  /// that settles the session is also the retry.
  bool get _checkoutSettled =>
      ref.watch(freshSessionsStateProvider) != null &&
      ref.watch(pendingActiveSessionIdProvider) == null;

  /// Open the file a navigation left in [pendingFilePathProvider], and clear it
  /// so a later rebuild cannot replay a spent link.
  ///
  /// The service is re-resolved here rather than captured from `build()`: this
  /// runs a frame later, and a project switch in between disposes the service
  /// that build saw. Resolving it through [focusedCheckoutServiceOrNull] is
  /// also what makes the path checkout-scoped — an isolated session opens the
  /// file in its own worktree, not in the project's main tree. An unresolved
  /// session leaves the path pending instead of dropping it, so the rebuild
  /// that lands the session still honours the link; a path stamped for another
  /// project is spent unopened, since this explorer is not its destination.
  void _drainPendingFilePath() {
    final pending = ref.read(pendingFilePathProvider);
    if (pending == null) return;
    if (pending.target != ref.read(selectedTargetProvider)) {
      ref.read(pendingFilePathProvider.notifier).set(null);
      return;
    }
    // Re-checked a frame later for the same reason the service is: a session
    // switch in between puts the checkout back in flight, and the path stays
    // pending rather than landing in the wrong tree.
    if (ref.read(freshSessionsStateProvider) == null ||
        ref.read(pendingActiveSessionIdProvider) != null) {
      return;
    }
    final service = focusedCheckoutServiceOrNull(
      ref.container,
      (s) => s.fileService,
    );
    if (service == null) return;
    ref.read(pendingFilePathProvider.notifier).set(null);
    service.selectFile(pending.value);
  }

  bool get _onScreen =>
      ref.read(visibleWorkspaceViewProvider) == WorkspaceView.files;

  bool _backFromViewer() {
    if (!_onScreen) return false;
    if (ref.read(fileTreeStateProvider).value?.files.selectedFilePath == null) {
      return false;
    }
    // The façade throws while the focused project's session is unresolved, and
    // this runs outside build(): decline the press rather than take the app
    // down (see focusedCheckoutServiceOrNull). Checkout-scoped like the rest of
    // this screen — the main-checkout façade would clear the viewing file of a
    // tree that is not the one on screen in an isolated session.
    final service = focusedCheckoutServiceOrNull(
      ref.container,
      (s) => s.fileService,
    );
    if (service == null) return false;
    service.clearViewingFile();
    return true;
  }

  bool _backFromSearch() {
    if (!_onScreen || !_searchOpen) return false;
    setState(() => _searchOpen = false);
    return true;
  }
}

class _FileExplorerBody extends ConsumerWidget {
  final FileTreeState state;
  final FileService fileService;
  final bool searchOpen;
  final VoidCallback onToggleSearch;
  final VoidCallback onCloseSearch;
  final String? filterQuery;
  final List<FileFindEntry> filterResults;
  final bool filterLoading;
  final String? filterError;
  final void Function(String?) onFilterQueryChanged;
  final FocusNode filterFocus;
  final GlobalKey<_SearchPanelState> searchPanelKey;

  const _FileExplorerBody({
    required this.state,
    required this.fileService,
    required this.searchOpen,
    required this.onToggleSearch,
    required this.onCloseSearch,
    required this.filterQuery,
    required this.filterResults,
    required this.filterLoading,
    required this.filterError,
    required this.onFilterQueryChanged,
    required this.filterFocus,
    required this.searchPanelKey,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return CallbackShortcuts(
      bindings: localShortcutBindings({
        AppCommand.refresh: fileService.requestFullTree,
      }),
      child: _buildLayout(context, ref),
    );
  }

  Widget _buildLayout(BuildContext context, WidgetRef ref) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final showSideBySide = constraints.maxWidth >= kCompactBreakpoint;

        if (showSideBySide) {
          return _buildSideBySideLayout(context, ref);
        }

        // Compact: show viewer full-width when file selected
        if (state.files.selectedFilePath != null) {
          return _buildViewerPage(context);
        }
        return _buildTreePanel(context, ref);
      },
    );
  }

  Widget _buildActionBar(BuildContext context) {
    return AbToolbar.actions(
      // The filter shares this row rather than taking one of its own beneath
      // it: stacked, the two put a pair of magnifiers directly above each
      // other, one filtering names and one searching contents. Dropped while
      // the content-search panel is open — that panel carries its own field,
      // and the tree this one filters is not on screen behind it.
      center: searchOpen
          ? null
          : FileSearchBar(
              focusNode: filterFocus,
              currentQuery: filterQuery,
              // Zero here on purpose: [FileService.find] debounces already,
              // and stacking the two put the first request ~550ms after the
              // last keystroke while the @-mention panel paid only 250ms for
              // the same search.
              debounce: Duration.zero,
              onQueryChanged: onFilterQueryChanged,
            ),
      trailing: [
        AbIconButton(
          icon: AbIcons.refresh,
          onTap: () => fileService.requestFullTree(),
          tooltip: withShortcut('Refresh', AppCommand.refresh),
        ),
        AbIconButton(
          icon: AbIcons.search,
          tone: searchOpen ? AbIconButtonTone.accent : AbIconButtonTone.normal,
          onTap: onToggleSearch,
          tooltip: withShortcut('Search in files', AppCommand.searchInFiles),
        ),
      ],
    );
  }

  Widget _buildTreePanel(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        _buildActionBar(context),
        Expanded(
          child: searchOpen
              ? _buildSearchContent(context, ref)
              : _buildBrowseContent(context),
        ),
      ],
    );
  }

  Widget _buildSearchContent(BuildContext context, WidgetRef ref) {
    final stateAsync = ref.watch(searchStateProvider);
    // Gate on readiness here too, not just in the parent's build: this body is
    // its own consumer, so Riverpod may rebuild it against a session the parent
    // hasn't yet re-gated on — and the façade throws once that session is gone.
    final searchService = serviceWhenReady(ref, searchServiceProvider);
    if (searchService == null) return const AbLoading();

    return stateAsync.when(
      loading: () => const AbLoading(),
      error: (error, _) => Center(child: Text('Error: $error')),
      data: (searchState) => _SearchPanel(
        key: searchPanelKey,
        searchState: searchState,
        searchService: searchService,
        onMatchTap: (path, line, column) {
          fileService.selectFile(
            path,
            searchLine: line,
            searchQuery: searchService.currentState.query,
          );
        },
        onClose: onCloseSearch,
      ),
    );
  }

  Widget _buildBrowseContent(BuildContext context) {
    final filtering = filterQuery != null && filterQuery!.isNotEmpty;
    return filtering
        ? _FileFilterResults(
            entries: filterResults,
            loading: filterLoading,
            error: filterError,
            onTapFile: (path) {
              fileService.selectFile(path);
              onFilterQueryChanged(null);
            },
            onTapDirectory: (path) {
              detached(
                'FileExplorerScreen',
                'reveal filtered directory',
                () => fileService.revealDirectory(path),
              );
              onFilterQueryChanged(null);
            },
          )
        : RefreshIndicator(
            onRefresh: () async {
              fileService.requestFullTree();
              await Future.delayed(const Duration(milliseconds: 500));
            },
            child: FileTreeView(
              root: state.root,
              expandedPaths: state.expandedPaths,
              selectedFilePath: state.files.selectedFilePath,
              onToggleExpanded: (path) => detached(
                'FileExplorerScreen',
                'expand folder',
                () => fileService.toggleExpanded(path),
              ),
              onFileSelected: (path) => fileService.selectFile(path),
            ),
          );
  }

  void _goBackFromViewer() {
    fileService.clearViewingFile();
  }

  Widget _buildContentArea() {
    final files = state.files;
    final hasContent = files.selectedFilePath != null;
    final child = _buildContentAreaInner();

    if (!hasContent) return child;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _goBackFromViewer,
      },
      child: Focus(child: child),
    );
  }

  Widget _buildContentAreaInner() {
    final files = state.files;
    if (files.selectedFilePath != null) {
      return FileViewerRouter(
        fileContent: files.viewingFile,
        isLoading: files.isLoading,
        selectedFilePath: files.selectedFilePath,
        fileWasModified: files.fileModifiedExternally,
        searchLine: files.searchLine,
        searchQuery: files.searchQuery,
        onRefreshContent: () =>
            fileService.requestFileContent(files.selectedFilePath!),
        onClose: () => fileService.clearViewingFile(),
        onOpenFile: (path) => fileService.selectFile(path),
      );
    }

    return const AbEmptyState.compact(title: 'Select a file to view');
  }

  Widget _buildSideBySideLayout(BuildContext context, WidgetRef ref) {
    return Row(
      children: [
        SizedBox(width: 280, child: _buildTreePanel(context, ref)),
        const AbSeparator.vertical(weight: AbSeparatorWeight.strong),
        Expanded(child: _buildContentArea()),
      ],
    );
  }

  Widget _buildViewerPage(BuildContext context) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AbTokens.space4,
            vertical: AbTokens.space2,
          ),
          child: Row(
            children: [
              AbIconButton(
                icon: AbIcons.back,
                onTap: () => fileService.clearViewingFile(),
                tooltip: 'Back to file tree',
              ),
              const SizedBox(width: AbTokens.space4),
              const Text(
                'File Explorer',
                style: TextStyle(
                  fontSize: AbTokens.fontBody,
                  color: Colors.grey,
                ),
              ),
            ],
          ),
        ),
        Expanded(child: _buildContentArea()),
      ],
    );
  }
}

/// Flat, bridge-ranked results for the tree's name filter — `file:find`
/// returns files and directories interleaved by relevance (basename match
/// first, then path-only, then shallow-first), not nested, so this renders a
/// flat list rather than reusing [FileTreeView]'s expand/collapse rows.
class _FileFilterResults extends StatelessWidget {
  final List<FileFindEntry> entries;
  final bool loading;
  final String? error;
  final void Function(String path) onTapFile;
  final void Function(String path) onTapDirectory;

  const _FileFilterResults({
    required this.entries,
    required this.loading,
    required this.error,
    required this.onTapFile,
    required this.onTapDirectory,
  });

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      // A failed listing and a genuine zero-match one both arrive as an empty
      // list; rendering them alike had the user retrying a search that broke.
      final failure = error;
      if (failure != null && !loading) {
        return AbEmptyState.error(title: 'Search failed: $failure');
      }
      return AbEmptyState(
        icon: AbIcons.search,
        title: loading ? 'Searching…' : 'No matching files',
      );
    }
    return ListView.builder(
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        return AbListRow(
          density: AbRowDensity.sm,
          onTap: entry.isDir
              ? () => onTapDirectory(entry.path)
              : () => onTapFile(entry.path),
          leading: entry.isDir
              ? AbIcon(
                  AbIcons.folder,
                  size: AbTokens.fontSm,
                  color: context.antgrid.textMuted,
                )
              : const SizedBox(width: AbTokens.fontSm),
          title: Text(
            entry.path,
            style: AbTokens.monoStyle(
              fontSize: AbTokens.fontSm,
              // Same token the tree dims an ignored row with — this list
              // stands in for the tree while a query is active, so the two
              // must agree about what a path is.
              color: entry.ignored
                  ? context.antgrid.textMuted
                  : context.antgrid.textPrimary,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        );
      },
    );
  }
}

/// The search panel content, extracted to manage its own TextField controller.
class _SearchPanel extends StatefulWidget {
  final SearchState searchState;
  final SearchService searchService;
  final void Function(String path, int line, int column) onMatchTap;
  final VoidCallback onClose;

  const _SearchPanel({
    super.key,
    required this.searchState,
    required this.searchService,
    required this.onMatchTap,
    required this.onClose,
  });

  @override
  State<_SearchPanel> createState() => _SearchPanelState();
}

class _SearchPanelState extends State<_SearchPanel> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.searchState.query);
    _focusNode = FocusNode(
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          widget.onClose();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
    );
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void focusField() {
    _focusNode.requestFocus();
    _controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _controller.text.length,
    );
  }

  void _onQueryChanged(String value) {
    widget.searchService.search(value);
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.searchState;
    final searchService = widget.searchService;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AbTokens.space8,
            AbTokens.space6,
            AbTokens.space8,
            3,
          ), // 3px non-ladder bottom for tighter feel
          child: AbSearchField(
            controller: _controller,
            focusNode: _focusNode,
            hint: 'Search in files...',
            height: AbTokens.rowHeightXs,
            autofocus: true,
            debounce: const Duration(milliseconds: 400),
            onChanged: _onQueryChanged,
          ),
        ),
        // Options row
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AbTokens.space8,
            vertical: 1,
          ), // 1px row inset
          child: Row(
            children: [
              Tooltip(
                message: 'Case Sensitive',
                child: AbChip.toggle(
                  label: 'Aa',
                  selected: state.caseSensitive,
                  onTap: searchService.toggleCaseSensitive,
                ),
              ),
              // 3px: tighter than space4, deliberately compact between toggle chips.
              const SizedBox(width: 3),
              Tooltip(
                message: 'Regex',
                child: AbChip.toggle(
                  label: '.*',
                  selected: state.regex,
                  onTap: searchService.toggleRegex,
                ),
              ),
              // 3px: tighter than space4, deliberately compact between toggle chips.
              const SizedBox(width: 3),
              Tooltip(
                message: 'Whole Word',
                child: AbChip.toggle(
                  label: 'W',
                  selected: state.wholeWord,
                  onTap: searchService.toggleWholeWord,
                ),
              ),
              const Spacer(),
              if (state.isSearching)
                AbLoadingDot(size: 12, color: context.antgrid.accent)
              else if (state.query.isNotEmpty)
                Flexible(
                  child: Text(
                    state.error ??
                        '${state.totalMatches} in ${state.totalFiles} files',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: state.error != null
                          ? colorScheme.error
                          : colorScheme.onSurfaceVariant,
                      fontSize: AbTokens.fontXxs,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
        ),
        const AbSeparator.horizontal(),
        Expanded(
          child: state.query.isEmpty
              ? const AbEmptyState.compact(title: 'Search across all files')
              : state.results.isEmpty && !state.isSearching
              ? AbEmptyState.compact(title: 'No results for "${state.query}"')
              : SearchResultList(
                  results: state.results,
                  query: state.query,
                  isRegex: state.regex,
                  caseSensitive: state.caseSensitive,
                  onMatchTap: widget.onMatchTap,
                ),
        ),
      ],
    );
  }
}
