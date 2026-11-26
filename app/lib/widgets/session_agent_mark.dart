import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/widgets/ab_agent_mark.dart';
import '../design/widgets/ab_tooltip.dart';
import '../providers/agent_catalog.dart';
import '../providers/agent_transport.dart';
import '../providers/focused_tools.dart';
import '../providers/new_session_picker.dart';
import '../providers/project_work_status.dart';
import '../providers/sessions.dart';
import 'agent_work_status_dot.dart';

/// Which agent is driving the focused session, as a mark beside the mode
/// control, corner-badged with its live work status.
///
/// The header names the project and the session but never the agent, so with
/// several sessions open there is nothing on screen that says whether the reply
/// coming back is Claude Code's or Codex's — which changes how you read it.
/// A glyph is the whole answer here because the name is the tooltip. The
/// recent-sessions rows draw the same mark + badge for the same reason
/// (`_SessionMark` in `recent_session_row_widget.dart`) — this mirrors that
/// layout so the two read identically: mark leads, breadcrumb follows.
///
/// Status is per-session when a session is focused, else the project rollup
/// (mirrors the breadcrumb's old inline dot, which this replaces) — always
/// shown, `done`/idle included, so an idle session reads the same hollow-grey
/// here as it does in the Recent list.
///
/// Without a mark (custom launch command, or nothing focused) this falls back
/// to the bare status dot, matching `_SessionMark`'s markless case.
class SessionAgentMark extends ConsumerWidget {
  const SessionAgentMark({super.key, this.size = 14});

  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeId = ref.watch(selectedRegistrationIdProvider);
    final active = ref.watch(activeSessionProvider);
    final tool = active?.tool;
    final workStatus = activeId == null
        ? null
        : active == null
        ? ref.watch(projectWorkStatusProvider(activeId))
        : ref.watch(
            sessionWorkStatusProvider((
              entryId: activeId,
              sessionId: active.id,
              running: active.running,
            )),
          );

    if (active == null || tool == null || tool.isEmpty) {
      return workStatus == null
          ? const SizedBox.shrink()
          : AgentWorkStatusDot(status: workStatus);
    }
    // The focused machine's own label first, the merged catalog second — the
    // same resolution the mode control uses, so one session cannot be named two
    // ways in one header.
    final label =
        ref.watch(focusedMachineToolsProvider).value?.labels[tool] ??
        sessionAgentDisplayLabel(active, ref.watch(agentCatalogProvider));

    final mark = AbTooltip(
      message: label,
      child: AbAgentMark(
        key: const Key('session-agent-mark'),
        toolKey: tool,
        label: label,
        size: size,
      ),
    );

    if (workStatus == null) return mark;
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        mark,
        Positioned(
          right: -2,
          bottom: -2,
          child: AgentWorkStatusBadge(
            status: workStatus,
            ringColor: context.antgrid.bgDeep,
          ),
        ),
      ],
    );
  }
}
