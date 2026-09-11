import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_chip.dart';
import '../design/widgets/ab_tooltip.dart';
import '../providers/agent_transport.dart' show selectedRegistrationIdProvider;
import '../providers/providers.dart';

/// How many answers Handler is waiting on in one session.
///
/// The row where the user picks a session is the only place a session that is
/// NOT in focus can speak. The Handler tab narrows to the focused session, its
/// tab badge counts that same session, and the agent header's pill yields to
/// the focused session's own count whenever that session is itself waiting — so
/// without this a sibling's unanswered question has nothing standing for it
/// anywhere in the app.
///
/// Rendered for the focused PROJECT only. [handlerStateProvider] follows
/// project focus, so a drawer row belonging to another project would be
/// answered out of this project's sessions — a count attached to the wrong
/// name, which is worse than no count. Escalations across projects need a
/// surface of their own and do not have one yet.
///
/// Accent and a bare number, matching the header pill this stands in for: the
/// count is the actionable part, and the tooltip — hover on a pointer, tap on
/// touch — carries the sentence.
class SessionHandlerBadge extends ConsumerWidget {
  const SessionHandlerBadge({
    super.key,
    required this.entryId,
    required this.sessionId,
  });

  /// The project the row belongs to, not the focused one.
  final String entryId;
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(selectedRegistrationIdProvider) != entryId) {
      return const SizedBox.shrink();
    }
    final pending = ref.watch(
      handlerStateProvider.select(
        (s) => s.value?.sessions[sessionId]?.pendingEscalations ?? 0,
      ),
    );
    if (pending == 0) return const SizedBox.shrink();
    return Padding(
      // Owns its leading gap, so a call site mounts it without reserving space
      // for a widget that usually renders nothing.
      padding: const EdgeInsets.only(left: AbTokens.space6),
      child: AbTooltip(
        message: pending == 1
            ? 'Handler is waiting on an answer in this session.'
            : 'Handler is waiting on $pending answers in this session.',
        triggerMode: TooltipTriggerMode.tap,
        child: AbChip.system(
          label: '$pending',
          color: context.antgrid.accent,
        ),
      ),
    );
  }
}
