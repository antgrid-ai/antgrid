import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_disclosure_chevron.dart';
import '../design/widgets/ab_list_row.dart';
import '../models/task.dart';
import '../providers/drawer_expansion.dart';
import '../providers/tasks.dart';
import 'tasks/task_status_view.dart';
import 'tasks/tasks_surface.dart';

/// The open tasks for one project, nested under its row in the drawer.
///
/// Renders NOTHING rather than an empty node in all three of the ways this can
/// have nothing to say — a folder with no origin remote, a repository the
/// account has no project bound to yet, and a project whose open list is empty.
/// A permanently-blank child on every row is pure chrome, and filing a task is
/// the account surface's job, not the tree's.
///
/// Reads its rows from [openTasksForProjectProvider], which partitions the one
/// account-scoped store: no fetch of its own, and no dependency on any bridge
/// being up. Tasks arrive over HTTPS, so this node is as live with every dev
/// machine offline as it is with all of them running.
class ProjectTasksNode extends ConsumerWidget {
  const ProjectTasksNode({
    super.key,
    required this.repoKey,
    required this.expansionId,
  });

  /// The row's repository identity, as the host folded it from the origin
  /// remote. Null for a folder without one, or a host too old to send it.
  final String? repoKey;

  /// This node's key in [expandedDrawerIdsProvider]. Callers pass a dotted id
  /// so it can never be read as a bare machine uuid by the control-plane
  /// keep-alive set, which counts only those.
  final String expansionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = repoKey;
    if (key == null || key.isEmpty) return const SizedBox.shrink();

    final projectId = ref.watch(taskProjectIdByRepoKeyProvider)[key];
    if (projectId == null) return const SizedBox.shrink();

    final tasks = ref.watch(openTasksForProjectProvider(projectId));
    if (tasks.isEmpty) return const SizedBox.shrink();

    final expanded = ref.watch(expandedDrawerIdsProvider).contains(expansionId);
    final t = context.antgrid;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AbTokens.drawerGutter,
          ),
          child: AbListRow(
            horizontalPadding: 0,
            density: AbRowDensity.sm,
            hoverable: true,
            leading: AbDisclosureChevron(expanded: expanded),
            title: Text(
              'Tasks',
              overflow: TextOverflow.ellipsis,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontSm,
                color: t.textSecondary,
              ),
            ),
            // The count is the whole point of the collapsed state: it says
            // whether opening the node is worth a click without opening it.
            trailing: Text(
              '${tasks.length}',
              style: AbTokens.monoStyle(
                fontSize: AbTokens.fontXs,
                color: t.textMuted,
              ),
            ),
            margin: const EdgeInsets.symmetric(vertical: AbTokens.space2),
            onTap: () => ref
                .read(expandedDrawerIdsProvider.notifier)
                .toggle(expansionId),
          ),
        ),
        if (expanded)
          for (final task in tasks)
            _DrawerTaskRow(key: ValueKey(task.number), task: task),
      ],
    );
  }
}

/// One task inside the node. Deliberately not [TaskRow]: that row is built for
/// the tasks surface and carries labels, provenance and a divider, none of
/// which survive the drawer's width. Reference plus title is what a tree needs.
class _DrawerTaskRow extends ConsumerWidget {
  const _DrawerTaskRow({super.key, required this.task});

  final Task task;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.antgrid;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AbTokens.space6),
      child: AbListRow(
        density: AbRowDensity.sm,
        hoverable: true,
        leading: SizedBox(
          width: AbTokens.drawerLeadingSlot,
          height: AbTokens.drawerLeadingSlot,
          child: Center(child: TaskStatusDot(status: task.status)),
        ),
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
        margin: const EdgeInsets.symmetric(vertical: AbTokens.space2),
        // Select before opening: the surface reads the selection on build, so
        // setting it after would land on the list with nothing chosen.
        onTap: () {
          ref.read(selectedTaskNumberProvider.notifier).select(task.number);
          showTasks(context);
        },
      ),
    );
  }
}
