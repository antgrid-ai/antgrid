import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_tokens.dart';
import '../design/widgets/ab_chip.dart';
import '../design/widgets/ab_tooltip.dart';
import '../models/session_entry.dart';
import '../providers/memory.dart';
import '../utils/platform_utils.dart';

/// Marks a running local session whose agent was launched before Memory was
/// turned on, so it has no Memory until it restarts.
///
/// Desktop and local only: the Memory status that gates it is read from this
/// machine's own host, and a remote row would be judged against the wrong
/// machine's setting. The status is watched only for a flagged row, so the
/// common case costs no request.
class SessionMemoryRestartBadge extends ConsumerWidget {
  const SessionMemoryRestartBadge({
    super.key,
    required this.entryId,
    required this.session,
  });

  final String entryId;
  final SessionEntry session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // A leading dot has no machine part, so it is not a compound remote id.
    final local = entryId.indexOf('.') <= 0;
    if (isMobilePlatform ||
        !local ||
        !session.running ||
        !session.startedWithoutMemory) {
      return const SizedBox.shrink();
    }
    if (ref.watch(memoryDrawerEnabledProvider).value != true) {
      return const SizedBox.shrink();
    }
    return const Padding(
      padding: EdgeInsets.only(left: AbTokens.space6),
      child: AbTooltip(
        message: 'Started before Memory was turned on. Restart to use Memory.',
        triggerMode: TooltipTriggerMode.tap,
        child: AbChip.system(label: 'No Memory'),
      ),
    );
  }
}
