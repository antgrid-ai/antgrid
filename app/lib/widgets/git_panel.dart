import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, LogicalKeyboardKey;
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
import '../design/widgets/ab_disclosure_chevron.dart';
import '../design/widgets/ab_empty_state.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_inline_banner.dart';
import '../design/widgets/ab_list_row.dart';
import '../design/widgets/ab_menu.dart';
import '../design/widgets/ab_text_field.dart';
import '../design/widgets/ab_toast.dart';
import '../design/widgets/ab_tap_target.dart';
import '../design/widgets/ab_tooltip.dart';
import '../design/widgets/ab_loading.dart';
import '../design/widgets/ab_separator.dart';
import '../models/ab_message.dart'
    show GitFileStatusEntry, GitCommitFileEntry, GitLogEntry;
import '../models/git_status_index.dart';
import '../models/git_sync_state.dart';
import '../models/file_tree_models.dart';
import '../navigation/back_intent.dart';
import '../providers/analytics.dart';
import '../providers/providers.dart';
import '../providers/tasks.dart' show focusedSessionTaskProvider;
import '../providers/visible_surface.dart';
import '../services/file_service.dart';
import '../util/detached.dart';
import '../util/relative_time.dart';
import '../widgets/workspace_tab_bar.dart';
import '../widgets/diff_viewer.dart';
import '../widgets/file_viewer_router.dart';
import '../widgets/file_tree_view.dart';
import '../widgets/git_status_color.dart';
import '../widgets/git_sync_failure_handoff.dart';
import '../widgets/send_capture_to_agent.dart';
import '../widgets/tasks/task_status_view.dart';
import '../widgets/tasks/tasks_surface.dart';

/// Anchors the Changes section header's diff totals for tests — a file row's
/// own diff-stat badge carries the same numbers, so a test reading the totals
/// has to scope its finder to this.
@visibleForTesting
const gitChangesHeaderTitleKey = Key('gitChangesHeaderTitle');

/// Standalone git-changes panel extracted from FileExplorerScreen.
///
/// One column at every width: the branch bar (branch, inline commit box,
/// Commit beside the remote action), then the Changes tree and the commit
/// History as two foldable sections. Wide enough, the column docks beside the
/// diff/file viewer; narrower, the viewer replaces it while a file is open.
/// The column is the same widget in both layouts, so no button moves when the
/// pane is resized across the breakpoint.
class GitPanel extends ConsumerStatefulWidget {
  const GitPanel({super.key});

  @override
  ConsumerState<GitPanel> createState() => _GitPanelState();
}

class _GitPanelState extends ConsumerState<GitPanel> {
  /// One commit-message draft per [FileService]. The panel is rebuilt with the
  /// newly focused project's service on a project switch rather than
  /// remounted, so a single controller would carry a half-written message into
  /// another repository — and clearing it instead would lose the draft the
  /// user comes back for.
  final _drafts = <FileService, TextEditingController>{};
  final _draftFocus = FocusNode();

  /// Pure view state, so it lives here rather than in [GitPaneState] the way
  /// `historyCollapsed` does: nothing outside this widget reads it.
  bool _changesCollapsed = false;

  @override
  void initState() {
    super.initState();
    // Fire the view event once per mount — build() can run many times per frame
    // and must stay side-effect free.
    ref.read(analyticsServiceProvider)?.track(AnalyticsEvents.gitViewed);
  }

  @override
  void dispose() {
    for (final draft in _drafts.values) {
      draft.dispose();
    }
    _draftFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fileService = serviceWhenReady(ref, fileServiceProvider);
    if (fileService == null) {
      return const AbLoading(message: 'loading changes...');
    }
    final panel = _PanelContext(
      fileService: fileService,
      draft: _drafts.putIfAbsent(fileService, TextEditingController.new),
      draftFocus: _draftFocus,
      changesCollapsed: _changesCollapsed,
      onToggleChanges: () =>
          setState(() => _changesCollapsed = !_changesCollapsed),
    );
    final treeStateAsync = ref.watch(fileTreeStateProvider);
    final counts = treeStateAsync.value?.gitStatus ?? GitStatusIndex.empty;
    final git = treeStateAsync.value?.git;
    // watch, not the `ref.read` in [_backFromViewer]: the `active` flag has to
    // be recomputed when this tab goes on or off screen.
    final onScreen =
        ref.watch(visibleWorkspaceViewProvider) == WorkspaceView.git;
    _maybeLoadHistory(fileService);

    // Loading/error keep the same branch bar so the panel chrome doesn't jump
    // when data arrives; the data case lays out its own sections because only
    // it knows the active layout (see _GitPanelBody).
    return BackHandler(
      priority: BackPriority.gitViewer,
      active: onScreen && (git?.viewingPath != null || git?.diffPath != null),
      onBack: _backFromViewer,
      child: treeStateAsync.when(
        loading: () => _GitPanelScaffold(
          panel: panel,
          counts: counts,
          git: git ?? GitPaneState.empty,
          body: const AbLoading(message: 'loading changes...'),
        ),
        error: (error, _) => _GitPanelScaffold(
          panel: panel,
          counts: counts,
          git: git ?? GitPaneState.empty,
          body: Center(
            child: Text(
              'Error: $error',
              style: TextStyle(color: context.antgrid.textMuted),
            ),
          ),
        ),
        data: (state) =>
            _GitPanelBody(state: state, panel: panel, counts: counts),
      ),
    );
  }

