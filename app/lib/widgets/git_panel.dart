import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../analytics/events.dart';
import '../constants/breakpoints.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/ab_colors.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_chip.dart';
import '../design/widgets/ab_confirm_dialog.dart';
import '../design/widgets/ab_diff_stat.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_tap_target.dart';
import '../design/widgets/ab_tooltip.dart';
import '../design/widgets/ab_loading.dart';
import '../design/widgets/ab_separator.dart';
import '../models/ab_message.dart' show GitFileStatusEntry;
import '../models/file_tree_models.dart';
import '../navigation/back_intent.dart';
import '../providers/analytics.dart';
import '../providers/providers.dart';
import '../providers/visible_surface.dart';
import '../services/file_service.dart';
import '../widgets/workspace_tab_bar.dart';
import '../widgets/diff_viewer.dart';
import '../widgets/file_viewer_router.dart';
import '../widgets/file_tree_view.dart';
import '../widgets/git_commit_sheet.dart';

/// Standalone git-changes panel extracted from FileExplorerScreen.
///
/// Shows changed files in a tree view; tapping a file requests its diff.
/// Adapts between compact (single-pane) and side-by-side layout based on
/// available width.
class GitPanel extends ConsumerStatefulWidget {
  const GitPanel({super.key});

  @override
  ConsumerState<GitPanel> createState() => _GitPanelState();
}

class _GitPanelState extends ConsumerState<GitPanel> {
  @override
  void initState() {
    super.initState();
    // Fire the view event once per mount — build() can run many times per frame
    // and must stay side-effect free.
    ref.read(analyticsServiceProvider)?.track(AnalyticsEvents.gitViewed);
  }

  @override
  Widget build(BuildContext context) {
    final fileService = serviceWhenReady(ref, fileServiceProvider);
    if (fileService == null) {
      return const AbLoading(message: 'loading changes...');
    }
    final treeStateAsync = ref.watch(fileTreeStateProvider);
    final counts = _GitHeaderCounts.of(treeStateAsync.value?.gitFileEntries);
    final git = treeStateAsync.value?.git;
    final collapsedPaths = git?.collapsedPaths ?? const <String>{};
    // watch, not the `ref.read` in [_backFromViewer]: the `active` flag has to
    // be recomputed when this tab goes on or off screen.
    final onScreen =
        ref.watch(visibleWorkspaceViewProvider) == WorkspaceView.git;

    // Loading/error keep the same header (no back affordance) so the panel
    // chrome doesn't jump when data arrives; the data case owns its own header
    // because only it knows the active layout (see _GitPanelBody).
    return BackHandler(
      priority: BackPriority.gitViewer,
      active: onScreen && (git?.viewingPath != null || git?.diffPath != null),
      onBack: _backFromViewer,
      child: treeStateAsync.when(
        loading: () => _GitPanelScaffold(
          counts: counts,
          fileService: fileService,
          collapsedPaths: collapsedPaths,
          body: const AbLoading(message: 'loading changes...'),
        ),
        error: (error, _) => _GitPanelScaffold(
          counts: counts,
          fileService: fileService,
          collapsedPaths: collapsedPaths,
          body: Center(
            child: Text(
              'Error: $error',
              style: TextStyle(color: context.antgrid.textMuted),
            ),
          ),
        ),
        data: (state) => _GitPanelBody(state: state, fileService: fileService),
      ),
    );
  }

  /// Steps out ONE level: the file opened from a diff, then the diff itself.
  /// Deliberately unlike the compact header's back button, which clears both at
  /// once because it means "return to the changes list".
  bool _backFromViewer() {
    if (ref.read(visibleWorkspaceViewProvider) != WorkspaceView.git) {
      return false;
    }
    final git = ref.read(fileTreeStateProvider).value?.git;
    if (git == null) return false;
    // Runs outside build(): the façade throws while the session is unresolved.
    // Checkout-scoped to match the service this panel was BUILT with — the
    // main-checkout façade would clear the git viewing state of a tree that is
    // not the one on screen in an isolated session, so the press would report
    // itself handled while nothing moved.
    final service = focusedCheckoutServiceOrNull(
      ref.container,
      (s) => s.fileService,
    );
    if (service == null) return false;
    if (git.viewingPath != null) {
      service.clearGitViewing();
      return true;
    }
    if (git.diffPath != null) {
      service.clearDiff();
      return true;
    }
    return false;
  }
}

