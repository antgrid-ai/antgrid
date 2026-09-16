import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_button.dart';
import '../../design/widgets/ab_chip.dart';
import '../../design/widgets/ab_empty_state.dart';
import '../../design/widgets/ab_fade_scroll.dart';
import '../../design/widgets/ab_icon_button.dart';
import '../../design/widgets/ab_inline_banner.dart';
import '../../design/widgets/ab_label_chip.dart';
import '../../design/widgets/ab_loading.dart';
import '../../design/widgets/ab_menu.dart';
import '../../design/widgets/ab_search_field.dart';
import '../../design/widgets/ab_segmented.dart';
import '../../design/widgets/ab_separator.dart';
import '../../models/task.dart';
import '../../providers/tasks.dart';
import '../../services/tasks_api.dart';
import '../../util/detached.dart';
import '../new_session/environment_menu.dart' show PanelHint, PanelRow, PanelSectionHeader;
import 'task_create_sheet.dart';
import 'task_row.dart';
import 'task_row_actions.dart';

/// The account task list: scope, filters, rows.
///
/// One list widget behind every entry point — the account-level surface and a
/// project-scoped one are the same rows with a different filter, never two
/// lists that can drift.
class TaskListView extends ConsumerWidget {
  const TaskListView({
    super.key,
    this.onOpen,
    this.compact = false,
    this.showProject = true,
  });

  /// Called with the task number the row wants opened. The master–detail split
  /// selects; a phone pushes a route. The list itself does neither.
  final ValueChanged<int>? onOpen;

  /// Phone metrics: two-line rows, and the filter row collapses.
  final bool compact;

  final bool showProject;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(taskFilterProvider);
    final tasks = ref.watch(visibleTasksProvider);
    final selected = ref.watch(selectedTaskNumberProvider);
    final failure = ref.watch(taskMutationErrorProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _ScopeBar(),
        const AbSeparator.horizontal(),
        _FilterBar(compact: compact),
        if (failure != null) _MutationBanner(failure: failure),
        const AbSeparator.horizontal(),
        Expanded(
          child: tasks.when(
            skipLoadingOnReload: true,
            // Never an empty state during a fetch: a cold app showing "no tasks
            // yet" is the dead first impression the whole surface works to
            // avoid.
            loading: () => const AbLoading(message: 'Loading tasks…'),
            error: (error, _) => _ListError(error: error),
            data: (list) => list.isEmpty
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
        ),
      ],
    );
  }
}

