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
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_loading.dart';
import '../design/widgets/ab_search_field.dart';
import '../design/widgets/ab_separator.dart';
import '../design/widgets/ab_toolbar.dart';

/// The main file explorer screen with an inline search panel that can be
/// toggled via a search icon. When search is inactive, shows the file tree.
/// When active, search input + results replace the tree.
class FileExplorerScreen extends ConsumerStatefulWidget {
  const FileExplorerScreen({super.key});

  @override
  ConsumerState<FileExplorerScreen> createState() => _FileExplorerScreenState();
}

class _FileExplorerScreenState extends ConsumerState<FileExplorerScreen> {
  bool _searchOpen = false;

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
    final treeStateAsync = ref.watch(fileTreeStateProvider);
    // watch, not the `ref.read` in [_onScreen]: the registered `active` flags
    // below have to be recomputed when this tab goes on or off screen.
    final onScreen =
        ref.watch(visibleWorkspaceViewProvider) == WorkspaceView.files;

    return BackHandler(
      priority: BackPriority.fileViewer,
      active: onScreen && treeStateAsync.value?.files.selectedFilePath != null,
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

  const _FileExplorerBody({
    required this.state,
    required this.fileService,
    required this.searchOpen,
    required this.onToggleSearch,
    required this.onCloseSearch,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
      trailing: [
        AbIconButton(
          icon: AbIcons.refresh,
          onTap: () => fileService.requestFullTree(),
          tooltip: 'Refresh',
        ),
        AbIconButton(
          icon: AbIcons.search,
          tone: searchOpen ? AbIconButtonTone.accent : AbIconButtonTone.normal,
          onTap: onToggleSearch,
          tooltip: 'Search in files',
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
    return RefreshIndicator(
      onRefresh: () async {
        fileService.requestFullTree();
        await Future.delayed(const Duration(milliseconds: 500));
      },
      child: FileTreeView(
        root: state.root,
        expandedPaths: state.expandedPaths,
        selectedFilePath: state.files.selectedFilePath,
        filterQuery: null,
        onToggleExpanded: (path) => fileService.toggleExpanded(path),
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

/// The search panel content, extracted to manage its own TextField controller.
class _SearchPanel extends StatefulWidget {
  final SearchState searchState;
  final SearchService searchService;
  final void Function(String path, int line, int column) onMatchTap;
  final VoidCallback onClose;

  const _SearchPanel({
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