/// What the header's Stage All / Revert All / Commit actions operate on,
/// derived from the raw entry list in ONE place.
///
/// Every branch of the panel (loading, error, data) renders the same header,
/// and each used to re-derive these itself — so a change to what counts as
/// unstaged reached only whichever copies were remembered.
class _GitHeaderCounts {
  const _GitHeaderCounts({
    required this.stagedCount,
    required this.unstagedPaths,
    required this.revertablePaths,
    this.conflictPaths = const [],
    this.unresolvedConflictPaths = const [],
    this.changedFolders = const {},
    this.additions = 0,
    this.deletions = 0,
  });

  /// A conflict ("!") is in [unstagedPaths] — staging one IS how git resolves
  /// it, so Stage All has to be able to reach it — but never in
  /// [revertablePaths]: resolving a conflict is not a restore to HEAD.
  ///
  /// A path with BOTH a staged and an unstaged change has two entries, so
  /// [revertablePaths] dedups — Revert All names each path once.
  factory _GitHeaderCounts.of(List<GitFileStatusEntry>? entries) {
    if (entries == null) {
      return const _GitHeaderCounts(
        stagedCount: 0,
        unstagedPaths: [],
        revertablePaths: [],
      );
    }
    final revertable = <String>{
      for (final e in entries)
        if (e.status != '!') e.path,
    };
    // Keyed by path for the same dedup reason: both entries of a
    // partially-staged file carry the SAME combined-vs-HEAD line counts.
    final perPath = <String, GitFileStatusEntry>{};
    for (final e in entries) {
      perPath.putIfAbsent(e.path, () => e);
    }
    return _GitHeaderCounts(
      additions: perPath.values.fold(0, (sum, e) => sum + e.additions),
      deletions: perPath.values.fold(0, (sum, e) => sum + e.deletions),
      stagedCount: entries.where((e) => e.staged).length,
      unstagedPaths: [
        for (final e in entries)
          if (!e.staged) e.path,
      ],
      revertablePaths: revertable.toList(),
      conflictPaths: [
        for (final e in entries)
          if (e.isConflict) e.path,
      ],
      unresolvedConflictPaths: [
        for (final e in entries)
          if (e.isUnresolvedConflict) e.path,
      ],
      changedFolders: {for (final e in entries) ..._ancestorsOf(e.path)},
    );
  }

  /// Every directory prefix of [path], which is exactly the set of folder rows
  /// the changed-files tree will produce for it. Derived from the PATHS rather
  /// than read off the rendered tree: the header is built on the loading and
  /// error branches too, where there is no tree yet, and a Collapse All that
  /// appeared only once the tree hydrated would flicker in on a cold tab.
  ///
  /// The trailing slash git puts on an untracked directory it did not walk into
  /// is dropped first: the tree renders that path verbatim as a LEAF, so the
  /// name before the slash is not a folder row and counting it as one leaves
  /// [changedFolders] holding a folder nothing can ever collapse.
  static Iterable<String> _ancestorsOf(String path) sync* {
    var dir = path.endsWith('/')
        ? path.substring(0, path.length - 1)
        : path;
    var slash = dir.lastIndexOf('/');
    while (slash >= 0) {
      dir = dir.substring(0, slash);
      yield dir;
      slash = dir.lastIndexOf('/');
    }
  }

  final int stagedCount;
  final List<String> unstagedPaths;

  /// Unmerged paths, resolved or not — git refuses a commit while ANY of them
  /// is unmerged, so this is what the header counts to explain why Commit is
  /// refused, and what keeps the bulk actions on a conflict-only tree.
  final List<String> conflictPaths;

  /// The conflicts with markers still in them — the ones staging would resolve
  /// on the user's word alone, which is what Stage All asks about before it
  /// stages anything. The rest need no question; see
  /// [GitFileStatusEntry.conflictResolved].
  final List<String> unresolvedConflictPaths;