  /// History has no consumer besides this panel — unlike the file tree or
  /// sync state, both shown elsewhere too — so it is fetched lazily here
  /// rather than eagerly for every `FileService` construction, which would
  /// cost every project session a `git:log` round trip whether or not its Git
  /// tab is ever opened.
  ///
  /// [FileService.claimHistoryLoad] (not a local flag) is what makes this
  /// safe to call on every build: build() itself must stay free of the
  /// [FileService.loadHistory] send (and the reply-timeout timer it arms), so
  /// the actual call is deferred to a post-frame callback — and a widget can
  /// legitimately build more than once before that callback runs and the
  /// resulting `loadingMore` state change comes back around. The claim is
  /// what keeps that window from firing the send twice.
  void _maybeLoadHistory(FileService? fileService) {
    if (fileService == null) return;
    if (!fileService.claimHistoryLoad()) return;
    // Deliberately NOT guarded on `mounted`: the claim is one-way for the
    // SERVICE's lifetime, and the service outlives this panel. Skipping the
    // send because the panel unmounted inside the frame (a view switch, a
    // session switch) spends the claim with nothing sent, and history then
    // sits on its "loading history..." placeholder forever — that is exactly
    // the state a service which never asked reports, and nothing asks again.
    // `loadHistory` touches no BuildContext; a disposed service drops it.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => fileService.loadHistory(),
    );
  }

  /// Steps out ONE level: the file opened from a diff, then the diff itself.
  /// Deliberately unlike the compact viewer bar's back button, which clears
  /// both at once because it means "return to the changes list".
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

/// What [_GitPanelState] owns and every branch of the panel threads through:
/// the service, the commit draft, and the Changes fold.
class _PanelContext {
  const _PanelContext({
    required this.fileService,
    required this.draft,
    required this.draftFocus,
    required this.changesCollapsed,
    required this.onToggleChanges,
  });

  final FileService fileService;
  final TextEditingController draft;
  final FocusNode draftFocus;
  final bool changesCollapsed;
  final VoidCallback onToggleChanges;
}

/// Names the task the active session's changes belong to, when it was
/// launched from one — the reverse of the task detail view's own Changes
/// section, which shows a task's diff FROM the task side. Renders nothing for
/// a session started outside a task, which is most of them.
class _TaskContextStrip extends ConsumerWidget {
  const _TaskContextStrip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final task = ref.watch(focusedSessionTaskProvider);
    if (task == null) return const SizedBox.shrink();
    final t = context.antgrid;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AbTokens.space6),
      child: AbListRow(
        density: AbRowDensity.sm,
        hoverable: true,
        title: Row(
          children: [
            Text(
              task.ref,
              style: AbTokens.monoStyle(
                fontSize: AbTokens.fontXs,
                color: t.textMuted,
              ),
            ),
            const SizedBox(width: AbTokens.space6),
            Expanded(
              child: Text(
                task.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontSm,
                  color: t.textSecondary,
                ),
              ),
            ),
          ],
        ),
        trailing: TaskStatusPill(status: task.status, compact: true),
        margin: const EdgeInsets.symmetric(vertical: AbTokens.space2),
        onTap: () => openTasks(context, ref, select: task.number),
      ),
    );
  }
}

/// The loading/error chrome: the branch bar over a placeholder body, so the
/// bar is already in place when the data branch takes over.
class _GitPanelScaffold extends StatelessWidget {
  const _GitPanelScaffold({
    required this.panel,
    required this.counts,
    required this.body,
    this.git = GitPaneState.empty,
  });

  final _PanelContext panel;
  final GitStatusIndex counts;
  final Widget body;
  final GitPaneState git;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Above the branch bar: it says whose changes the rest of the panel
        // is about, so it has to be read before anything the bar counts.
        const _TaskContextStrip(),
        _GitBranchBar(panel: panel, counts: counts, git: git),
        if (git.lastSyncFailure case final failure?)
          _SyncFailureStrip(failure: failure, git: git),
        const AbSeparator.horizontal(),
        Expanded(child: body),
      ],
    );
  }
}

/// The top of the column: which branch this is and where it stands against
/// its remote, the commit box, and the row that acts on both — Commit, and
/// Publish or Pull/Push beside it.
///
/// The commit box and Commit only appear while something is changed; the
/// remote action stays whenever there is a remote to act on, so a clean tree
/// still offers the push it is usually waiting for.
class _GitBranchBar extends StatelessWidget {
  const _GitBranchBar({
    required this.panel,
    required this.counts,
    required this.git,
  });

  final _PanelContext panel;
  final GitStatusIndex counts;
  final GitPaneState git;

  FileService get _fileService => panel.fileService;

  bool get _commitBlocked => counts.conflictPaths.isNotEmpty;

  bool get _canCommit => !_commitBlocked && counts.stagedCount > 0;

  /// What gets committed is decided by staging, never re-asked here — the VS
  /// Code contract. An empty message sends the user to the box rather than
  /// letting git refuse it after the fact.
  void _commit() {
    if (!_canCommit) return;
    final message = panel.draft.text.trim();
    if (message.isEmpty) {
      panel.draftFocus.requestFocus();
      return;
    }
    _fileService.commit(message);
    panel.draft.clear();
  }

  /// Re-pulls everything the panel shows: the file tree (which, server-side,
  /// forces a fresh git-status read alongside it — see the bridge's
  /// `file:tree:root:request` handler), the ahead/behind sync counts, and
  /// the commit log. One button for all three: from here they read as one
  /// picture of the repository, not three independently-stale ones.
  void _refresh() {
    _fileService.requestFullTree();
    _fileService.refreshSyncState();
    _fileService.loadHistory();
  }

