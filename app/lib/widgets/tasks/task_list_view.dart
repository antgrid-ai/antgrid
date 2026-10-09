import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_button.dart';
import '../../design/widgets/ab_control_box.dart';
import '../../design/widgets/ab_empty_state.dart';
import '../../design/widgets/ab_icon.dart';
import '../../design/widgets/ab_icon_button.dart';
import '../../design/widgets/ab_inline_banner.dart';
import '../../design/widgets/ab_label_chip.dart';
import '../../design/widgets/ab_loading.dart';
import '../../design/widgets/ab_menu.dart';
import '../../design/widgets/ab_search_field.dart';
import '../../design/widgets/ab_separator.dart';
import '../../models/task.dart';
import '../../providers/tasks.dart';
import '../../services/tasks_api.dart';
import '../../util/detached.dart';
import '../new_session/environment_menu.dart'
    show PanelHint, PanelRow, PanelSectionHeader;
import 'task_create_sheet.dart';
import 'task_row.dart';
import 'task_row_actions.dart';

/// The account task list: scope, filters, rows.
///
/// One list widget behind every entry point — the account-level surface and a
/// project-scoped one are the same rows with a different filter, never two
/// lists that can drift.
class TaskListView extends ConsumerStatefulWidget {
  const TaskListView({
    super.key,
    this.onOpen,
    this.compact = false,
    this.showProject = true,
    this.siblingDetailNumber,
  });

  /// Called with the task number the row wants opened. The master–detail split
  /// selects; a phone pushes a route. The list itself does neither.
  final ValueChanged<int>? onOpen;

  /// Phone metrics: two-line rows, and the filter row collapses.
  final bool compact;

  final bool showProject;

  /// The task number a `TaskDetailView` is ALREADY showing beside this list,
  /// on the desktop master–detail split — never inferred from
  /// [selectedTaskNumberProvider] alone, which a phone leaves set after
  /// popping the detail route, where no sibling pane exists to be showing
  /// anything. Null everywhere else, including the phone's stacked list,
  /// which is the only place a mutation failure is visible at all.
  final int? siblingDetailNumber;

  @override
  ConsumerState<TaskListView> createState() => _TaskListViewState();
}

/// How often a visible list refetches. The list is a mirror of what teammates
/// and GitHub change, with no push channel behind it, so a list that only
/// refreshes on a button press reads as truth long after it stopped being.
const _autoRefreshEvery = Duration(seconds: 60);

