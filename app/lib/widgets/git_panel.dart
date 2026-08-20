import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../analytics/events.dart';
import '../constants/breakpoints.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/ab_colors.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_confirm_dialog.dart';
import '../design/widgets/ab_diff_stat.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_tap_target.dart';
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
          body: const AbLoading(message: 'loading changes...'),
        ),
        error: (error, _) => _GitPanelScaffold(
          counts: counts,
          fileService: fileService,
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
    this.additions = 0,
    this.deletions = 0,
  });

  /// Conflicts ("!") are in none of these: there is nothing safe to stage or
  /// revert on one, and resolving it is not a restore to HEAD.
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
          if (e.status != '!' && !e.staged) e.path,
      ],
      revertablePaths: revertable.toList(),
    );
  }

  final int stagedCount;
  final List<String> unstagedPaths;

  /// Lines added/removed across every changed path — the same worktree total
  /// the workspace menu carries (`gitDiffTotalsProvider`), recomputed here off
  /// the entries this header was already given rather than watched separately.
  final int additions;
  final int deletions;

  /// Every changed path, staged side included — Revert All means "back to
  /// HEAD", so a file whose only change is already staged is still in scope.
  final List<String> revertablePaths;
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
    this.onBack,
  });

  final _GitHeaderCounts counts;
  final FileService fileService;
  final Widget body;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _GitChangesHeader(
          counts: counts,
          fileService: fileService,
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
    this.onBack,
  });

  final _GitHeaderCounts counts;
  final FileService fileService;
  final VoidCallback? onBack;

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
                  Row(children: _title(context)),
                  const SizedBox(height: AbTokens.space4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: _actions(context),
                  ),
                ],
              )
            : Row(children: [..._title(context), ..._actions(context)]),
      ),
    );
  }

  List<Widget> _title(BuildContext context) => [
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
          if (counts.additions > 0 || counts.deletions > 0) ...[
            const SizedBox(width: AbTokens.space8),
            AbDiffStat(
              additions: counts.additions,
              deletions: counts.deletions,
              fontSize: AbTokens.fontXs,
            ),
          ],
        ],
      ),
    ),
  ];

  List<Widget> _actions(BuildContext context) => [
    // Both bulk actions stay mounted while anything is changed, even when one
    // of them has nothing to do — a Stage All that vanishes the moment the
    // last file is staged moves Commit under the finger already travelling
    // toward it.
    if (counts.revertablePaths.isNotEmpty) ...[
      _BulkActionGroup(
        children: [
          _BulkAction(
            icon: AbIcons.revert,
            tooltip: 'Revert All Changes',
            onTap: () => _revertAll(context),
          ),
          _BulkAction(
            icon: AbIcons.gitStage,
            tooltip: 'Stage All Changes',
            onTap: counts.unstagedPaths.isEmpty
                ? null
                : () => fileService.stageFiles(counts.unstagedPaths),
          ),
        ],
      ),
      const SizedBox(width: AbTokens.space6),
    ],
    AbButton(
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
      onTap: counts.stagedCount == 0
          ? null
          : () => GitCommitSheet.show(
              context: context,
              onCommit: fileService.commit,
            ),
    ),
  ];
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

  // Same tree shape as the Files tab, decorated AND pruned down to changed
  // files and their ancestor folders — FileTreeView's [changesOnly] hides
  // everything else rather than just leaving it undecorated.
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
        onToggleExpanded: (path) => fileService.toggleExpanded(path),
        onFileSelected: (path) => fileService.requestDiff(path),
        onStage: (path) => fileService.stageFiles([path]),
        onUnstage: (path) => fileService.unstageFiles([path]),
        onDiscard: (path) => _confirmDiscard(context, path),
      ),
    );
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