  @override
  Widget build(BuildContext context) {
    final sync = git.sync;
    final busy = git.syncing != null;
    final actions = <Widget>[
      if (counts.hasChanges) Expanded(child: _commitButton(context)),
      // A branch that has never been pushed has nothing to pull and no counts
      // to show — one action, named for what it does, matching VS Code.
      if (sync.canPublish)
        Expanded(
          child: AbButton(
            label: 'Publish Branch',
            expand: true,
            fontSize: AbTokens.fontSm,
            leading: busy
                ? const AbLoadingDot(size: AbTokens.fontXs)
                : AbIcon(
                    AbIcons.upload,
                    size: AbTokens.iconButtonGlyph,
                    color: context.antgrid.textSecondary,
                  ),
            onTap: busy ? null : _fileService.push,
          ),
        )
      else if (sync.hasUpstream)
        Expanded(
          child: _SyncSplit(
            sync: sync,
            syncing: git.syncing,
            fileService: _fileService,
          ),
        ),
    ];

    return Padding(
      padding: const EdgeInsets.all(AbTokens.space12),
      child: AbCompactTapTargets(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _BranchLine(sync: sync, onRefresh: _refresh),
            if (counts.hasChanges) ...[
              const SizedBox(height: AbTokens.space10),
              _CommitMessageField(panel: panel, onCommit: _commit),
            ],
            // Above the button it explains, not down in the tree: a conflict is
            // why Commit is dead, and a user who cannot see one without
            // scrolling reads that button as broken.
            if (_commitBlocked) ...[
              const SizedBox(height: AbTokens.space8),
              _ConflictNotice(count: counts.conflictPaths.length),
            ],
            if (actions.isNotEmpty) ...[
              const SizedBox(height: AbTokens.space8),
              SizedBox(
                height: AbTokens.rowHeightXs,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (i, action) in actions.indexed) ...[
                      if (i > 0) const SizedBox(width: AbTokens.space6),
                      action,
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Commit, refused while anything is unmerged and while nothing is staged.
  ///
  /// Git refuses an unmerged commit anyway, but only after the message has
  /// been written. Disabling here moves the refusal to before the typing, and
  /// the conflict notice above is what keeps a dead button from reading as a
  /// broken one.
  Widget _commitButton(BuildContext context) {
    final button = AbButton(
      label: counts.stagedCount == 0
          ? 'Commit'
          : 'Commit (${counts.stagedCount})',
      expand: true,
      fontSize: AbTokens.fontSm,
      fontWeight: FontWeight.w600,
      leading: AbIcon(
        AbIcons.gitCommit,
        size: AbTokens.iconButtonGlyph,
        // Match the primary variant's accentForeground label.
        color: context.antgrid.accentForeground,
      ),
      variant: AbButtonVariant.primary,
      onTap: _canCommit ? _commit : null,
    );
    final String? why;
    if (_commitBlocked) {
      why = counts.conflictPaths.length == 1
          ? 'Resolve the merge conflict before committing'
          : 'Resolve ${counts.conflictPaths.length} merge conflicts before '
                'committing';
    } else if (counts.stagedCount == 0) {
      why = 'Stage changes to commit them';
    } else {
      why = null;
    }
    if (why == null) return button;
    return AbTooltip(
      message: why,
      // A disabled child swallows no pointer here (AbButton drops its gesture
      // detector rather than absorbing), so hover still reaches the tooltip.
      triggerMode: TooltipTriggerMode.tap,
      child: button,
    );
  }
}

/// Branch name, where it stands against the remote, and Refresh.
class _BranchLine extends StatelessWidget {
  const _BranchLine({required this.sync, required this.onRefresh});

  final GitSyncState sync;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final branch = sync.branch;
    final remote = sync.remote;
    // Null branch is both "not reported yet" and "detached"; neither is a
    // branch that could be published, so no status is claimed for it.
    final Widget? status;
    if (branch == null) {
      status = null;
    } else if (!sync.hasUpstream) {
      status = _LocalOnlyPill(hasRemote: sync.hasRemote);
    } else if (remote != null && remote.isNotEmpty) {
      status = AbTooltip(
        message: 'Tracking ${sync.remoteRefLabel ?? remote}',
        child: Text(
          '→ $remote',
          maxLines: 1,
          style: AbTokens.monoStyle(fontSize: AbTokens.fontXs, color: p.textMuted),
        ),
      );
    } else {
      status = null;
    }
    return Row(
      children: [
        AbIcon(
          AbIcons.gitBranch,
          size: AbTokens.iconButtonGlyph,
          color: p.textMuted,
        ),
        const SizedBox(width: AbTokens.space8),
        Expanded(
          child: Row(
            children: [
              if (branch != null)
                Flexible(
                  child: AbTooltip(
                    message: branch,
                    child: Text(
                      branch,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: AbTokens.monoStyle(
                        fontSize: AbTokens.fontSm,
                        color: p.textPrimary,
                      ),
                    ),
                  ),
                ),
              if (status != null) ...[
                const SizedBox(width: AbTokens.space8),
                status,
              ],
            ],
          ),
        ),
        AbIconButton(
          icon: AbIcons.refresh,
          tooltip: 'Refresh',
          onTap: onRefresh,
        ),
      ],
    );
  }
}

/// The badge an unpublished branch carries in place of its upstream.
class _LocalOnlyPill extends StatelessWidget {
  const _LocalOnlyPill({required this.hasRemote});

  final bool hasRemote;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return AbTooltip(
      message: hasRemote
          ? 'Not published to the remote yet'
          : 'This repository has no remote',
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AbTokens.space8,
          vertical: AbTokens.space2,
        ),
        decoration: BoxDecoration(
          border: Border.all(color: p.borderDefault),
          borderRadius: AbTokens.borderRadiusFull,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: AbTokens.dotSizeSm,
              height: AbTokens.dotSizeSm,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: p.textMuted,
              ),
            ),
            const SizedBox(width: AbTokens.space4),
            Text(
              'Local only',
              maxLines: 1,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXs,
                color: p.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The inline commit box. Multi-line, so Enter is a newline and Ctrl/⌘+Enter
/// commits — the binding every SCM commit box shares.
class _CommitMessageField extends StatelessWidget {
  const _CommitMessageField({required this.panel, required this.onCommit});

  final _PanelContext panel;
  final VoidCallback onCommit;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true):
            onCommit,
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): onCommit,
      },
      child: AbTextField(
        controller: panel.draft,
        focusNode: panel.draftFocus,
        hintText: 'Commit message',
        minLines: 2,
        maxLines: 6,
        keyboardType: TextInputType.multiline,
        textInputAction: TextInputAction.newline,
      ),
    );
  }
}