class _TaskListViewState extends ConsumerState<TaskListView>
    with WidgetsBindingObserver {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(_autoRefreshEvery, (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  void _refresh() {
    // A refetch under an unsent mutation would land the server's older copy
    // over the optimistic one.
    if (ref.read(taskMutationErrorProvider) != null) return;
    detached(
      'tasks',
      'auto refresh',
      ref.read(taskListProvider.notifier).refresh,
    );
  }

  @override
  Widget build(BuildContext context) {
    final siblingDetailNumber = widget.siblingDetailNumber;
    final filter = ref.watch(taskFilterProvider);
    final tasks = ref.watch(visibleTasksProvider);
    final selected = ref.watch(selectedTaskNumberProvider);
    final failure = ref.watch(taskMutationErrorProvider);
    // The detail pane already shows this exact failure (with the same Retry)
    // whenever its task is the one open in the sibling pane — stacking the
    // list's own copy on top reads as the same error happening twice.
    final showFailureHere =
        failure != null &&
        (failure.taskNumber == null ||
            failure.taskNumber != siblingDetailNumber);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _ViewBar(),
        const _FilterBar(),
        if (showFailureHere) _MutationBanner(failure: failure),
        const AbSeparator.horizontal(),
        Expanded(
          // A failed refresh keeps the list the user was reading and says so in
          // a banner; only a list that never loaded gets the full error state.
          child: tasks.hasError && tasks.value == null
              ? _ListError(error: tasks.error!)
              : tasks.value == null
              ? const AbLoading(message: 'Loading tasks…')
              : _buildList(
                  context,
                  tasks.value!,
                  tasks.error,
                  filter,
                  selected,
                ),
        ),
      ],
    );
  }

  Widget _buildList(
    BuildContext context,
    List<Task> list,
    Object? refreshError,
    TaskFilter filter,
    int? selected,
  ) {
    final onOpen = widget.onOpen;
    final compact = widget.compact;
    final showProject = widget.showProject;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (refreshError != null)
          _RefreshFailedBanner(error: refreshError, onRetry: _refresh),
        Expanded(
          child: list.isEmpty
              ? _EmptyForScope(filter: filter)
              : ListView.builder(
                  itemCount: list.length,
                  itemBuilder: (context, i) {
                    final task = list[i];
                    return TaskRow(
                      task: task,
                      selected: task.number == selected,
                      showStatusLabel:
                          !compact && filter.scope == TaskScope.allOpen,
                      showProject: showProject,
                      twoLine: compact,
                      onTap: () => onOpen?.call(task.number),
                      onLongPress: () => detached(
                        'tasks',
                        'row actions',
                        () => showTaskRowActions(
                          context,
                          ref,
                          task: task,
                          neighbours: list,
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _RefreshFailedBanner extends StatelessWidget {
  const _RefreshFailedBanner({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final api = error is TaskApiException ? error as TaskApiException : null;
    return AbInlineBanner(
      text: api?.error == TaskApiError.network
          ? 'Offline — showing the last list you loaded.'
          : 'Could not refresh — showing the last list you loaded.',
      color: context.antgrid.warning,
      trailing: AbButton(label: 'Retry', compact: true, onTap: onRetry),
    );
  }
}

/// The list's header: which view, plus refresh and new-task actions.
///
/// One dropdown, not a row of tabs: five views overflowed a 380px pane and had
/// to scroll, and the dropdown has room to say how many tasks each holds.
class _ViewBar extends ConsumerWidget {
  const _ViewBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = ref.watch(taskFilterProvider.select((f) => f.scope));
    final counts = ref.watch(taskFacetCountsProvider).byScope;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AbTokens.space12,
        AbTokens.space12,
        AbTokens.space8,
        0,
      ),
      child: Row(
        children: [
          Expanded(
            child: _FilterDropdown(
              prefix: 'View',
              label: scope.label,
              count: counts[scope],
              onTap: (anchor) => detached(
                'tasks',
                'pick view',
                () => _pick(context, ref, anchor),
              ),
            ),
          ),
          const SizedBox(width: AbTokens.space8),
          AbIconButton(
            icon: AbIcons.refresh,
            tooltip: 'Refresh tasks',
            // Projects alongside the tasks: `taskProjectsProvider` is fetched
            // once at sign-in and otherwise never refetched, so a project
            // bound after that (a newly opened repo, a fresh GitHub link)
            // stays invisible to every picker fed by it until something
            // invalidates it. A manual refresh is that something.
            onTap: () => detached('tasks', 'refresh list', () {
              ref.invalidate(taskProjectsProvider);
              ref.invalidate(taskUnlinkedReposProvider);
              return ref.read(taskListProvider.notifier).refresh();
            }),
          ),
          AbIconButton(
            icon: AbIcons.add,
            tooltip: 'New task',
            onTap: () => detached(
              'tasks',
              'open create sheet',
              () => showTaskCreateSheet(context),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pick(BuildContext context, WidgetRef ref, Rect anchor) async {
    final container = ref.container;
    final picked = await showAbPanel<TaskScope>(
      context: context,
      anchorRect: anchor,
      width: anchor.width,
      builder: (_) => const _ViewPanel(),
    );
    if (picked == null) return;
    container.read(taskFilterProvider.notifier).setScope(picked);
  }
}

class _ViewPanel extends ConsumerWidget {
  const _ViewPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = ref.watch(taskFilterProvider.select((f) => f.scope));
    final counts = ref.watch(taskFacetCountsProvider).byScope;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PanelSectionHeader('View'),
        for (final s in TaskScope.values)
          PanelRow(
            icon: AbIcons.tasks,
            label: s.label,
            mono: false,
            selected: s == scope,
            trailing: counts[s] == null ? null : _PanelCount(counts[s]!),
            onTap: () => Navigator.of(context).pop(s),
          ),
      ],
    );
  }
}

class _FilterBar extends ConsumerWidget {
  const _FilterBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(taskFilterProvider.notifier);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AbTokens.space12,
        AbTokens.space8,
        AbTokens.space12,
        AbTokens.space10,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AbSearchField(
            hint: 'Filter these tasks',
            height: AbTokens.rowHeightXs,
            onChanged: controller.setQuery,
            onClear: () => controller.setQuery(''),
          ),
          const SizedBox(height: AbTokens.space8),
          // Status lives in the view above; these two only narrow it. Each
          // names its own selection, so no row of active chips or separate
          // "Clear" is needed — the empty state carries the reset.
          const Row(
            children: [
              Expanded(child: _RepoFilter()),
              SizedBox(width: AbTokens.space8),
              Expanded(child: _LabelFilter()),
            ],
          ),
        ],
      ),
    );
  }
}

/// A full-width menu trigger: what is chosen, optionally how many rows it
/// holds, and a chevron. Shares [AbControlBox] with the search field above it
/// so the header reads as one set of controls.
class _FilterDropdown extends StatelessWidget {
  const _FilterDropdown({
    required this.label,
    required this.onTap,
    this.prefix,
    this.count,
    this.active = false,
  });

  final String? prefix;
  final String label;
  final int? count;

  /// A narrowing filter is applied — painted like a selected chip, so a
  /// filtered list never passes for the whole view.
  final bool active;
  final ValueChanged<Rect> onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.antgrid;
    TextStyle style(Color color) => AbTokens.monoStyle(
      fontSize: AbTokens.fontXs,
      color: color,
      letterSpacing: 0.6,
    );
    return Builder(
      builder: (anchorContext) => MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            final anchor = abMenuAnchorRect(anchorContext);
            if (anchor != null) onTap(anchor);
          },
          child: AbControlBox(
            height: AbTokens.rowHeightXs,
            focused: active,
            child: Row(
              children: [
                // One flex child only: a Spacer beside a Flexible label would
                // take half the spare width and ellipsize a label that fits.
                Expanded(
                  child: Row(
                    children: [
                      if (prefix != null) ...[
                        Text(
                          prefix!.toUpperCase(),
                          style: style(palette.textMuted),
                        ),
                        const SizedBox(width: AbTokens.space8),
                      ],
                      Flexible(
                        child: Text(
                          label.toUpperCase(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: style(palette.textPrimary),
                        ),
                      ),
                      if (count != null) ...[
                        const SizedBox(width: AbTokens.space8),
                        Text('$count', style: style(palette.textMuted)),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: AbTokens.space6),
                AbIcon(
                  AbIcons.chevronDown,
                  size: AbTokens.iconButtonGlyph,
                  color: palette.textMuted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PanelCount extends StatelessWidget {
  const _PanelCount(this.count);

  final int count;

  @override
  Widget build(BuildContext context) => Text(
    '$count',
    style: AbTokens.monoStyle(
      fontSize: AbTokens.fontXs,
      color: context.antgrid.textMuted,
    ),
  );
}

/// Narrows the list to one account project — the "repo" a drawer row's
/// `repoKey` resolves to via [taskProjectIdByRepoKeyProvider]. Read/write
/// [TaskFilter.projectId] directly rather than through [taskQueryProvider]'s
/// server query: the fetch stays wide (see [TaskFilter.serverQuery]) so the
/// drawer's per-project nodes are never emptied by a scope picked here, and
/// this filter narrows the same client-side pass [visibleTasksProvider] does.
class _RepoFilter extends ConsumerWidget {
  const _RepoFilter();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repoId = ref.watch(taskFilterProvider.select((f) => f.projectId));
    final names = ref.watch(taskProjectNamesProvider);
    // Watched only to have it loaded by the time the panel opens — the panel
    // reads it once, and a FutureProvider nobody watches never fetches.
    ref.watch(taskUnlinkedReposProvider);
    return _FilterDropdown(
      label: repoId == null ? 'All repos' : (names[repoId] ?? 'Unknown repo'),
      active: repoId != null,
      onTap: (anchor) =>
          detached('tasks', 'repo filter', () => _pick(context, ref, anchor)),
    );
  }

  Future<void> _pick(BuildContext context, WidgetRef ref, Rect anchor) async {
    final container = ref.container;
    final picked = await showAbPanel<Object?>(
      context: context,
      anchorRect: anchor,
      width: 260,
      builder: (_) => _RepoFilterPanel(
        unlinked: container.read(taskUnlinkedReposProvider).value ?? const [],
      ),
    );
    // Dismissed (tap-outside / Esc) rather than a pick — leave the filter
    // alone. Distinct from picking "All repos", which pops [_kAllRepos] to
    // ask for a real clear.
    if (picked == null) return;
    container
        .read(taskFilterProvider.notifier)
        .setProject(identical(picked, _kAllRepos) ? null : picked as String);
  }
}

/// Several labels can be held at once, so picking one leaves the panel open
/// and toggles it in place; the trigger then names the selection.
class _LabelFilter extends ConsumerWidget {
  const _LabelFilter();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final labels = ref.watch(taskLabelsProvider).value ?? const <TaskLabel>[];
    final active = ref.watch(taskFilterProvider.select((f) => f.labelIds));
    final String label;
    if (active.isEmpty) {
      label = 'All labels';
    } else if (active.length == 1) {
      label =
          labels.where((l) => l.id == active.first).firstOrNull?.name ??
          'Label · 1';
    } else {
      label = 'Labels · ${active.length}';
    }
    return _FilterDropdown(
      label: label,
      active: active.isNotEmpty,
      onTap: (anchor) => detached(
        'tasks',
        'label filter',
        () => showAbPanel<void>(
          context: context,
          anchorRect: anchor,
          width: 240,
          builder: (_) => const _LabelFilterPanel(),
        ),
      ),
    );
  }
}

class _LabelFilterPanel extends ConsumerWidget {
  const _LabelFilterPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final labels = ref.watch(taskLabelsProvider).value ?? const <TaskLabel>[];
    final selected = ref.watch(taskFilterProvider.select((f) => f.labelIds));
    final counts = ref.watch(taskFacetCountsProvider).byLabel;
    final controller = ref.read(taskFilterProvider.notifier);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PanelSectionHeader('Label'),
        if (labels.isEmpty)
          const PanelHint('This account has no labels yet')
        else
          for (final label in labels)
            PanelRow(
              icon: AbIcons.tag,
              leading: AbLabelDot(colorHex: label.color),
              mono: false,
              label: label.name,
              selected: selected.contains(label.id),
              trailing: _PanelCount(counts[label.id] ?? 0),
              onTap: () => controller.toggleLabel(label.id),
            ),
        if (selected.isNotEmpty) ...[
          const AbSeparator.horizontal(),
          PanelRow(
            icon: AbIcons.close,
            label: 'Clear labels',
            mono: false,
            selected: false,
            onTap: controller.clearLabels,
          ),
        ],
      ],
    );
  }
}

/// Popped by the "All repos" row to mean "clear the filter" — distinct from
/// the popup's own null-on-dismiss, which must leave the filter untouched.
const Object _kAllRepos = Object();

class _RepoFilterPanel extends ConsumerWidget {
  const _RepoFilterPanel({required this.unlinked});

  /// Repos the GitHub App can see with no folder opened for them yet. Shown
  /// inert: a filter on one could only ever be empty, but knowing it is there
  /// is what tells the user which folder to open next.
  final List<UnlinkedRepo> unlinked;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final names = ref.watch(taskProjectNamesProvider);
    final selected = ref.watch(taskFilterProvider.select((f) => f.projectId));
    final counts = ref.watch(taskFacetCountsProvider).byProject;
    final inView = counts.values.fold(0, (a, b) => a + b);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PanelSectionHeader('Repo'),
        PanelRow(
          icon: AbIcons.folder,
          label: 'All repos',
          selected: selected == null,
          trailing: _PanelCount(inView),
          onTap: () => Navigator.of(context).pop(_kAllRepos),
        ),
        if (names.isEmpty && unlinked.isEmpty)
          const PanelHint('No repos are bound to this account yet')
        else
          for (final entry in names.entries)
            PanelRow(
              icon: AbIcons.folder,
              label: entry.value,
              selected: entry.key == selected,
              trailing: _PanelCount(counts[entry.key] ?? 0),
              onTap: () => Navigator.of(context).pop(entry.key),
            ),
        if (unlinked.isNotEmpty) ...[
          const PanelSectionHeader('No folder yet'),
          for (final repo in unlinked)
            // A null onTap is the row's disabled state, not a missing handler.
            PanelRow(
              icon: AbIcons.folder,
              label: repo.name,
              selected: false,
              onTap: null,
            ),
          const PanelHint('Open or clone a repo to file tasks against it'),
        ],
      ],
    );
  }
}

class _MutationBanner extends ConsumerWidget {
  const _MutationBanner({required this.failure});

  final TaskMutationFailure failure;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final retry = failure.retry;
    return AbInlineBanner(
      // Reverted, with the reason and a way to try again — a silent snap-back
      // is indistinguishable from a mis-tap.
      text: failure.error.message,
      color: context.antgrid.warning,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (retry != null)
            AbButton(
              label: 'Retry',
              compact: true,
              onTap: () => detached('tasks', 'retry mutation', retry),
            ),
          const SizedBox(width: AbTokens.space4),
          AbIconButton(
            icon: AbIcons.close,
            tooltip: 'Dismiss',
            onTap: () => ref.read(taskMutationErrorProvider.notifier).set(null),
          ),
        ],
      ),
    );
  }
}

class _ListError extends ConsumerWidget {
  const _ListError({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = error is TaskApiException ? error as TaskApiException : null;
    return AbEmptyState.error(
      title: api?.message ?? 'Tasks could not be loaded.',
      subtitle: api?.error == TaskApiError.network
          // The distinction the UI must not blur: every dev machine can be
          // offline and the list still works. The network being offline is a
          // different failure, and this is it.
          ? 'The task list needs the internet, not a running machine.'
          : null,
      action: AbButton(
        label: 'Retry',
        onTap: () => detached(
          'tasks',
          'retry list load',
          () => ref.read(taskListProvider.notifier).refresh(),
        ),
      ),
    );
  }
}

class _EmptyForScope extends ConsumerWidget {
  const _EmptyForScope({required this.filter});

  final TaskFilter filter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(taskFilterProvider.notifier);
    if (filter.hasNarrowingFilters) {
      return AbEmptyState(
        icon: AbIcons.filter,
        title: 'No tasks match these filters.',
        action: AbButton(label: 'Reset filters', onTap: controller.resetAll),
      );
    }
    return switch (filter.scope) {
      TaskScope.mine => AbEmptyState(
        icon: AbIcons.tasks,
        title: 'Nothing assigned to you',
        action: AbButton(
          label: 'Browse unassigned',
          onTap: () => controller.setScope(TaskScope.unassigned),
        ),
      ),
      TaskScope.running => AbEmptyState(
        icon: AbIcons.tasks,
        title: 'No agents are working a task right now',
        action: AbButton(
          label: 'Browse open tasks',
          onTap: () => controller.setScope(TaskScope.allOpen),
        ),
      ),
      TaskScope.unassigned => AbEmptyState(
        icon: AbIcons.tasks,
        title: 'Nothing is waiting to be picked up',
        action: AbButton(
          label: 'Browse open tasks',
          onTap: () => controller.setScope(TaskScope.allOpen),
        ),
      ),
      TaskScope.done => const AbEmptyState(
        icon: AbIcons.tasks,
        title: 'Nothing has been closed yet',
      ),
      TaskScope.allOpen => AbEmptyState(
        icon: AbIcons.tasks,
        title: 'No tasks yet',
        action: AbButton(
          label: 'New task',
          onTap: () => detached(
            'tasks',
            'open create sheet',
            () => showTaskCreateSheet(context),
          ),
        ),
      ),
    };
  }
}