  /// Whether anything at all is changed — a conflict counts, which is why this
  /// is not `revertablePaths.isNotEmpty`.
  bool get hasChanges => revertablePaths.isNotEmpty || conflictPaths.isNotEmpty;

  /// Lines added/removed across every changed path — the same worktree total
  /// the workspace menu carries (`gitDiffTotalsProvider`), recomputed here off
  /// the entries this header was already given rather than watched separately.
  final int additions;
  final int deletions;

  /// Every changed path, staged side included — Revert All means "back to
  /// HEAD", so a file whose only change is already staged is still in scope.
  final List<String> revertablePaths;

  /// Every folder the changed-files tree nests something under — what Collapse
  /// All folds, and what tells Expand All when there is nothing left to fold.
  final Set<String> changedFolders;
}

/// The shared git-panel chrome: header + separator + expanded body, defined
/// once so the loading/error/data branches can't drift in how they wrap the
/// header. [onBack] is forwarded to the header (only the compact diff-viewing
/// data branch supplies it).
class _GitPanelScaffold extends StatelessWidget {
  const _GitPanelScaffold({
    required this.counts,
    required this.fileService,
    required this.body,
    this.collapsedPaths = const {},
    this.onBack,
  });

  final _GitHeaderCounts counts;
  final FileService fileService;
  final Widget body;
  final Set<String> collapsedPaths;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _GitChangesHeader(
          counts: counts,
          fileService: fileService,
          collapsedPaths: collapsedPaths,
          onBack: onBack,
        ),
        const AbSeparator.horizontal(),
        Expanded(child: body),
      ],
    );
  }
}

/// The single git-changes header: title + Revert All / Stage All / Commit,
/// with an optional back affordance.
///
/// The two bulk actions are icons in the same order and vocabulary every SCM
/// panel uses (revert, then +), so only Commit — the one that opens a sheet
/// and needs its staged count — carries a label.
///
/// One header for all layouts. In compact diff-viewing mode the back button is
/// merged in here (via [onBack]) rather than rendered as a second stacked bar,
/// so the user never sees two headers.
class _GitChangesHeader extends StatelessWidget {
  const _GitChangesHeader({
    required this.counts,
    required this.fileService,
    this.collapsedPaths = const {},
    this.onBack,
  });

  final _GitHeaderCounts counts;
  final FileService fileService;
  final VoidCallback? onBack;

  /// Folders currently folded shut. Only used to decide which way the one
  /// toggle points, so an unhydrated Git pane (empty set) correctly offers to
  /// collapse rather than to expand.
  final Set<String> collapsedPaths;

  bool get allFoldersCollapsed =>
      counts.changedFolders.isNotEmpty &&
      collapsedPaths.containsAll(counts.changedFolders);

  Future<void> _revertAll(BuildContext context) async {
    final paths = counts.revertablePaths;
    if (paths.isEmpty) return;
    final count = paths.length;
    final confirmed = await AbConfirmDialog.show(
      context: context,
      title: 'Revert all changes',
      body:
          'Revert $count file${count == 1 ? '' : 's'} to the last commit? '
          'Staged changes are reverted too and new files are deleted. '
          'This cannot be undone.',
      confirmLabel: 'Revert All',
      destructive: true,
    );
    if (confirmed) fileService.discard(paths, includeStaged: true);
  }

  /// Stage All, with the question VS Code asks before the same thing: an
  /// unresolved conflict is staged only on the user's word, because staging IS
  /// the resolution and a later `git reset` gives back a plain modified file
  /// rather than the unmerged stages. Cancelling stages NOTHING — the pressed
  /// action was "stage all of it", and quietly staging most of it instead is a
  /// different action nobody asked for.
  ///
  /// A conflict with no markers left is not asked about, the same split VS
  /// Code makes: the everyday "I fixed them all, now stage" stays one tap.
  Future<void> _stageAll(BuildContext context) async {
    final paths = counts.unstagedPaths;
    if (paths.isEmpty) return;
    final unresolved = counts.unresolvedConflictPaths;
    if (unresolved.isNotEmpty) {
      final confirmed = await AbConfirmDialog.show(
        context: context,
        title: 'Stage merge conflicts',
        body: unresolved.length == 1
            ? 'Stage all changes? "${unresolved.first}" is still an unresolved '
                  'merge conflict — staging it marks it resolved, and git will '
                  'commit whatever the file holds now.'
            : 'Stage all changes? ${unresolved.length} of them are still '
                  'unresolved merge conflicts — staging one marks it resolved, '
                  'and git will commit whatever the file holds now.',
        confirmLabel: 'Stage All',
      );
      if (!confirmed) return;
    }
    fileService.stageFiles(paths);
  }