class _ConflictNotice extends StatelessWidget {
  const _ConflictNotice({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        AbChip.system(
          label: count == 1 ? '1 conflict' : '$count conflicts',
          color: context.antgrid.gitConflict,
        ),
        const SizedBox(width: AbTokens.space8),
        Expanded(
          child: Text(
            'Resolve before committing',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontXs,
              color: context.antgrid.textMuted,
            ),
          ),
        ),
      ],
    );
  }
}

/// Pull and Push as one split control, each half labelled with its count.
///
/// Both halves stay mounted whenever the branch tracks an upstream, even when
/// one of them has nothing to do — a control that vanishes the moment its
/// count reaches zero moves its neighbour under a finger already travelling
/// toward it.
///
/// The counts are as fresh as the last fetch (see [GitSyncState]), which is
/// what Pull is for. Nothing here probes the network on its own.
class _SyncSplit extends StatelessWidget {
  const _SyncSplit({
    required this.sync,
    required this.syncing,
    required this.fileService,
  });

  final GitSyncState sync;
  final GitSyncOp? syncing;
  final FileService fileService;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    // Both are disabled while either runs: they mutate the same branch, and a
    // pull racing a push is a state neither result can describe.
    final busy = syncing != null;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: p.bgSurface,
        borderRadius: AbTokens.borderRadius5,
        border: Border.all(color: p.borderDefault),
      ),
      child: ClipRRect(
        borderRadius: AbTokens.borderRadius5,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: _SplitCell(
                icon: AbIcons.arrowDown,
                label: 'Pull',
                count: sync.behind,
                countColor: p.textMuted,
                tooltip: sync.behind > 0
                    ? 'Pull ${sync.behind} commit${sync.behind == 1 ? '' : 's'}'
                    : 'Pull',
                running: syncing == GitSyncOp.pull,
                onTap: (busy || !sync.canPull) ? null : fileService.pull,
              ),
            ),
            const AbSeparator.vertical(),
            Expanded(
              child: _SplitCell(
                icon: AbIcons.arrowUp,
                label: 'Push',
                count: sync.ahead,
                countColor: sync.ahead > 0 ? p.accent : p.textMuted,
                tooltip: sync.ahead > 0
                    ? 'Push ${sync.ahead} commit${sync.ahead == 1 ? '' : 's'}'
                    : 'Push',
                running: syncing == GitSyncOp.push,
                onTap: (busy || !sync.canPush) ? null : fileService.push,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One half of [_SyncSplit]. `onTap: null` renders it disabled in place.
class _SplitCell extends StatefulWidget {
  const _SplitCell({
    required this.icon,
    required this.label,
    required this.count,
    required this.countColor,
    required this.tooltip,
    required this.running,
    required this.onTap,
  });

  final String icon;
  final String label;
  final int count;
  final Color countColor;
  final String tooltip;

  /// This half's op is the one in flight — its glyph becomes the spinner, and
  /// it is NOT dimmed with the rest, since it is the one thing happening.
  final bool running;
  final VoidCallback? onTap;

  @override
  State<_SplitCell> createState() => _SplitCellState();
}

class _SplitCellState extends State<_SplitCell> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final enabled = widget.onTap != null;
    Widget cell = Container(
      color: enabled && _hovered ? p.bgElevated : null,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: AbTokens.space4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.running)
            const AbLoadingDot(size: AbTokens.fontXs)
          else
            AbIcon(
              widget.icon,
              size: AbTokens.fontSm,
              color: p.textSecondary,
            ),
          const SizedBox(width: AbTokens.space4),
          Flexible(
            child: Text(
              widget.label,
              maxLines: 1,
              overflow: TextOverflow.clip,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontSm,
                color: p.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: AbTokens.space4),
          Text(
            '${widget.count}',
            style: AbTokens.monoStyle(
              fontSize: AbTokens.fontXs,
              color: widget.countColor,
            ),
          ),
        ],
      ),
    );
    if (!enabled && !widget.running) {
      cell = Opacity(opacity: AbTokens.opacityDisabled, child: cell);
    }
    return AbTooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: cell,
        ),
      ),
    );
  }
}

/// The disclosure that opens and closes one of the column's two sections: a
/// chevron, the section's name, and its size.
class _SectionToggle extends StatelessWidget {
  const _SectionToggle({
    required this.label,
    required this.expanded,
    required this.onTap,
    this.count,
  });

  final String label;
  final bool expanded;
  final VoidCallback? onTap;

