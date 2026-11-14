import 'dart:async';

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
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
import '../design/ab_carbon.dart';
import '../util/detached.dart';
import '../util/external_url.dart';
import '../widgets/carbon_empty_state.dart';
import '../widgets/file_search_bar.dart';
import '../widgets/git_change_list.dart' show CarbonPullToRefresh;
import '../widgets/ab_status_helpers.dart' show caughtErrorCopy;

/// The main file explorer screen with an inline search panel that can be
/// toggled via a search icon. When search is inactive, shows the file tree.
/// When active, search input + results replace the tree.
///
/// One [AbCarbonScope] at the root, for the tree, the search panel and the file
/// viewers beside them, so the surface never changes theme as data arrives.
class FileExplorerScreen extends ConsumerStatefulWidget {
  const FileExplorerScreen({super.key});

  @override
  ConsumerState<FileExplorerScreen> createState() => _FileExplorerScreenState();
}

class _FileExplorerScreenState extends ConsumerState<FileExplorerScreen> {
  final _treeInterest = TreeInterest();
  @override
  void dispose() {
    _treeInterest.dispose();
    super.dispose();
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
    // watch, not the `ref.read` in [_onScreen]: the registered `active` flags
    // below have to be recomputed when this tab goes on or off screen.
    final onScreen =
        ref.watch(visibleWorkspaceViewProvider) == WorkspaceView.files;
    _treeInterest.update(
      fileService,
      onScreen &&
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
    final Widget content;
    if (fileService == null) {
      content = const CarbonLoading(message: 'loading files...');
    } else {
      content = BackHandler(
        priority: BackPriority.fileViewer,
        active:
            onScreen && treeStateAsync.value?.files.selectedFilePath != null,
        onBack: _backFromViewer,
        child: BackHandler(
          priority: BackPriority.fileSearch,
          active: onScreen && _searchOpen,
          onBack: _backFromSearch,
          child: treeStateAsync.when(
            loading: () => const CarbonLoading(message: 'loading files...'),
            error: (error, _) => CarbonEmptyState(
              error: true,
              heading: "Couldn't load files",
              body: caughtErrorCopy(error, 'Try again in a moment.'),
            ),
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
            ),
          ),
        ),
      );
    }
    return AbCarbonScope(
      child: Builder(
        builder: (context) => ColoredBox(
          color: CarbonTheme.of(context).colors.background,
          // IndexedStack keeps this screen mounted while another workspace
          // view is up, and a spinner would keep ticking unseen.
          child: TickerMode(enabled: onScreen, child: content),
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
    return _Toolbar(
      children: [
        // The filter shares this row rather than taking one of its own beneath
        // it: stacked, the two put a pair of magnifiers directly above each
        // other, one filtering names and one searching contents. Dropped while
        // the content-search panel is open — that panel carries its own field,
        // and the tree this one filters is not on screen behind it.
        Expanded(
          child: searchOpen
              ? const SizedBox.shrink()
              : FileSearchBar(
                  currentQuery: filterQuery,
                  onQueryChanged: onFilterQueryChanged,
                ),
        ),
        _ToolbarButton(
          icon: CarbonIcons.renew,
          label: 'Refresh',
          onPressed: () => fileService.requestFullTree(),
        ),
        _ToolbarButton(
          icon: CarbonIcons.search,
          label: 'Search in files',
          selected: searchOpen,
          onPressed: onToggleSearch,
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
    if (searchService == null) return const CarbonLoading();

    return stateAsync.when(
      loading: () => const CarbonLoading(),
      error: (error, _) => CarbonEmptyState(
        error: true,
        heading: 'Search failed',
        body: caughtErrorCopy(error, 'Try again in a moment.'),
      ),
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
        : CarbonPullToRefresh(
            onRefresh: () async {
              fileService.requestFullTree();
              await Future.delayed(const Duration(milliseconds: 500));
            },
            child: FileTreeView(
              root: state.root,
              expandedPaths: state.expandedPaths,
              selectedFilePath: state.files.selectedFilePath,
              revealedDirectoryPath: state.files.revealedDirectoryPath,
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

  Widget _buildContentArea(BuildContext context) {
    final files = state.files;
    final hasContent = files.selectedFilePath != null;
    final child = _buildContentAreaInner(context);

    if (!hasContent) return child;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _goBackFromViewer,
      },
      child: Focus(child: child),
    );
  }

  Widget _buildContentAreaInner(BuildContext context) {
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
        onOpenLocalPath: (path, repoFallback) => detached(
          'FileExplorer',
          'open markdown path link',
          () => openMarkdownLocalPath(
            context,
            path,
            fileService: () => fileService,
            repoFallback: repoFallback,
          ),
        ),
      );
    }

    return const CarbonEmptyState(
      icon: CarbonIcons.document,
      heading: 'Select a file to view',
    );
  }

  Widget _buildSideBySideLayout(BuildContext context, WidgetRef ref) {
    final theme = CarbonTheme.of(context);
    return Row(
      children: [
        SizedBox(width: 280, child: _buildTreePanel(context, ref)),
        SizedBox(
          width: CarbonBorders.hairline,
          child: ColoredBox(
            color: theme.borderStrong(CarbonLayer.of(context)),
          ),
        ),
        Expanded(child: _buildContentArea(context)),
      ],
    );
  }

  Widget _buildViewerPage(BuildContext context) {
    final theme = CarbonTheme.of(context);
    return Column(
      children: [
        _Toolbar(
          children: [
            _ToolbarButton(
              icon: CarbonIcons.arrowLeft,
              label: 'Back to file tree',
              onPressed: () => fileService.clearViewingFile(),
            ),
            Expanded(
              child: Text(
                'File Explorer',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.typography.control.copyWith(
                  color: theme.colors.textSecondary,
                ),
              ),
            ),
          ],
        ),
        Expanded(child: _buildContentArea(context)),
      ],
    );
  }
}

/// The action row above the tree: a layer-coloured strip with a hairline under
/// it, whose controls sit one layer up.
class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CarbonLayerSurface(
          padding: const EdgeInsets.symmetric(
            horizontal: CarbonSpacing.spacing03,
            vertical: CarbonSpacing.spacing02,
          ),
          child: Row(spacing: CarbonSpacing.spacing02, children: children),
        ),
        SizedBox(
          height: CarbonBorders.hairline,
          child: ColoredBox(color: theme.borderSubtle(CarbonLayer.of(context))),
        ),
      ],
    );
  }
}

/// A ghost icon-only button with its name in a tooltip. [selected] makes it a
/// toggle that shows its state; null is a plain action.
class _ToolbarButton extends StatelessWidget {
  const _ToolbarButton({
    this.icon,
    this.glyph,
    required this.label,
    this.selected,
    required this.onPressed,
  }) : assert(icon != null || glyph != null);

  final CarbonIcons? icon;

  /// Text standing in for an icon Carbon does not have.
  final String? glyph;
  final String label;
  final bool? selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final glyph = this.glyph;
    final icon = this.icon;
    return CarbonButton.iconOnly(
      icon: glyph != null
          ? Builder(
              builder: (context) => Text(
                glyph,
                style: CarbonTheme.of(context).typography.code.copyWith(
                  color: IconTheme.of(context).color,
                  fontWeight: FontWeight.w600,
                ),
              ),
            )
          : CarbonIcon(icon!),
      semanticLabel: label,
      size: CarbonButtonSize.small,
      selected: selected,
      onPressed: onPressed,
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
        return CarbonEmptyState(error: true, heading: 'Search failed: $failure');
      }
      return CarbonEmptyState(
        icon: loading ? null : CarbonIcons.search,
        iconWidget: loading
            ? const CarbonSpinner(size: CarbonSpacing.spacing07)
            : null,
        heading: loading ? 'Searching…' : 'No matching files',
      );
    }
    return CarbonTreeView(
      semanticLabel: 'Matching files',
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        return CarbonTreeNodeData(
          id: (entry.isDir, entry.path),
          label: entry.path,
          leading: entry.isDir ? const CarbonIcon(CarbonIcons.folder) : null,
          content: _PathLabel(path: entry.path, ignored: entry.ignored),
        );
      },
      onActivate: (id) {
        if (id case (final bool isDir, final String path)) {
          isDir ? onTapDirectory(path) : onTapFile(path);
        }
      },
    );
  }
}

