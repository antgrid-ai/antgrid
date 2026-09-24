import 'package:flutter/widgets.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_status_tone.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_icon.dart';
import '../../design/widgets/ab_status_dot.dart';
import '../../design/widgets/ab_task_status_pill.dart';
import '../../models/agent_work_status.dart';
import '../../models/task.dart';
import '../../providers/tasks.dart';
import '../agent_work_status_dot.dart';

/// Task status → tone. The domain enum maps to a tone here rather than to a
/// colour, per [AbStatusTone]'s own rule.
///
/// `success` for `done` does not violate that enum's rest rule: the rule keeps
/// a dormant AGENT from wearing a green check, and a task marked done is a
/// completion claim a person made.
AbStatusTone taskStatusTone(TaskStatus status) => switch (status) {
  TaskStatus.open => AbStatusTone.neutral,
  TaskStatus.inProgress => AbStatusTone.info,
  TaskStatus.blocked => AbStatusTone.warning,
  TaskStatus.done => AbStatusTone.success,
  TaskStatus.cancelled => AbStatusTone.disabled,
};

/// The labelled form. Persistent and user-owned, which is why it is a pill and
/// the agent's liveness is a dot — two status systems on one row must never
/// share a shape.
class TaskStatusPill extends StatelessWidget {
  const TaskStatusPill({super.key, required this.status, this.compact = false});

  final TaskStatus status;
  final bool compact;

  @override
  Widget build(BuildContext context) => AbTaskStatusPill(
    label: status.label,
    tone: taskStatusTone(status),
    compact: compact,
  );
}

/// The narrow form, for the scoped views where the status is near-redundant and
/// the list is only a few hundred pixels wide.
class TaskStatusDot extends StatelessWidget {
  const TaskStatusDot({super.key, required this.status});

  final TaskStatus status;

  @override
  Widget build(BuildContext context) => AbStatusDot(
    tone: taskStatusTone(status),
    size: AbDotSize.sm,
    style: status == TaskStatus.open ? AbDotStyle.hollow : AbDotStyle.filled,
  );
}

/// The live-run slot on a row: the agent's mark beside its liveness dot.
///
/// [AgentWorkStatus.attention] outranks everything else here — an agent blocked
/// on a permission is a person's turn, and it has to be readable without
/// opening the task. So attention gets a warning-toned glyph rather than the
/// generic pulse the other live states share.
class TaskRunMark extends StatelessWidget {
  const TaskRunMark({super.key, required this.run, this.showLabel = false});

  final TaskRunPresence run;

  /// Adds the word beside the glyph. For the detail header and the wide row,
  /// not the narrow list.
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final palette = context.antgrid;
    final isAttention = run.status == AgentWorkStatus.attention;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (isAttention)
          AbIcon(
            AbIcons.warning,
            size: AbTokens.iconButtonGlyph,
            color: palette.warning,
          )
        else
          AgentWorkStatusDot(status: run.status),
        if (showLabel) ...[
          const SizedBox(width: AbTokens.space4),
          Text(
            _label(run.status),
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontXxs,
              fontWeight: isAttention ? FontWeight.w600 : FontWeight.w500,
              color: isAttention ? palette.warning : palette.textMuted,
            ),
          ),
        ],
      ],
    );
  }

  static String _label(AgentWorkStatus status) => switch (status) {
    AgentWorkStatus.attention => 'Waiting on you',
    AgentWorkStatus.working => 'Working',
    AgentWorkStatus.error => 'Failed',
    AgentWorkStatus.done => 'Finished',
    AgentWorkStatus.unread => 'Unread',
  };
}