  /// Rendered verbatim, so a paginated list can say `50+`.
  final String? count;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final count = this.count;
    return Semantics(
      button: onTap != null,
      expanded: expanded,
      child: MouseRegion(
        cursor: onTap != null ? SystemMouseCursors.click : MouseCursor.defer,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AbDisclosureChevron(expanded: expanded),
              const SizedBox(width: AbTokens.space6),
              Text(
                label.toUpperCase(),
                maxLines: 1,
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontXxs,
                  fontWeight: FontWeight.w600,
                  color: p.textSecondary,
                  letterSpacing: 0.8,
                ),
              ),
              if (count != null) ...[
                const SizedBox(width: AbTokens.space6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AbTokens.space4,
                  ),
                  decoration: BoxDecoration(
                    color: p.bgElevated,
                    borderRadius: AbTokens.borderRadius3,
                  ),
                  child: Text(
                    count,
                    style: AbTokens.monoStyle(
                      fontSize: AbTokens.fontXxs,
                      color: p.textSecondary,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The fixed band both section headers share, so the two read as one family.
class _SectionHeaderBand extends StatelessWidget {
  const _SectionHeaderBand({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: AbTokens.rowHeightSm,
      child: Padding(
        padding: const EdgeInsets.only(
          left: AbTokens.space10,
          right: AbTokens.space8,
        ),
        child: AbCompactTapTargets(child: Row(children: children)),
      ),
    );
  }
}

/// The Changes section's header: its fold, the diff totals, and the
/// whole-tree actions — fold all folders, Revert All, Stage All.
///
/// The two write actions are icons in the order and vocabulary every SCM
/// panel uses (revert, then +). Both stay mounted while anything is changed,
/// even when one has nothing to do — a Stage All that vanishes the moment the
/// last file is staged slides its neighbour under the finger travelling
/// toward it. Each is gated on its OWN scope for the same reason: a tree of
/// nothing but conflicts has nothing safe to revert, and is exactly where
/// Stage All is the way out.
class _ChangesSectionHeader extends StatelessWidget {
  const _ChangesSectionHeader({
    required this.counts,
    required this.fileService,
    required this.collapsedPaths,
    required this.expanded,
    required this.onToggle,
  });

  final GitStatusIndex counts;
  final FileService fileService;

  /// Folders currently folded shut. Only used to decide which way the fold
  /// toggle points, so an unhydrated Git pane (empty set) correctly offers to
  /// collapse rather than to expand.
  final Set<String> collapsedPaths;
  final bool expanded;
  final VoidCallback onToggle;

  // Collapse All hands this very set to FileService, so until a folder is
  // reopened the answer is identity rather than a walk over every folder.
  bool get _allFoldersCollapsed =>
      counts.changedFolders.isNotEmpty &&
      (identical(collapsedPaths, counts.changedFolders) ||
          collapsedPaths.containsAll(counts.changedFolders));

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

  @override
  Widget build(BuildContext context) {
    final showStat = counts.additions > 0 || counts.deletions > 0;
    final allFoldersCollapsed = _allFoldersCollapsed;
    return _SectionHeaderBand(
      children: [
        _SectionToggle(
          label: 'Changes',
          count: '${counts.changedCount}',
          expanded: expanded,
          onTap: onToggle,
        ),
        const SizedBox(width: AbTokens.space6),
        // The one part of the band that may give way: the totals are also on
        // the workspace menu, while every control here is the only way to do
        // what it does. Clipped by a non-scrolling view rather than overflowing.
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const NeverScrollableScrollPhysics(),
            child: Row(
              key: gitChangesHeaderTitleKey,
              children: [
                if (showStat)
                  AbDiffStat(
                    additions: counts.additions,
                    deletions: counts.deletions,
                    fontSize: AbTokens.fontXs,
                  ),
              ],
            ),
          ),
        ),
        // Its own control, gated separately from the write pair: a tree of
        // nothing but conflicts is exactly when folding a long list is wanted.
        // It names the RESULT of pressing it (the VS Code convention), not the
        // current state — the tree itself already shows which folders are open.
        if (counts.changedFolders.isNotEmpty)
          AbIconButton(
            icon: allFoldersCollapsed
                ? AbIcons.expandAll
                : AbIcons.collapseAll,
            tooltip: allFoldersCollapsed
                ? 'Expand All Folders'
                : 'Collapse All Folders',
            onTap: () => fileService.setGitCollapsedFolders(
              allFoldersCollapsed ? const {} : counts.changedFolders,
            ),
          ),
        AbIconButton(
          icon: AbIcons.revert,
          tooltip: 'Revert All Changes',
          onTap: counts.revertablePaths.isEmpty
              ? null
              : () => _revertAll(context),
        ),
        AbIconButton(
          icon: AbIcons.gitStage,
          tooltip: 'Stage All Changes',
          onTap: counts.unstagedPaths.isEmpty
              ? null
              : () => _stageAll(context),
        ),
      ],
    );
  }
}

/// The History section's header — its fold, and Collapse All for commits
/// expanded in the list. No bulk "expand all": expanding a commit fetches its
/// file list, so expanding every loaded commit at once would fire one request
/// per row for a list the user hasn't scrolled to yet.
class _GitHistorySectionHeader extends StatelessWidget {
  const _GitHistorySectionHeader({
    required this.fileService,
    required this.history,
    required this.collapsed,
    required this.onToggleCollapsed,
  });

  final FileService fileService;
  final GitHistoryState history;

  /// Whether the WHOLE section is folded shut — see
  /// [GitPaneState.historyCollapsed]. Distinct from
  /// [GitHistoryState.expandedShas], which folds individual commits within an
  /// already-visible list — "Collapse All" below acts on that, not on this.
  final bool collapsed;
  final VoidCallback onToggleCollapsed;

  @override
  Widget build(BuildContext context) {
    final loaded = history.commits.length;
    return _SectionHeaderBand(
      children: [
        _SectionToggle(
          label: 'History',
          count: loaded == 0 ? null : '$loaded${history.hasMore ? '+' : ''}',
          expanded: !collapsed,
          onTap: onToggleCollapsed,
        ),
        const Spacer(),
        if (!collapsed && history.expandedShas.isNotEmpty)
          AbIconButton(
            icon: AbIcons.collapseAll,
            tooltip: 'Collapse All',
            onTap: fileService.collapseAllHistory,
          ),
      ],
    );
  }
}

/// The strip a failed push or pull leaves behind, and the one tap that hands
/// it to the agent.
///
/// It persists rather than auto-dismissing: the toast that already fired says
/// what happened, and this says what can be done about it — which is worth
/// nothing if it disappears while the user is still reading the toast.
class _SyncFailureStrip extends ConsumerWidget {
  const _SyncFailureStrip({required this.failure, required this.git});

  final GitSyncFailure failure;
  final GitPaneState git;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AbInlineBanner(
      text: '${failure.op.label} failed — ${failure.message}',
      color: context.antgrid.gitConflict,
      trailing: failure.warrantsAgent
          ? AbButton(
              label: 'Ask agent to fix',
              // A tap handler discards the future it starts, so a rejection
              // inside the dialog or the send would reach
              // `PlatformDispatcher.onError` as a fatal with no in-app frames.
              onTap: () => detached(
                'GitPanel',
                'hand sync failure to agent',
                () => _handOff(context, ref),
              ),
            )
          : null,
    );
  }

  Future<void> _handOff(BuildContext context, WidgetRef ref) async {
    // Read the entries here rather than holding them on the strip: the dialog
    // stays open indefinitely, and what the agent should be told about the
    // working tree is what it holds when the message is composed.
    final entries =
        ref.read(fileTreeStateProvider).value?.gitFileEntries ?? const [];
    await offerSyncFailureToAgent(
      context: context,
      container: ref.container,
      failure: failure,
      sync: git.sync,
      changed: entries,
    );
  }
}

/// The compact layout's bar while a diff or file replaces the column: the way
/// back, and which file this is.
class _CompactViewerBar extends StatelessWidget {
  const _CompactViewerBar({required this.path, required this.onBack});

  final String? path;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final path = this.path;
    return SizedBox(
      height: AbTokens.rowHeightSm,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AbTokens.space8),
        child: AbCompactTapTargets(
          child: Row(
            children: [
              AbIconButton(
                icon: AbIcons.back,
                onTap: onBack,
                tooltip: 'Back to changed files',
              ),
              const SizedBox(width: AbTokens.space6),
              if (path != null)
                Expanded(
                  child: Text(
                    path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AbTokens.monoStyle(
                      fontSize: AbTokens.fontXs,
                      color: context.antgrid.textMuted,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GitPanelBody extends ConsumerWidget {
  const _GitPanelBody({
    required this.state,
    required this.panel,
    required this.counts,
  });

  final FileTreeState state;
  final _PanelContext panel;

  /// Read off the index rather than re-derived: the [LayoutBuilder] below
  /// re-runs on every resize.
  final GitStatusIndex counts;

  FileService get fileService => panel.fileService;

  /// Docked width of the column beside the viewer.
  static const double _columnWidth = 300; // non-ladder: design spec

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final showSideBySide = constraints.maxWidth >= kCompactBreakpoint;
        final git = state.git;
        final isViewing = git.diffPath != null || git.viewingPath != null;

        if (showSideBySide) {
          return Row(
            children: [
              SizedBox(
                width: _columnWidth,
                child: _buildColumn(context),
              ),
              const AbSeparator.vertical(weight: AbSeparatorWeight.strong),
              Expanded(child: _buildContentArea(context, ref)),
            ],
          );
        }

        // Compact: the viewer replaces the column while a diff or file is open.
        if (isViewing) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _CompactViewerBar(
                path: git.diffPath ?? git.viewingPath,
                onBack: () {
                  fileService.clearDiff();
                  fileService.clearGitViewing();
                },
              ),
              const AbSeparator.horizontal(),
              Expanded(child: _buildContentArea(context, ref)),
            ],
          );
        }
        return _buildColumn(context);
      },
    );
  }

  /// The branch bar, then Changes over History. With both sections open they
  /// split the column 3:2 and scroll independently, so seeing what changed and
  /// seeing how it got there never costs a tap to switch between. A folded
  /// section shrinks to its header and the open one takes the rest; folding
  /// History leaves its header bottom-anchored under the tree.
  ///
  /// With no working-tree changes the Changes section is dropped entirely
  /// rather than showing an empty tree, and History attaches directly under
  /// the branch bar.
  Widget _buildColumn(BuildContext context) {
    final git = state.git;
    final hasChanges = counts.hasChanges;
    final changesOpen = hasChanges && !panel.changesCollapsed;
    final historyOpen = !git.historyCollapsed;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Above the branch bar: it says whose changes the rest of the panel
        // is about, so it has to be read before anything the bar counts.
        const _TaskContextStrip(),
        _GitBranchBar(panel: panel, counts: counts, git: git),
        if (git.lastSyncFailure case final failure?)
          _SyncFailureStrip(failure: failure, git: git),
        const AbSeparator.horizontal(),
        if (hasChanges) ...[
          _ChangesSectionHeader(
            counts: counts,
            fileService: fileService,
            collapsedPaths: git.collapsedPaths,
            expanded: changesOpen,
            onToggle: panel.onToggleChanges,
          ),
          if (changesOpen)
            Expanded(
              flex: historyOpen ? 3 : 1,
              child: _buildFileList(context),
            ),
          const AbSeparator.horizontal(),
        ],
        _GitHistorySectionHeader(
          fileService: fileService,
          history: git.history,
          collapsed: !historyOpen,
          onToggleCollapsed: fileService.toggleHistoryCollapsed,
        ),
        if (historyOpen) ...[
          const AbSeparator.horizontal(),
          Expanded(
            flex: changesOpen ? 2 : 1,
            child: _HistoryList(git: git, fileService: fileService),
          ),
        ] else if (!changesOpen)
          const Spacer(),
      ],
    );
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
        gitStatus: state.gitStatus,
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
    final entries = state.gitStatus.byPath[path] ?? const [];
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
    final entries = state.gitStatus.byPath[path] ?? const [];
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

  Widget _buildContentArea(BuildContext context, WidgetRef ref) {
    final git = state.git;
    if (git.diffPath != null) {
      if (git.diffLoading) {
        return const AbLoading();
      }
      if (git.diffContent != null) {
        // A commit-scoped diff's status letter comes from that commit's own
        // file list, never `state.gitFileStatuses` — the working tree's
        // status for the same path (or none at all) describes a different
        // change.
        final commitSha = git.diffCommitSha;
        final gitStatus = commitSha == null
            ? state.gitFileStatuses[git.diffPath!]
            : git.history.filesBySha[commitSha]
                  ?.where((f) => f.path == git.diffPath)
                  .firstOrNull
                  ?.status;
        return DiffViewer(
          path: git.diffPath!,
          gitStatus: gitStatus,
          diff: git.diffContent!,
          additions: git.diffAdditions ?? 0,
          deletions: git.diffDeletions ?? 0,
          onViewFile: () => fileService.gitViewFile(git.diffPath!),
          onClose: () => fileService.clearDiff(),
          onSendToAgent: (context, message) => sendCaptureToAgent(
            context: context,
            container: ref.container,
            text: message,
          ),
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

/// The History section's scrollable commit list, in its own [Expanded] slot
/// under [_GitHistorySectionHeader]. Each commit can expand in place to a
/// file list (more than one at once — see [GitHistoryState]); the list itself
/// paginates via [FileService.loadMoreHistory] as the user scrolls near its
/// end, the same "ask for more before you hit the wall" margin a fling can
/// cover in one frame.
class _HistoryList extends StatefulWidget {
  const _HistoryList({required this.git, required this.fileService});

  final GitPaneState git;
  final FileService fileService;

  @override
  State<_HistoryList> createState() => _HistoryListState();
}

class _HistoryListState extends State<_HistoryList> {
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    // A hovered row's tooltip is a fixed-position overlay entry — it has no
    // idea the list under it just moved, since a scroll carries no pointer
    // event to tell it the target left the cursor. Left alone it lingers
    // over the row's new (scrolled) position until its own show timer
    // expires, reading as the tooltip sliding toward the list's edge and
    // popping off.
    Tooltip.dismissAllToolTips();
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 400) {
      widget.fileService.loadMoreHistory();
    }
  }

  @override
  Widget build(BuildContext context) {
    final history = widget.git.history;
    if (history.initialLoad && history.commits.isEmpty) {
      return const AbLoading(message: 'loading history...');
    }
    if (history.error != null && history.commits.isEmpty) {
      return AbEmptyState.error(
        title: 'Could not load history',
        subtitle: history.error,
        action: AbButton(
          label: 'Retry',
          compact: true,
          onTap: widget.fileService.loadHistory,
        ),
      );
    }
    if (history.commits.isEmpty) {
      return const AbEmptyState(
        title: 'No commits yet',
        icon: AbIcons.gitCommit,
      );
    }

    return RefreshIndicator(
      onRefresh: () async {
        widget.fileService.loadHistory();
        await Future.delayed(const Duration(milliseconds: 500));
      },
      child: ListView.builder(
        controller: _scrollController,
        itemCount: history.commits.length + 1,
        itemBuilder: (context, index) {
          if (index == history.commits.length) {
            return _HistoryFooter(
              history: history,
              fileService: widget.fileService,
            );
          }
          final commit = history.commits[index];
          final expanded = history.expandedShas.contains(commit.sha);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _CommitHeaderRow(
                commit: commit,
                expanded: expanded,
                onTap: () =>
                    widget.fileService.toggleCommitExpanded(commit.sha),
              ),
              if (expanded)
                _CommitFilesSection(
                  sha: commit.sha,
                  files: history.filesBySha[commit.sha],
                  loading: history.filesLoadingShas.contains(commit.sha),
                  error: history.filesErrorBySha[commit.sha],
                  openPath: widget.git.diffCommitSha == commit.sha
                      ? widget.git.diffPath
                      : null,
                  fileService: widget.fileService,
                ),
              const AbSeparator.horizontal(),
            ],
          );
        },
      ),
    );
  }
}

/// The trailing row of the history list: a spinner while the next page loads,
/// a retry affordance if it failed, "No more commits" once [hasMore] is
/// false, or nothing while there's more to scroll to but nothing is loading
/// yet.
class _HistoryFooter extends StatelessWidget {
  const _HistoryFooter({required this.history, required this.fileService});

  final GitHistoryState history;
  final FileService fileService;

  @override
  Widget build(BuildContext context) {
    if (history.loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: AbTokens.space16),
        child: Center(child: AbLoadingDot()),
      );
    }
    if (history.error != null) {
      return Padding(
        padding: const EdgeInsets.all(AbTokens.space12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              history.error!,
              textAlign: TextAlign.center,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXs,
                color: context.antgrid.error,
              ),
            ),
            const SizedBox(height: AbTokens.space8),
            AbButton(
              label: 'Retry',
              compact: true,
              onTap: fileService.loadMoreHistory,
            ),
          ],
        ),
      );
    }
    if (!history.hasMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AbTokens.space16),
        child: Center(
          child: Text(
            'No more commits',
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontXs,
              color: context.antgrid.textMuted,
            ),
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}

