import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_adaptive_sheet.dart';
import '../../design/widgets/ab_confirm_dialog.dart';
import '../../design/widgets/ab_icon.dart';
import '../../design/widgets/ab_icon_button.dart';
import '../../design/widgets/ab_label_chip.dart';
import '../../design/widgets/ab_list_row.dart';
import '../../design/widgets/ab_select_sheet.dart';
import '../../design/widgets/ab_separator.dart';
import '../../models/task.dart';
import '../../providers/tasks.dart';
import 'task_status_view.dart';

/// Row actions on long-press.
///
/// A sheet, not a swipe: swipe-to-act would mean `Dismissible`, whose look is
/// Material and whose gesture fights the mobile page-swipe between the agent
/// and the workspace.
///
/// [neighbours] is the list AS RENDERED, which is what a move is relative to —
/// the server reorders against the two rows the task lands between, and those
/// are the rows the user can see.
Future<void> showTaskRowActions(
  BuildContext context,
  WidgetRef ref, {
  required Task task,
  required List<Task> neighbours,
}) async {
  final action = await showAbAdaptiveSheet<_RowAction>(
    context,
    child: _TaskRowActionsSheet(task: task, canMove: neighbours.length > 1),
  );
  if (action == null || !context.mounted) return;
  final tasks = ref.read(taskListProvider.notifier);
  final index = neighbours.indexWhere((t) => t.number == task.number);

  switch (action) {
    case _RowAction.status:
      final picked = await showAbSelect<TaskStatus>(
        context,
        title: 'Status',
        single: true,
        options: [
          for (final status in TaskStatus.values)
            AbSelectOption(
              value: status,
              label: status.label,
              leading: TaskStatusDot(status: status),
            ),
        ],
        selected: {task.status},
      );
      final next = picked?.firstOrNull;
      if (next != null && next != task.status) {
        await tasks.setStatus(task.number, next);
      }
    case _RowAction.assignToMe:
      final me = ref.read(taskAssigneeCandidatesProvider).firstOrNull;
      if (me != null) {
        await tasks.setAssignee(task.number, TaskMemberAssignee(me.userId));
      }
    case _RowAction.unassign:
      await tasks.setAssignee(task.number, null);
    case _RowAction.labels:
      await editTaskLabels(context, ref, task);
    case _RowAction.moveUp:
      if (index > 0) {
        await tasks.move(
          task.number,
          previousNumber: index >= 2 ? neighbours[index - 2].number : null,
          nextNumber: neighbours[index - 1].number,
        );
      }
    case _RowAction.moveDown:
      if (index >= 0 && index < neighbours.length - 1) {
        await tasks.move(
          task.number,
          previousNumber: neighbours[index + 1].number,
          nextNumber: index + 2 < neighbours.length
              ? neighbours[index + 2].number
              : null,
        );
      }
    case _RowAction.delete:
      if (!context.mounted) return;
      final confirmed = await showTaskDeleteConfirm(context, task);
      if (confirmed) {
        if (ref.read(selectedTaskNumberProvider) == task.number) {
          ref.read(selectedTaskNumberProvider.notifier).select(null);
        }
        await tasks.delete(task.number);
      }
  }
}

/// Delete confirmation, shared by the row sheet and the detail's own button so
/// the wording of an irreversible action cannot drift between the two places it
/// is offered.
Future<bool> showTaskDeleteConfirm(BuildContext context, Task task) {
  return AbConfirmDialog.show(
    context: context,
    title: 'Delete ${task.ref}?',
    body: 'This removes the task from the account. It cannot be undone from '
        'the app.',
    confirmLabel: 'Delete task',
    destructive: true,
  );
}

/// The label editor: multi-select over the account's labels, committed as one
/// replace so a set edit is one write rather than a burst of attach/detach.
Future<void> editTaskLabels(
  BuildContext context,
  WidgetRef ref,
  Task task,
) async {
  final all = await ref.read(taskLabelsProvider.future);
  if (!context.mounted) return;
  final picked = await showAbSelect<String>(
    context,
    title: 'Labels',
    emptyMessage: 'This account has no labels yet',
    options: [
      for (final label in all)
        AbSelectOption(
          value: label.id,
          label: label.name,
          detail: label.description,
          leading: _LabelDot(colorHex: label.color),
        ),
    ],
    selected: task.labels.map((l) => l.id).toSet(),
  );
  if (picked == null) return;
  final before = task.labels.map((l) => l.id).toSet();
  if (before.length == picked.length && before.containsAll(picked)) return;
  await ref
      .read(taskListProvider.notifier)
      .setLabels(
        task.number,
        all.where((l) => picked.contains(l.id)).toList(growable: false),
      );
}

class _LabelDot extends StatelessWidget {
  const _LabelDot({required this.colorHex});

  final String colorHex;

  @override
  Widget build(BuildContext context) {
    final color = abLabelColor(colorHex);
    return Container(
      width: AbTokens.dotSizeMd,
      height: AbTokens.dotSizeMd,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color ?? const Color(0x00000000),
        border: Border.all(color: context.antgrid.borderStrong),
      ),
    );
  }
}

enum _RowAction {
  status,
  assignToMe,
  unassign,
  labels,
  moveUp,
  moveDown,
  delete,
}

class _TaskRowActionsSheet extends StatelessWidget {
  const _TaskRowActionsSheet({required this.task, required this.canMove});

  final Task task;
  final bool canMove;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AbTokens.space12,
            AbTokens.space8,
            AbTokens.space8,
            AbTokens.space8,
          ),
          child: Row(
            children: [
              Text(
                task.ref,
                style: AbTokens.monoStyle(fontSize: AbTokens.fontXs),
              ),
              const SizedBox(width: AbTokens.space8),
              Expanded(
                child: Text(
                  task.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AbTokens.sansStyle(fontSize: AbTokens.fontSm),
                ),
              ),
              AbIconButton(
                icon: AbIcons.close,
                tooltip: 'Close',
                onTap: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        const AbSeparator.horizontal(),
        _action(context, AbIcons.circle, 'Change status', _RowAction.status),
        if (task.assignee == null)
          _action(context, AbIcons.account, 'Assign to me', _RowAction.assignToMe)
        else
          _action(context, AbIcons.unassigned, 'Unassign', _RowAction.unassign),
        _action(context, AbIcons.tag, 'Edit labels', _RowAction.labels),
        if (canMove) ...[
          _action(context, AbIcons.arrowUp, 'Move up', _RowAction.moveUp),
          _action(context, AbIcons.arrowDown, 'Move down', _RowAction.moveDown),
        ],
        const AbSeparator.horizontal(),
        _action(context, AbIcons.trash, 'Delete task', _RowAction.delete),
      ],
    );
  }

  Widget _action(
    BuildContext context,
    String icon,
    String label,
    _RowAction action,
  ) {
    return AbListRow(
      density: AbRowDensity.lg,
      hoverable: true,
      leading: AbIcon(
        icon,
        size: AbTokens.iconButtonGlyph,
        color: context.antgrid.iconMuted,
      ),
      title: Text(label),
      onTap: () => Navigator.of(context).pop(action),
    );
  }
}
