import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_avatar.dart';
import '../../design/widgets/ab_icon.dart';
import '../../design/widgets/ab_label_chip.dart';
import '../../design/widgets/ab_list_row.dart';
import '../../models/task.dart';
import '../../providers/tasks.dart';
import 'task_provenance_view.dart';
import 'task_status_view.dart';

/// One task, dense enough to scan a triage queue down.
///
/// Meta goes in [AbListRow.trailing] rather than `actions`: `actions` is a typed
/// list of icon buttons and the row asserts the two are exclusive, so a row has
/// meta OR row actions. Meta wins — the actions live in the long-press sheet.
class TaskRow extends ConsumerWidget {
  const TaskRow({
    super.key,
    required this.task,
    this.selected = false,
    this.onTap,
    this.onLongPress,
    this.showStatusLabel = false,
    this.showProject = true,
    this.twoLine = false,
  });

  final Task task;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// The labelled pill instead of the leading dot. Worth ~80px, so it belongs
  /// only where the status is actually carrying information — the unscoped list
  /// and the detail header, not the four scoped views where it is implied.
  final bool showStatusLabel;

  /// Dropped when the list is already scoped to one project.
  final bool showProject;

  /// Phone layout: title on the first line, meta on the second.
  final bool twoLine;

  /// Beyond this the labels collapse to a count — a row that wraps stops being
  /// scannable, which is the only thing it is for.
  static const _maxLabelChips = 2;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final run = ref.watch(taskRunPresenceProvider)[task.number];
    final meta = _meta(context, ref, run);

    return AbListRow(
      density: AbRowDensity.md,
      hoverable: true,
      selected: selected,
      selectionStyle: AbRowSelection.accentBar,
      divider: true,
      onTap: onTap,
      onLongPress: onLongPress,
      leading: showStatusLabel ? null : TaskStatusDot(status: task.status),
      title: Row(
        children: [
          if (showStatusLabel) ...[
            TaskStatusPill(status: task.status),
            const SizedBox(width: AbTokens.space8),
          ],
          Text(
            task.ref,
            style: AbTokens.monoStyle(
              fontSize: AbTokens.fontXs,
              color: context.antgrid.textMuted,
            ),
          ),
          const SizedBox(width: AbTokens.space8),
          Expanded(
            child: Text(
              task.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontSm,
                color: task.status.isClosed
                    ? context.antgrid.textMuted
                    : context.antgrid.textPrimary,
              ),
            ),
          ),
        ],
      ),
      subtitle: twoLine ? meta : null,
      trailing: twoLine ? null : meta,
    );
  }

  Widget _meta(BuildContext context, WidgetRef ref, TaskRunPresence? run) {
    final palette = context.antgrid;
    final projectName = task.projectId == null
        ? null
        : ref.watch(taskProjectNamesProvider)[task.projectId] ??
              _shortId(task.projectId!);
    final labelBudget = twoLine ? 1 : _maxLabelChips;
    final shown = task.labels.take(labelBudget).toList(growable: false);
    final overflow = task.labels.length - shown.length;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Ahead of the labels rather than beside the title: the row must stay
        // one line and the title must not shift by whether a task was
        // imported, or the list stops being scannable down its left edge.
        if (!task.isLocal) ...[
          TaskProvenanceMark(task: task),
          const SizedBox(width: AbTokens.space6),
        ],
        for (final label in shown) ...[
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _labelChipMaxWidth),
            child: AbLabelChip(label: label.name, colorHex: label.color),
          ),
          const SizedBox(width: AbTokens.space4),
        ],
        if (overflow > 0) ...[
          Text(
            '+$overflow',
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontXxs,
              color: palette.textMuted,
            ),
          ),
          const SizedBox(width: AbTokens.space6),
        ],
        _assignee(context),
        // A count, not an avatar stack: the row is a scanning surface and
        // these are provider identities the account cannot even name. Who they
        // are is the detail sheet's answer.
        if (task.otherAssignees.isNotEmpty) ...[
          const SizedBox(width: AbTokens.space4),
          Text(
            '+${task.otherAssignees.length}',
            style: AbTokens.monoStyle(
              fontSize: AbTokens.fontXxs,
              color: palette.textMuted,
            ),
          ),
        ],
        if (run != null) ...[
          const SizedBox(width: AbTokens.space8),
          TaskRunMark(run: run),
        ],
        if (showProject && projectName != null) ...[
          const SizedBox(width: AbTokens.space8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _projectMaxWidth),
            child: Text(
              projectName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AbTokens.monoStyle(
                fontSize: AbTokens.fontXxs,
                color: palette.textMuted,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _assignee(BuildContext context) {
    final assignee = task.assignee;
    return switch (assignee) {
      null => AbIcon(
        AbIcons.unassigned,
        size: _avatarSize,
        color: context.antgrid.iconMuted,
      ),
      TaskMemberAssignee() => AbAvatar(
        name: assignee.userId,
        size: _avatarSize,
      ),
      // An imported provider identity with no Antgrid account: its login is the
      // only name there is, so it renders as one rather than as initials that
      // would read like a member.
      TaskExternalAssignee() => Text(
        '@${assignee.login}',
        style: AbTokens.monoStyle(
          fontSize: AbTokens.fontXxs,
          color: context.antgrid.textMuted,
        ),
      ),
    };
  }

  /// Enough of a uuid to tell two projects apart without pretending it is a
  /// name. Mono, because it is an id.
  static String _shortId(String id) =>
      id.length <= 8 ? id : id.substring(0, 8);

  static const _avatarSize = 18.0;
  static const _labelChipMaxWidth = 110.0;
  static const _projectMaxWidth = 90.0;
}