class _ScopeBar extends ConsumerWidget {
  const _ScopeBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(taskFilterProvider);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AbTokens.space12,
        vertical: AbTokens.space8,
      ),
      child: Row(
        children: [
          Expanded(
            // Five scopes overflow a narrow context panel, and a wrapped
            // primary control reads as two rows of unrelated chips. Scrolling
            // keeps them one control; the fade says there's more rather than
            // letting DONE clip mid-glyph against the pane edge.
            child: AbFadeScroll(
              children: [
                AbSegmented<TaskScope>(
                  segments: [
                    for (final scope in TaskScope.values)
                      AbSegment(value: scope, label: scope.label),
                  ],
                  selected: filter.scope,
                  onSelect: (scope) =>
                      ref.read(taskFilterProvider.notifier).setScope(scope),
                ),
              ],
            ),
          ),
          const SizedBox(width: AbTokens.space8),
          AbIconButton(
            icon: AbIcons.refresh,
            tooltip: 'Refresh tasks',
            onTap: () => detached(
              'tasks',
              'refresh list',
              () => ref.read(taskListProvider.notifier).refresh(),
            ),
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
}

class _FilterBar extends ConsumerWidget {
  const _FilterBar({required this.compact});

  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(taskFilterProvider);
    final labels = ref.watch(taskLabelsProvider).value ?? const <TaskLabel>[];
    final controller = ref.read(taskFilterProvider.notifier);
    final activeLabels = labels
        .where((l) => filter.labelIds.contains(l.id))
        .toList(growable: false);

    // Repo scoping stays outside the compact-narrowing gate: it is how this
    // list becomes the per-project view the drawer node used to be the only
    // way to reach, so it must be reachable with zero other filters active.
    final showStatusRow = !compact || filter.hasNarrowingFilters;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AbTokens.space12,
        AbTokens.space6,
        AbTokens.space12,
        AbTokens.space8,
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
          const SizedBox(height: AbTokens.space6),
          // Repo, status and label chips share one scrollable row — folding
          // what used to be two stacked rows into one buys the list back a
          // full row of height without dropping any filter. "Clear filters"
          // sits fixed at the trailing edge, outside the scroll: it's the
          // only escape hatch once several chips are active, so it must stay
          // reachable without scrolling past them to find it.
          Row(
            children: [
              Expanded(
                child: AbFadeScroll(
                  children: [
                    const _RepoFilterChip(),
                    if (showStatusRow) ...[
                      const SizedBox(width: AbTokens.space8),
                      for (final status in TaskStatus.values)
                        Padding(
                          padding: const EdgeInsets.only(
                            right: AbTokens.space4,
                          ),
                          child: AbChip.toggle(
                            label: status.label,
                            selected: filter.statuses.contains(status),
                            onTap: () => controller.toggleStatus(status),
                          ),
                        ),
                      // Only the labels already in the filter appear here;
                      // the rest are reached from a row's chip or the
                      // detail's editor, which is where the user is already
                      // looking at them.
                      for (final label in activeLabels)
                        Padding(
                          padding: const EdgeInsets.only(
                            right: AbTokens.space4,
                          ),
                          child: AbLabelChip(
                            label: label.name,
                            colorHex: label.color,
                            selected: true,
                            onTap: () => controller.toggleLabel(label.id),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
              if (filter.hasNarrowingFilters) ...[
                const SizedBox(width: AbTokens.space6),
                AbButton(
                  label: 'Clear filters',
                  compact: true,
                  onTap: controller.clearFilters,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// Narrows the list to one account project — the "repo" a drawer row's
/// `repoKey` resolves to via [taskProjectIdByRepoKeyProvider]. Read/write
/// [TaskFilter.projectId] directly rather than through [taskQueryProvider]'s
/// server query: the fetch stays wide (see [TaskFilter.serverQuery]) so the
/// drawer's per-project nodes are never emptied by a scope picked here, and
/// this filter narrows the same client-side pass [visibleTasksProvider] does.
///
/// An anchored popup (`showAbPanel`), not a dialog — the same chrome the New
/// Session composer's project picker uses (`widgets/new_session/project_menu.dart`'s
/// `PanelRow` rows), so a handful of repo names doesn't cost a full-screen
/// sheet.
class _RepoFilterChip extends ConsumerWidget {
  const _RepoFilterChip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repoId = ref.watch(taskFilterProvider.select((f) => f.projectId));
    final names = ref.watch(taskProjectNamesProvider);
    final label = repoId == null
        ? 'All repos'
        : (names[repoId] ?? 'Unknown repo');
    return AbChip.toggle(
      label: label,
      selected: repoId != null,
      onTap: () => _pick(context, ref, names),
    );
  }

  Future<void> _pick(
    BuildContext context,
    WidgetRef ref,
    Map<String, String> names,
  ) async {
    final anchor = abMenuAnchorRect(context);
    if (anchor == null) return;
    final picked = await showAbPanel<Object?>(
      context: context,
      anchorRect: anchor,
      builder: (_) => _RepoFilterPanel(
        names: names,
        selected: ref.read(taskFilterProvider).projectId,
      ),
    );
    // Dismissed (tap-outside / Esc) rather than a pick — leave the filter
    // alone. Distinct from picking "All repos", which pops [_kAllRepos] to
    // ask for a real clear.
    if (picked == null) return;
    ref
        .read(taskFilterProvider.notifier)
        .setProject(identical(picked, _kAllRepos) ? null : picked as String);
  }
}

/// Popped by the "All repos" row to mean "clear the filter" — distinct from
/// the popup's own null-on-dismiss, which must leave the filter untouched.
const Object _kAllRepos = Object();

class _RepoFilterPanel extends StatelessWidget {
  const _RepoFilterPanel({required this.names, required this.selected});

  final Map<String, String> names;
  final String? selected;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PanelSectionHeader('Repo'),
        PanelRow(
          icon: AbIcons.folder,
          label: 'All repos',
          selected: selected == null,
          onTap: () => Navigator.of(context).pop(_kAllRepos),
        ),
        if (names.isEmpty)
          const PanelHint('No repos are bound to this account yet')
        else
          for (final entry in names.entries)
            PanelRow(
              icon: AbIcons.folder,
              label: entry.value,
              selected: entry.key == selected,
              onTap: () => Navigator.of(context).pop(entry.key),
            ),
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
        title: 'No tasks match these filters',
        action: AbButton(
          label: 'Clear filters',
          onTap: controller.clearFilters,
        ),
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
