import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_list_row.dart';
import '../models/task.dart';
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
///
/// Always shows its rows once there are any — no collapse to click through.
/// A task outlives any session opened against it and is exactly the kind of
/// thing worth seeing without an extra tap; the header below is a label, not
/// a control.
class ProjectTasksNode extends ConsumerWidget {
  const ProjectTasksNode({super.key, required this.repoKey});

  /// The row's repository identity, as the host folded it from the origin
  /// remote. Null for a folder without one, or a host too old to send it.
  final String? repoKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = repoKey;
    if (key == null || key.isEmpty) return const SizedBox.shrink();

    final projectId = ref.watch(taskProjectIdByRepoKeyProvider)[key];
    if (projectId == null) return const SizedBox.shrink();

    final tasks = ref.watch(openTasksForProjectProvider(projectId));
    if (tasks.isEmpty) return const SizedBox.shrink();

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
            title: Text(
              'Tasks',
              overflow: TextOverflow.ellipsis,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontSm,
                color: t.textSecondary,
              ),
            ),
            trailing: Text(
              '${tasks.length}',
              style: AbTokens.monoStyle(
                fontSize: AbTokens.fontXs,
                color: t.textMuted,
              ),
            ),
            margin: const EdgeInsets.symmetric(vertical: AbTokens.space2),
          ),
        ),
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
        // Blank, not removed: the slot keeps this row's title flush with the
        // sessions listed below it, which reserve the same width for their
        // own leading mark.
        leading: const SizedBox(
          width: AbTokens.drawerLeadingSlot,
          height: AbTokens.drawerLeadingSlot,
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
        trailing: TaskStatusPill(status: task.status, compact: true),
        margin: const EdgeInsets.symmetric(vertical: AbTokens.space2),
        onTap: () => openTasks(context, ref, select: task.number),
      ),
    );
  }
}
