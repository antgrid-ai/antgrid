import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/widgets/ab_agent_mark.dart';
import '../design/widgets/ab_tooltip.dart';
import '../providers/focused_tools.dart';
import '../providers/new_session_picker.dart';
import '../providers/sessions.dart';

/// Which agent is driving the focused session, as a mark beside the mode
/// control.
///
/// The header names the project and the session but never the agent, so with
/// several sessions open there is nothing on screen that says whether the reply
/// coming back is Claude Code's or Codex's — which changes how you read it.
/// A glyph is the whole answer here because the name is the tooltip; this is the
/// one place the label genuinely doesn't fit. Rows that DO have the width (the
/// drawer, the recent-sessions list) keep printing it as text — swapping those
/// for a hover-only mark would be a downgrade.
///
/// Hidden for a custom launch command: it has no registry key and so no agent
/// identity to assert, and a monogram of `npm run dev` would be noise.
class SessionAgentMark extends ConsumerWidget {
  const SessionAgentMark({super.key, this.size = 14});

  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(activeSessionProvider);
    final tool = active?.tool;
    if (active == null || tool == null || tool.isEmpty) {
      return const SizedBox.shrink();
    }
    // Wire label first, static table second — the same resolution the mode
    // control uses, so one session cannot be named two ways in one header.
    final label =
        ref.watch(focusedMachineToolsProvider).value?.labels[tool] ??
        sessionAgentDisplayLabel(active);

    return AbTooltip(
      message: label,
      child: AbAgentMark(
        key: const Key('session-agent-mark'),
        toolKey: tool,
        label: label,
        size: size,
      ),
    );
  }
}
