import 'package:flutter/widgets.dart';

import '../design/ab_tokens.dart';
import '../design/widgets/ab_chip.dart';
import '../design/widgets/ab_tooltip.dart';

/// The marker that says a session is being removed right now, mounted wherever
/// a session is named — the drawer row and the Recent row.
///
/// Renders nothing when [deleting] is false, so both call sites mount it
/// unconditionally and neither re-states the copy. Neutral, not an error
/// colour: this is a normal operation in progress. The motion lives in each
/// surface's leading slot rather than here, so the two read the same.
class SessionDeletingBadge extends StatelessWidget {
  const SessionDeletingBadge({super.key, required this.deleting});

  final bool deleting;

  @override
  Widget build(BuildContext context) {
    if (!deleting) return const SizedBox.shrink();
    // Owns its leading gap, so a call site reserves no space for a widget that
    // usually renders nothing.
    return const Padding(
      padding: EdgeInsets.only(left: AbTokens.space6),
      child: AbTooltip(
        // Names no mechanism, matching the isolation badge: the same badge
        // stands for every checkout kind.
        message:
            'Deleting this session. Removing an isolated workspace can take a '
            'while.',
        child: AbChip.system(label: 'DELETING'),
      ),
    );
  }
}
