import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_carbon.dart';
import '../design/widgets/ab_agent_mark.dart';
import '../providers/agent_catalog.dart';
import '../providers/agent_transport.dart';
import '../providers/focused_tools.dart';
import '../providers/new_session_picker.dart';
import '../providers/project_work_status.dart';
import '../providers/sessions.dart';
import 'carbon_status_dot.dart';

/// Which agent is driving the focused session, as a mark beside the mode
/// control, corner-badged with its live work status.
///
/// The header names the project and the session but never the agent, so with
/// several sessions open there is nothing on screen that says whether the reply
/// coming back is Claude Code's or Codex's — which changes how you read it.
/// A glyph is the whole answer here because the name is the tooltip. The
/// recent-sessions rows draw the same mark + badge for the same reason
/// (`_SessionMark` in `recent_sessions/carbon_recent_session_row.dart`) — this mirrors that
/// layout so the two read identically: mark leads, breadcrumb follows.
///
/// Status is per-session when a session is focused, else the project rollup —
/// always shown, `done`/idle included, so an idle session reads the same
/// hollow ring here as it does in the Recent list.
///
/// Without a mark (custom launch command, or nothing focused) this falls back
/// to the bare status dot, matching the Recent row's markless case.
class SessionAgentMark extends ConsumerWidget {
  const SessionAgentMark({super.key});

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
          : AbCarbonScope(child: CarbonWorkStatusDot(status: workStatus));
    }
    // The focused machine's own label first, the merged catalog second — the
    // same resolution the mode control uses, so one session cannot be named two
    // ways in one header.
    final label =
        ref.watch(focusedMachineToolsProvider).value?.labels[tool] ??
        sessionAgentDisplayLabel(active, ref.watch(agentCatalogProvider));

    return AbCarbonScope(
      child: Builder(
        builder: (context) {
          final t = CarbonTheme.of(context);
          final mark = CarbonTooltip(
            message: label,
            child: AbAgentMark(
              key: const Key('session-agent-mark'),
              toolKey: tool,
              label: label,
              size: t.iconSize,
              color: t.colors.iconSecondary,
            ),
          );
          if (workStatus == null) return mark;
          return Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              mark,
              // Hung off the corner rather than inset, so the dot eats as
              // little of the mark as it can. The overhang is decorative and
              // clears the gap the header leaves after the mark.
              Positioned(
                right: -CarbonSpacing.spacing01,
                bottom: -CarbonSpacing.spacing01,
                child: CarbonWorkStatusDot(status: workStatus),
              ),
            ],
          );
        },
      ),
    );
  }
}
