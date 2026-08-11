import 'package:flutter/widgets.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_icon.dart';
import '../../design/widgets/ab_icon_button.dart';
import '../../design/widgets/ab_list_row.dart';
import '../../design/widgets/ab_loading.dart';
import '../../models/agent_event.dart';

/// Pinned strip above the composer listing the session's live background
/// tasks (backgrounded shells, subagents). Collapsed: one summary row with a
/// running dot and count. Expanded: one row per task with a stop button.
/// Collapses to nothing when the list is empty (mirrors _UpdateBanner).
class BackgroundTasksStrip extends StatefulWidget {
  final List<AgentBackgroundTask> tasks;
  final void Function(AgentBackgroundTask task) onStop;
  const BackgroundTasksStrip({
    super.key,
    required this.tasks,
    required this.onStop,
  });

  @override
  State<BackgroundTasksStrip> createState() => _BackgroundTasksStripState();
}

class _BackgroundTasksStripState extends State<BackgroundTasksStrip> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final c = context.antgrid;
    if (widget.tasks.isEmpty) return const SizedBox.shrink();
    return Container(
      decoration: BoxDecoration(
        color: c.bgElevated,
        border: Border(top: BorderSide(color: c.borderSubtle)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AbListRow(
            density: AbRowDensity.sm,
            onTap: () => setState(() => _expanded = !_expanded),
            leading: const AbLoadingDot(size: 10),
            title: Text(
              widget.tasks.length == 1
                  ? '1 background task'
                  : '${widget.tasks.length} background tasks',
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXs,
                color: c.textSecondary,
              ),
            ),
            trailing: AbIcon(
              _expanded ? AbIcons.chevronDown : AbIcons.chevronRight,
              size: AbTokens.fontSm,
              color: c.textMuted,
            ),
          ),
          if (_expanded)
            for (final task in widget.tasks)
              AbListRow(
                density: AbRowDensity.sm,
                leading: AbIcon(
                  AbIcons.terminal,
                  size: AbTokens.fontSm,
                  color: c.textMuted,
                ),
                title: Text(
                  task.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AbTokens.monoStyle(
                    fontSize: AbTokens.fontSm,
                    color: c.textSecondary,
                  ),
                ),
                trailing: task.killable
                    ? AbIconButton(
                        icon: AbIcons.stop,
                        tooltip: 'Stop task',
                        onTap: () => widget.onStop(task),
                      )
                    : null,
              ),
        ],
      ),
    );
  }
}