/// One commit's row: a graph-rail dot, its subject, and the author/date/sha
/// meta line. Tapping anywhere on the row toggles the file list beneath it;
/// long-pressing opens a copy-SHA menu — the touch replacement for a desktop
/// row's spare icon buttons, which a phone-width row has no room for.
class _CommitHeaderRow extends StatelessWidget {
  const _CommitHeaderRow({
    required this.commit,
    required this.expanded,
    required this.onTap,
  });

  final GitLogEntry commit;
  final bool expanded;
  final VoidCallback onTap;

  Future<void> _showActions(BuildContext context, Offset globalPosition) async {
    final action = await showAbMenu<String>(
      context: context,
      anchorRect: Rect.fromCenter(center: globalPosition, width: 1, height: 1),
      header: commit.shortSha,
      entries: const [
        AbMenuItem(label: 'Copy full SHA', icon: AbIcons.copy, value: 'sha'),
        AbMenuItem(
          label: 'Copy short SHA',
          icon: AbIcons.copy,
          value: 'shortSha',
        ),
      ],
    );
    if (!context.mounted || action == null) return;
    await Clipboard.setData(
      ClipboardData(text: action == 'sha' ? commit.sha : commit.shortSha),
    );
    if (context.mounted) showAbToast(context, 'Copied to clipboard');
  }

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final when = DateTime.tryParse(commit.authorDate);
    return GestureDetector(
      // A void callback discards whatever future it starts — see
      // util/detached.dart — so a rejected `showAbMenu`/clipboard write would
      // otherwise reach `PlatformDispatcher.onError` as an unattributed fatal.
      onLongPressStart: (details) => detached(
        'GitPanel',
        'commit history long-press actions',
        () => _showActions(context, details.globalPosition),
      ),
      // The rail's line segments fill the row via Expanded, which needs a
      // determinate height to resolve against — IntrinsicHeight measures the
      // row's natural (title+subtitle) height first and hands that down,
      // the same trick AbSegmented uses to stretch its own cell dividers.
      child: IntrinsicHeight(
        child: AbListRow(
          onTap: onTap,
          hoverable: true,
          density: AbRowDensity.md,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          titleMaxLines: 2,
          leading: _CommitRail(expanded: expanded),
          // A commit subject clips at 2 lines; the tooltip is the only way to
          // read the rest of a longer one, matching VS Code's history hover.
          title: AbTooltip(
            message: commit.subject,
            child: Text(commit.subject),
          ),
          // Author and time share one Expanded, not a Flexible beside a Spacer:
          // two flex children split the free space evenly, the author leaves
          // its half unused, and the sha landed mid-row at a spot set by the
          // author's name length rather than at the edge.
          subtitle: Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        commit.authorName,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: AbTokens.space6),
                    if (when != null)
                      AbTooltip(
                        message: absoluteTime(when),
                        child: Text(relativeTime(when)),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: AbTokens.space8),
              Text(
                commit.shortSha,
                style: AbTokens.monoStyle(
                  fontSize: AbTokens.fontXxs,
                  color: p.textMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The History list's graph rail: one continuous line down the column with a
/// dot at each commit, filled with the accent while that commit is expanded.
///
/// Each row draws only its own short segment (top half-line, dot, bottom
/// half-line), stretched to that row's height by the [IntrinsicHeight] in
/// [_CommitHeaderRow] — with consecutive commit rows sitting flush against
/// the hairline [AbSeparator] between them, the segments read as one
/// unbroken rail with no cross-row layout coordination needed. The rail does
/// NOT continue through an expanded commit's file list, the same way a git
/// graph doesn't draw through expanded detail.
class _CommitRail extends StatelessWidget {
  const _CommitRail({required this.expanded});

  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final line = Expanded(child: Container(width: 1.5, color: p.borderDefault));
    return SizedBox(
      width: 16,
      child: Column(
        children: [
          line,
          Container(
            width: 7,
            height: 7,
            margin: const EdgeInsets.symmetric(vertical: 3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: expanded ? p.accent : p.textMuted,
            ),
          ),
          line,
        ],
      ),
    );
  }
}

/// One expanded commit's file list — loading, an error with retry, an empty
/// result (a commit with no diff, e.g. an empty merge), or the files
/// themselves. Indented under the commit row it belongs to.
class _CommitFilesSection extends StatelessWidget {
  const _CommitFilesSection({
    required this.sha,
    required this.files,
    required this.loading,
    required this.error,
    required this.openPath,
    required this.fileService,
  });

  final String sha;
  final List<GitCommitFileEntry>? files;
  final bool loading;
  final String? error;
  final String? openPath;
  final FileService fileService;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: AbTokens.space12),
        child: Center(child: AbLoadingDot()),
      );
    }
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AbTokens.space16,
          vertical: AbTokens.space8,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                error!,
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontXs,
                  color: context.antgrid.error,
                ),
              ),
            ),
            AbButton(
              label: 'Retry',
              compact: true,
              onTap: () => fileService.retryCommitFiles(sha),
            ),
          ],
        ),
      );
    }
    final entries = files ?? const <GitCommitFileEntry>[];
    if (entries.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AbTokens.space16,
          vertical: AbTokens.space8,
        ),
        child: Text(
          'No file changes',
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontXs,
            color: context.antgrid.textMuted,
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final file in entries)
          _CommitFileRow(
            sha: sha,
            file: file,
            selected: file.path == openPath,
            onTap: () => fileService.requestCommitDiff(sha, file.path),
          ),
      ],
    );
  }
}