  /// Below this the header's one line cannot hold both halves: the title and
  /// its diff stat, the two bulk actions and Commit need about 300px between
  /// them, and the title — inside the only [Flexible] here — is what gets
  /// ellipsised away first, leaving a header that shows counts for something
  /// it no longer names. Measured on the pane, not the window: a phone's full
  /// width clears it, a touch tablet's quarter-width context pane does not,
  /// which is the case this exists for.
  static const double _stackedHeaderWidth = 360;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) =>
          _build(context, stacked: constraints.maxWidth < _stackedHeaderWidth),
    );
  }

  Widget _build(BuildContext context, {required bool stacked}) {
    return Padding(
      // Tighter than the panel headers that sit over prose: this one sits over
      // a dense file list, and the tallest control in the row (Commit) already
      // carries its own padding — the SCM headers this is modelled on give the
      // strip barely more than the button itself.
      padding: const EdgeInsets.symmetric(
        horizontal: AbTokens.space12,
        vertical: AbTokens.space4,
      ),
      // Hand-rolled header, but the same rhythm as an AbToolbar: type sets the
      // height, the back button is inline chrome inside it.
      //
      child: AbCompactTapTargets(
        child: stacked
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: _title(context, stacked: true)),
                  const SizedBox(height: AbTokens.space4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: _actions(context),
                  ),
                ],
              )
            : Row(
                children: [
                  ..._title(context, stacked: false),
                  ..._actions(context),
                ],
              ),
      ),
    );
  }

  /// The title half of the header. Everything in it except the title text is
  /// fixed-width, so [stacked] — the narrow layout — is where the row runs out
  /// of line and something has to give.
  List<Widget> _title(BuildContext context, {required bool stacked}) => [
    if (onBack != null) ...[
      AbIconButton(
        icon: AbIcons.back,
        onTap: onBack,
        tooltip: 'Back to changed files',
      ),
      const SizedBox(width: AbTokens.space8),
    ],
    // Expanded, not a Spacer: sharing the line with the actions, the title is
    // the one thing here that can give room up (the tab it sits under already
    // says Git); on its own row it is what pushes nothing to the right.
    Expanded(
      child: Row(
        children: [
          Flexible(
            child: Text(
              'Changes',
              overflow: TextOverflow.ellipsis,
              style: AbTokens.sansStyle(color: context.antgrid.textMuted),
            ),
          ),
          // The diff stat is what yields, and only where it has to: on the
          // narrow header a merge is the one thing that fills the row (back
          // button + totals + conflict chip, none of them shrinkable), and of
          // the two counts it is the chip that has to survive — it is what
          // explains the dead Commit button beside it. The totals are still on
          // the workspace menu, and a merge's conflicts contribute 0 to them
          // anyway.
          if ((counts.additions > 0 || counts.deletions > 0) &&
              !(stacked && counts.conflictPaths.isNotEmpty)) ...[
            const SizedBox(width: AbTokens.space8),
            AbDiffStat(
              additions: counts.additions,
              deletions: counts.deletions,
              fontSize: AbTokens.fontXs,
            ),
          ],
          if (counts.conflictPaths.isNotEmpty) ...[
            const SizedBox(width: AbTokens.space8),
            // Beside the header's own totals, not down in the list: a conflict
            // is why Commit beside it is dead, and a user who cannot see one
            // without scrolling the tree reads that button as broken.
            AbChip.system(
              label: counts.conflictPaths.length == 1
                  ? '1 conflict'
                  : '${counts.conflictPaths.length} conflicts',
              color: context.antgrid.gitConflict,
            ),
          ],
        ],
      ),
    ),
  ];

  List<Widget> _actions(BuildContext context) => [
    // Its own control, not a third cell in the group below: that group is the
    // two actions that WRITE to the tree, and a view toggle sharing their
    // border would read as one of them. It is also gated separately — a tree
    // of nothing but conflicts drops the write group entirely, and folding a
    // long conflict list is exactly when this is wanted.
    if (counts.changedFolders.isNotEmpty) ...[
      _CollapseToggle(
        allCollapsed: allFoldersCollapsed,
        onTap: () => fileService.setGitCollapsedFolders(
          allFoldersCollapsed ? const {} : counts.changedFolders,
        ),
      ),
      const SizedBox(width: AbTokens.space6),
    ],
    // Both bulk actions stay mounted while anything is changed, even when one
    // of them has nothing to do — a Stage All that vanishes the moment the
    // last file is staged moves Commit under the finger already travelling
    // toward it. Each cell is gated on its OWN scope for the same reason: a
    // tree of nothing but conflicts has nothing safe to revert, and is exactly
    // where Stage All is the way out.
    if (counts.hasChanges) ...[
      _BulkActionGroup(
        children: [
          _BulkAction(
            icon: AbIcons.revert,
            tooltip: 'Revert All Changes',
            onTap: counts.revertablePaths.isEmpty
                ? null
                : () => _revertAll(context),
          ),
          _BulkAction(
            icon: AbIcons.gitStage,
            tooltip: 'Stage All Changes',
            onTap: counts.unstagedPaths.isEmpty
                ? null
                : () => _stageAll(context),
          ),
        ],
      ),
      const SizedBox(width: AbTokens.space6),
    ],
    _commitButton(context),
  ];

  /// Commit, refused while anything is unmerged.
  ///
  /// Git refuses that commit anyway, but only AFTER the user has opened the
  /// sheet and written a message — the work is thrown away to show an error
  /// about a file the sheet never mentioned. Disabling here moves the refusal
  /// to before the typing, and the header's conflict chip beside it is what
  /// keeps a dead button from reading as a broken one.
  Widget _commitButton(BuildContext context) {
    final blocked = counts.conflictPaths.isNotEmpty;
    final button = AbButton(
      label: counts.stagedCount == 0
          ? 'Commit'
          : 'Commit (${counts.stagedCount})',
      leading: AbIcon(
        AbIcons.gitCommit,
        size: AbTokens.iconButtonGlyph,
        // Match the primary variant's accentForeground label.
        color: context.antgrid.accentForeground,
      ),
      variant: AbButtonVariant.primary,
      onTap: (blocked || counts.stagedCount == 0)
          ? null
          : () => GitCommitSheet.show(
              context: context,
              onCommit: fileService.commit,
            ),
    );
    if (!blocked) return button;
    return AbTooltip(
      message: counts.conflictPaths.length == 1
          ? 'Resolve the merge conflict before committing'
          : 'Resolve ${counts.conflictPaths.length} merge conflicts before '
                'committing',
      // A disabled child swallows no pointer here (AbButton drops its gesture
      // detector rather than absorbing), so hover still reaches the tooltip.
      triggerMode: TooltipTriggerMode.tap,
      child: button,
    );
  }
}

