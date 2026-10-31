import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_tokens.dart';
import '../design/widgets/ab_chip.dart';
import '../design/widgets/ab_tooltip.dart';
import '../models/session_entry.dart';
import '../providers/memory.dart';
import '../providers/open_checkout.dart';

/// Marks a running local session whose agent was launched before Memory was
/// turned on, so it has no Memory until it restarts.
///
/// Local only: the Memory status that gates it is read from this machine's own
/// host, and a remote row would be judged against the wrong machine's setting.
/// Both providers are watched only for a flagged row, so the common case costs
/// no request.
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
    if (!session.startedWithoutMemory ||
        !session.running ||
        ref.watch(entryIsLocalCheckoutProvider(entryId)).value != true ||
        ref.watch(memoryDrawerEnabledProvider).value != true) {
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