/// A path in the mono face, dimmed when git ignores it. Same dim the tree
/// gives an ignored row — this list stands in for the tree while a query is
/// active, so the two must agree about what a path is.
class _PathLabel extends StatelessWidget {
  const _PathLabel({required this.path, required this.ignored});

  final String path;
  final bool ignored;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final inherited = DefaultTextStyle.of(context).style;
    return Text(
      path,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: theme.typography.code.copyWith(
        color: ignored ? theme.colors.textPlaceholder : inherited.color,
      ),
    );
  }
}

/// The search panel content, extracted to manage its own text controller.
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
  // Carbon's search never debounces, and a content search walks the whole
  // checkout.
  static const _searchDebounce = Duration(milliseconds: 400);

  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.searchState.query);
    // Sits on the field's own focus node, so it answers before the search
    // field's clear-first Escape does: one press closes the panel.
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
    _debounce?.cancel();
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(_searchDebounce, () => widget.searchService.search(value));
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.searchState;
    final searchService = widget.searchService;
    final theme = CarbonTheme.of(context);
    final error = state.error;

    return Column(
      children: [
        CarbonLayerSurface(
          padding: const EdgeInsets.all(CarbonSpacing.spacing03),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: CarbonSpacing.spacing02,
            children: [
              CarbonSearch(
                controller: _controller,
                focusNode: _focusNode,
                placeholder: 'Search in files...',
                semanticLabel: 'Search in files',
                size: CarbonFieldSize.small,
                autofocus: true,
                busy: state.isSearching,
                onChanged: _onQueryChanged,
              ),
              Row(
                spacing: CarbonSpacing.spacing02,
                children: [
                  _ToolbarButton(
                    icon: CarbonIcons.letterAa,
                    label: 'Case Sensitive',
                    selected: state.caseSensitive,
                    onPressed: searchService.toggleCaseSensitive,
                  ),
                  _ToolbarButton(
                    glyph: '.*',
                    label: 'Regex',
                    selected: state.regex,
                    onPressed: searchService.toggleRegex,
                  ),
                  _ToolbarButton(
                    icon: CarbonIcons.stringText,
                    label: 'Whole Word',
                    selected: state.wholeWord,
                    onPressed: searchService.toggleWholeWord,
                  ),
                  const Spacer(),
                  if (!state.isSearching && state.query.isNotEmpty)
                    Flexible(
                      child: CarbonTag(
                        label:
                            error ??
                            '${state.totalMatches} in ${state.totalFiles} files',
                        color: error != null
                            ? CarbonTagColor.red
                            : CarbonTagColor.gray,
                        size: CarbonTagSize.small,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        SizedBox(
          height: CarbonBorders.hairline,
          child: ColoredBox(color: theme.borderSubtle(CarbonLayer.of(context))),
        ),
        Expanded(
          child: state.query.isEmpty
              ? const CarbonEmptyState(
                  icon: CarbonIcons.search,
                  heading: 'Search across all files',
                )
              : state.results.isEmpty && !state.isSearching
              ? CarbonEmptyState(
                  icon: CarbonIcons.search,
                  heading: 'No results for "${state.query}"',
                )
              : SearchResultList(
                  key: const PageStorageKey('search_results'),
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