/// The header's one fold control: Collapse All until every folder is shut,
/// Expand All after that.
///
/// One button rather than a pair, and it names the RESULT of pressing it (the
/// VS Code convention), not the current state — the tree itself already shows
/// which folders are open.
class _CollapseToggle extends StatelessWidget {
  const _CollapseToggle({required this.allCollapsed, required this.onTap});

  final bool allCollapsed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: AbTokens.rowHeightSm,
      child: AbIconButton(
        icon: allCollapsed ? AbIcons.expandAll : AbIcons.collapseAll,
        onTap: onTap,
        tooltip: allCollapsed ? 'Expand All Folders' : 'Collapse All Folders',
      ),
    );
  }
}

/// One cell of a [_BulkActionGroup]. `onTap: null` renders it disabled,
/// keeping its slot in the group.
class _BulkAction {
  const _BulkAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final String icon;
  final String tooltip;
  final VoidCallback? onTap;
}

/// Joins the header's whole-tree actions into one bordered control, sharing
/// the fill, radius and border of the Commit button beside them.
///
/// Loose icon buttons were the obvious spelling and the wrong one on touch:
/// [AbTapTarget] reserves a 44px-wide target around each 14px glyph, so two of
/// them read as a pair of unexplained marks drifting in whitespace. Bounding
/// each cell caps that reservation ([AbTapTarget] documents a bounded parent
/// winning) and the border turns what is left into surface the user can aim
/// at, which is what the gap was always meant to be.
class _BulkActionGroup extends StatelessWidget {
  const _BulkActionGroup({required this.children});

