import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../analytics/events.dart';
import '../constants/breakpoints.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/ab_colors.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_confirm_dialog.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_tap_target.dart';
import '../design/widgets/ab_loading.dart';
import '../design/widgets/ab_separator.dart';
import '../models/file_tree_models.dart';
import '../providers/analytics.dart';
import '../providers/providers.dart';
import '../services/file_service.dart';
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
    final statuses =
        treeStateAsync.value?.gitFileStatuses ?? const <String, String>{};

    // Loading/error keep the same header (no back affordance) so the panel
    // chrome doesn't jump when data arrives; the data case owns its own header
    // because only it knows the active layout (see _GitPanelBody).
    return treeStateAsync.when(
      loading: () => _GitPanelScaffold(
        statuses: statuses,
        fileService: fileService,
        body: const AbLoading(message: 'loading changes...'),
      ),
      error: (error, _) => _GitPanelScaffold(
        statuses: statuses,
        fileService: fileService,
        body: Center(
          child: Text(
            'Error: $error',
            style: TextStyle(color: context.antgrid.textMuted),
          ),
        ),
      ),
      data: (state) => _GitPanelBody(state: state, fileService: fileService),
    );
  }
}

/// The shared git-panel chrome: header + separator + expanded body, defined
/// once so the loading/error/data branches can't drift in how they wrap the
/// header. [onBack] is forwarded to the header (only the compact diff-viewing
/// data branch supplies it).
class _GitPanelScaffold extends StatelessWidget {
  const _GitPanelScaffold({
    required this.statuses,
    required this.fileService,
    required this.body,
    this.onBack,
  });

  final Map<String, String> statuses;
  final FileService fileService;
  final Widget body;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _GitChangesHeader(
          statuses: statuses,
          fileService: fileService,
          onBack: onBack,
        ),
        const AbSeparator.horizontal(),
        Expanded(child: body),
      ],
    );
  }
}

/// The single git-changes header: title + Commit action, with an optional
/// back affordance.
///
/// One header for all layouts. In compact diff-viewing mode the back button is
/// merged in here (via [onBack]) rather than rendered as a second stacked bar,
/// so the user never sees two headers.
class _GitChangesHeader extends StatelessWidget {
  const _GitChangesHeader({
    required this.statuses,
    required this.fileService,
    this.onBack,
  });

  final Map<String, String> statuses;
  final FileService fileService;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AbTokens.space12,
        vertical: AbTokens.space8,
      ),
      // Hand-rolled header, but the same rhythm as an AbToolbar: type sets the
      // height, the back button is inline chrome inside it.
      child: AbCompactTapTargets(
        child: Row(
          children: [
            if (onBack != null) ...[
              AbIconButton(
                icon: AbIcons.back,
                onTap: onBack,
                tooltip: 'Back to changed files',
              ),
              const SizedBox(width: AbTokens.space8),
            ],
            Text(
              'Changes',
              style: AbTokens.sansStyle(color: context.antgrid.textMuted),
            ),
            const Spacer(),
            AbButton(
              label: statuses.isEmpty
                  ? 'Commit'
                  : 'Commit (${statuses.length})',
              leading: AbIcon(
                AbIcons.gitCommit,
                size: AbTokens.iconButtonGlyph,
                // Match the primary variant's accentForeground label.
                color: context.antgrid.accentForeground,
              ),
              variant: AbButtonVariant.primary,
              onTap: statuses.isEmpty
                  ? null
                  : () => GitCommitSheet.show(
                      context: context,
                      changedFiles: statuses,
                      onCommit: fileService.commit,
                    ),
            ),
          ],
        ),
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
          statuses: state.gitFileStatuses,
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

  Widget _buildFileList(BuildContext context) {
    final changedFiles = state.gitFileStatuses;
    if (changedFiles.isEmpty) {
      return Center(
        child: Text(
          'No changed files',
          style: TextStyle(color: context.antgrid.textMuted),
        ),
      );
    }

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
        gitFileStatuses: state.gitFileStatuses,
        showChangedOnly: true,
        onToggleExpanded: (path) => fileService.toggleExpanded(path),
        onFileSelected: (path) => fileService.requestDiff(path),
        onDiscard: (path) => _confirmDiscard(context, path),
      ),
    );
  }

  Future<void> _confirmDiscard(BuildContext context, String path) async {
    final isUntracked = state.gitFileStatuses[path] == '?';
    final confirmed = await AbConfirmDialog.show(
      context: context,
      title: 'Discard changes',
      body: isUntracked
          ? 'Permanently delete the new file "$path"? This cannot be undone.'
          : 'Discard all changes to "$path"? This cannot be undone.',
      confirmLabel: isUntracked ? 'Delete' : 'Discard',
      destructive: true,
    );
    if (confirmed) fileService.discard([path]);
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