/// One file within an expanded commit — status letter, path, and a diff stat.
/// Tapping it opens that file's diff for this specific commit.
class _CommitFileRow extends StatelessWidget {
  const _CommitFileRow({
    required this.sha,
    required this.file,
    required this.selected,
    required this.onTap,
  });

  final String sha;
  final GitCommitFileEntry file;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return AbListRow(
      onTap: onTap,
      hoverable: true,
      selected: selected,
      selectionStyle: AbRowSelection.surface,
      density: AbRowDensity.sm,
      // Indented under the commit's own leading rail so the file list
      // reads as nested content, matching the depth-indent the Changes tab's
      // folder tree uses for the same reason.
      horizontalPadding: AbTokens.space12 + AbTokens.space16,
      leading: SizedBox(
        width: 14,
        child: Text(
          file.status,
          textAlign: TextAlign.center,
          style: AbTokens.monoStyle(
            fontSize: AbTokens.fontXs,
            fontWeight: FontWeight.w600,
            color: gitStatusColor(context, file.status),
          ),
        ),
      ),
      // A long path clips to the row's width with no way to read the rest of
      // it — the hover tooltip is what VS Code's own changed-files list shows
      // in exactly this spot.
      title: AbTooltip(
        message: file.path,
        child: Text(
          file.path,
          style: AbTokens.monoStyle(color: selected ? p.accent : p.textPrimary),
        ),
      ),
      subtitle: file.oldPath != null
          ? AbTooltip(message: file.oldPath!, child: Text(file.oldPath!))
          : null,
      trailing: (file.additions > 0 || file.deletions > 0)
          ? AbDiffStat(
              additions: file.additions,
              deletions: file.deletions,
              fontSize: AbTokens.fontXxs,
            )
          : null,
    );
  }
}
