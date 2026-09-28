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
    final labelBudget = twoLine ? 1 : _maxLabelChips;
    final shownLabels = task.labels.take(labelBudget).toList(growable: false);
    final labelOverflow = task.labels.length - shownLabels.length;
    final meta = _meta(context, ref, run, shownLabels, labelOverflow);

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
          // The label and provenance mark trail the (possibly now truncated)
          // title itself in the two-line layout, rather than sitting on the
          // meta line below with who it's for and which project it's in —
          // what a task IS belongs beside its title; who it's for is a
          // different question, answered on the line built for it. The wide
          // desktop row has no second line to split onto, so `_meta` keeps
          // carrying both there, unchanged.
          if (twoLine) ..._titleBadges(context, shownLabels, labelOverflow),
        ],
      ),
      subtitle: twoLine ? meta : null,
      trailing: twoLine ? null : meta,
    );
  }

  List<Widget> _titleBadges(
    BuildContext context,
    List<TaskLabel> shown,
    int overflow,
  ) {
    final palette = context.antgrid;
    return [
      for (final label in shown) ...[
        const SizedBox(width: AbTokens.space6),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _labelChipMaxWidth),
          child: AbLabelChip(label: label.name, colorHex: label.color),
        ),
      ],
      if (overflow > 0) ...[
        const SizedBox(width: AbTokens.space4),
        Text(
          '+$overflow',
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontXxs,
            color: palette.textMuted,
          ),
        ),
      ],
      if (!task.isLocal) ...[
        const SizedBox(width: AbTokens.space6),
        TaskProvenanceMark(task: task),
      ],
      // Ignores `isLocal` on purpose — see the mark's own doc comment.
      if (task.isPushDisconnected) ...[
        const SizedBox(width: AbTokens.space6),
        TaskSyncBrokenMark(task: task),
      ],
      // Unassigned is a fact ABOUT the task, same standing as its provenance —
      // not an answer to "who is this for" that belongs on the line built for
      // that question. `_assignee` still renders it there for the wide
      // desktop row, which has no second line to split it onto.
      if (task.assignee == null) ...[
        const SizedBox(width: AbTokens.space6),
        AbIcon(
          AbIcons.unassigned,
          size: AbTokens.iconButtonGlyph,
          color: palette.iconMuted,
        ),
      ],
    ];
  }

  Widget _meta(
    BuildContext context,
    WidgetRef ref,
    TaskRunPresence? run,
    List<TaskLabel> shown,
    int overflow,
  ) {
    final palette = context.antgrid;
    final projectName = task.projectId == null
        ? null
        : ref.watch(taskProjectNamesProvider)[task.projectId] ??
              _shortId(task.projectId!);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // In the two-line layout the label and provenance mark already sit
        // beside the title (see `_titleBadges`) — only the wide desktop row
        // still carries them here, ahead of who the task is for, so the row
        // stays one line and the title never shifts by whether a task was
        // imported.
        if (!twoLine) ...[
          if (!task.isLocal) ...[
            TaskProvenanceMark(task: task),
            const SizedBox(width: AbTokens.space6),
          ],
          // Ignores `isLocal` on purpose — see the mark's own doc comment.
          if (task.isPushDisconnected) ...[
            TaskSyncBrokenMark(task: task),
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
        ],
        // In the two-line layout an unassigned task already said so up on the
        // title line (see `_titleBadges`); a real assignee still belongs down
        // here regardless of layout.
        if (!twoLine || task.assignee != null) _assignee(context),
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
          // A `·`, not a bare gap, only where the two-line layout's second
          // line already has something to its left — who it's for and where
          // it lives are two different fields on the same line, and the dot
          // is what tells them apart. The wide row keeps a plain gap: there
          // provenance and labels always precede it, so the line never opens
          // with the project chip the way an unassigned two-line row can.
          if (twoLine &&
              (task.assignee != null ||
                  task.otherAssignees.isNotEmpty ||
                  run != null)) ...[
            const SizedBox(width: AbTokens.space6),
            Text(
              '·',
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXxs,
                color: palette.textMuted,
              ),
            ),
            const SizedBox(width: AbTokens.space6),
          ] else
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
      // would read like a member. Capped: an unbounded login is what turned a
      // two-line row's second line — assignee, then the project it's paired
      // with — into a real overflow the moment both fields were long.
      TaskExternalAssignee() => ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _assigneeMaxWidth),
        child: Text(
          '@${assignee.login}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AbTokens.monoStyle(
            fontSize: AbTokens.fontXxs,
            color: context.antgrid.textMuted,
          ),
        ),
      ),
    };
  }

  /// Enough of a uuid to tell two projects apart without pretending it is a
  /// name. Mono, because it is an id.
  static String _shortId(String id) =>
      id.length <= 8 ? id : id.substring(0, 8);

  static const _avatarSize = 18.0;
  static const _assigneeMaxWidth = 140.0;
  static const _labelChipMaxWidth = 110.0;
  static const _projectMaxWidth = 90.0;
}