  final List<_BulkAction> children;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.antgrid.bgSurface,
        borderRadius: AbTokens.borderRadius5,
        border: Border.all(color: context.antgrid.borderDefault),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (i, action) in children.indexed) ...[
            if (i > 0)
              const SizedBox(
                height: AbTokens.iconButtonBox,
                child: AbSeparator.vertical(),
              ),
            SizedBox(
              width: AbTokens.rowHeightSm,
              child: AbIconButton(
                icon: action.icon,
                onTap: action.onTap,
                tooltip: action.tooltip,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _GitPanelBody extends StatelessWidget {
  const _GitPanelBody({required this.state, required this.fileService});

  final FileTreeState state;
  final FileService fileService;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final showSideBySide = constraints.maxWidth >= kCompactBreakpoint;
        final isViewing =
            state.git.diffPath != null || state.git.viewingPath != null;
        // Back belongs only to the compact single-pane viewer; side-by-side
        // shows the file list and content together, so there's nothing to go
        // "back" from.
        final showBack = !showSideBySide && isViewing;

        return _GitPanelScaffold(
          counts: _GitHeaderCounts.of(state.gitFileEntries),
          fileService: fileService,
          collapsedPaths: state.git.collapsedPaths,
          onBack: showBack
              ? () {
                  fileService.clearDiff();
                  fileService.clearGitViewing();
                }
              : null,
          body: _buildContent(
            context,
            showSideBySide: showSideBySide,
            isViewing: isViewing,
          ),
        );
      },
    );
  }

  Widget _buildContent(
    BuildContext context, {
    required bool showSideBySide,
    required bool isViewing,
  }) {
    if (showSideBySide) {
      return Row(
        children: [
          SizedBox(
            width: 280,
            child: _buildFileList(context),
          ), // 280px non-ladder: side-by-side file list width
          const AbSeparator.vertical(weight: AbSeparatorWeight.strong),
          Expanded(child: _buildContentArea(context)),
        ],
      );
    }

    // Compact: show viewer when a diff or "view file" is active.
    if (isViewing) {
      return _buildContentArea(context);
    }

    return _buildFileList(context);
  }

  // The same widget the Files tab renders, in its [changesOnly] mode: decorated,
  // and nesting the changed paths under folders of their own rather than
  // pruning the file tree down to them. [state.root] is passed for the
  // signature's sake and goes unread there (see FileTreeView's own doc), which
  // is what keeps this list from rearranging itself when the tree lands.
  Widget _buildFileList(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async {
        fileService.requestFullTree();
        await Future.delayed(const Duration(milliseconds: 500));
      },
      child: FileTreeView(
        root: state.root,
        expandedPaths: state.expandedPaths,
        selectedFilePath: state.git.diffPath ?? state.git.viewingPath,
        filterQuery: null,
        gitFileEntries: state.gitFileEntries,
        changesOnly: true,
        collapsedPaths: state.git.collapsedPaths,
        // The Git tab's own fold state, never the Files tab's `toggleExpanded`
        // — see [GitPaneState.collapsedPaths].
        onToggleExpanded: (path) => fileService.toggleGitFolder(path),
        onFileSelected: (path) => fileService.requestDiff(path),
        onStage: (path) => fileService.stageFiles([path]),
        onUnstage: (path) => fileService.unstageFiles([path]),
        onDiscard: (path) => _confirmDiscard(context, path),
        onResolveConflict: (path) => _confirmResolve(context, path),
      ),
    );
  }

  /// Marking a conflict resolved is `git add` on the file — the same command
  /// the Stage button runs, asked as a different question because it means
  /// something different and cannot be taken back: `git reset` afterwards
  /// leaves a plain modified file, it does not restore the unmerged stages.
  ///
  /// The question is skipped for a conflict the bridge has already scanned and
  /// found free of markers ([GitFileStatusEntry.conflictResolved]) — the user
  /// has done the work, and VS Code stages that one without asking for the same
  /// reason. Anything the bridge could not be sure about reports unresolved, so
  /// the unknown case still asks.
  Future<void> _confirmResolve(BuildContext context, String path) async {
    final entries = state.gitFileEntries
        .where((e) => e.path == path)
        .toList(growable: false);
    if (entries.isNotEmpty && !entries.any((e) => e.isUnresolvedConflict)) {
      fileService.stageFiles([path]);
      return;
    }
    // A delete racing an edit has no marker block to remove, so "check for
    // markers" is the wrong instruction: what staging keeps is whatever is on
    // disk, and choosing the deletion means deleting the file first.
    final deletionConflict = entries.any(
      (e) =>
          e.conflictKind == 'deletedByUs' ||
          e.conflictKind == 'deletedByThem' ||
          e.conflictKind == 'bothDeleted',
    );
    final confirmed = await AbConfirmDialog.show(
      context: context,
      title: 'Mark resolved',
      body: deletionConflict
          ? 'One side of the merge deleted "$path" while the other changed it. '
                'Marking it resolved keeps exactly what is on disk now — delete '
                'the file first if the deletion is what you want.'
          : 'Mark "$path" as resolved? Open it first and make sure no conflict '
                'markers (<<<<<<<) are left — git will commit whatever the file '
                'holds now.',
      confirmLabel: 'Mark Resolved',
    );
    if (confirmed) fileService.stageFiles([path]);
  }

  Future<void> _confirmDiscard(BuildContext context, String path) async {
    // Read the per-entry list, not the deduped `gitFileStatuses` map: a path
    // with BOTH a staged and an unstaged change collapses to one letter there,
    // which cannot answer the question the copy below turns on.
    final entries = state.gitFileEntries.where((e) => e.path == path);
    // Nothing at HEAD to restore, whether the file is untracked or already in
    // the index — reverting one means deleting it.
    final isNew = entries.any(
      (e) => e.status == 'U' || (e.status == 'A' && e.staged),
    );
    final hasStaged = entries.any((e) => e.staged);
    final String body;
    if (isNew) {
      body = 'Permanently delete the new file "$path"? This cannot be undone.';
    } else if (hasStaged) {
      body =
          'Revert "$path" to the last commit? Its staged changes are reverted '
          'too. This cannot be undone.';
    } else {
      body = 'Discard all changes to "$path"? This cannot be undone.';
    }
    final confirmed = await AbConfirmDialog.show(
      context: context,
      title: hasStaged && !isNew ? 'Revert changes' : 'Discard changes',
      body: body,
      confirmLabel: isNew
          ? 'Delete'
          : hasStaged
          ? 'Revert'
          : 'Discard',
      destructive: true,
    );
    if (confirmed) fileService.discard([path], includeStaged: true);
  }

  Widget _buildContentArea(BuildContext context) {
    final git = state.git;
    if (git.diffPath != null) {
      if (git.diffLoading) {
        return const AbLoading();
      }
      if (git.diffContent != null) {
        return DiffViewer(
          path: git.diffPath!,
          gitStatus: state.gitFileStatuses[git.diffPath!],
          diff: git.diffContent!,
          additions: git.diffAdditions ?? 0,
          deletions: git.diffDeletions ?? 0,
          onViewFile: () => fileService.gitViewFile(git.diffPath!),
          onClose: () => fileService.clearDiff(),
        );
      }
      return Center(
        child: Text(
          'No changes',
          style: TextStyle(color: context.antgrid.textMuted),
        ),
      );
    }

    if (git.viewingPath != null) {
      return FileViewerRouter(
        fileContent: git.viewingFile,
        isLoading: git.viewingLoading,
        selectedFilePath: git.viewingPath,
        fileWasModified: false,
        onRefreshContent: () =>
            fileService.requestFileContent(git.viewingPath!),
        onClose: () => fileService.clearGitViewing(),
      );
    }

    return Center(
      child: Text(
        'Select a file to view',
        style: TextStyle(color: context.antgrid.textMuted),
      ),
    );
  }
}
