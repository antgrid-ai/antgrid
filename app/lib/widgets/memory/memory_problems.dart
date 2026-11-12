import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../../models/memory.dart';

class MemoryProblems extends StatelessWidget {
  const MemoryProblems({
    super.key,
    required this.status,
    required this.busy,
    required this.onRepair,
    required this.onShowMemory,
    required this.onReviewSessions,
  });

  final MemoryStatus status;
  final bool busy;
  final VoidCallback onRepair;
  final ValueChanged<MemoryFailure> onShowMemory;
  final VoidCallback onReviewSessions;

  @override
  Widget build(BuildContext context) {
    final pending = status.pendingOperations;
    final failed = status.failedOperations;
    final unrestarted = status.sessionsWithoutMemory.length;
    final lines = <Widget>[
      if (unrestarted > 0)
        _ProblemLine(
          warning: false,
          text: unrestarted == 1
              ? '1 running session started without Memory.'
              : '$unrestarted running sessions started without Memory.',
          action: 'Review',
          onAction: busy ? null : onReviewSessions,
        ),
      if (!status.searchReady)
        _ProblemLine(
          warning: true,
          text:
              "Search is broken, so it's switched off. You can still browse every memory below.",
          action: 'Rebuild search',
          onAction: busy ? null : onRepair,
        ),
      if (pending > 0)
        _ProblemLine(
          warning: false,
          text: pending == 1
              ? "1 save is waiting for its session to reconnect. It'll finish on its own."
              : "$pending saves are waiting for their session to reconnect. They'll finish on their own.",
        ),
      if (failed > 0)
        _ProblemLine(
          warning: true,
          text: failed == 1
              ? '1 save was skipped because someone edited that memory first.'
              : '$failed saves were skipped because someone edited those memories first.',
          action: status.failures.isEmpty ? null : 'Show memory',
          onAction: status.failures.isEmpty
              ? null
              : () => onShowMemory(status.failures.first),
        ),
      if (status.cleanupFailed)
        _ProblemLine(
          warning: true,
          text: "Forgotten memories are hidden, but cleanup didn't finish.",
          action: 'Finish cleanup',
          onAction: busy ? null : onRepair,
        ),
    ];
    if (lines.isEmpty) return const SizedBox.shrink();
    // Each notification announces itself, so the strip needs no live region.
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        CarbonSpacing.spacing05,
        CarbonSpacing.spacing02,
        CarbonSpacing.spacing05,
        CarbonSpacing.spacing03,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: CarbonSpacing.spacing02,
        children: lines,
      ),
    );
  }
}

class _ProblemLine extends StatelessWidget {
  const _ProblemLine({
    required this.warning,
    required this.text,
    this.action,
    this.onAction,
  });

  final bool warning;
  final String text;
  final String? action;

  /// Null with an [action] keeps the action but disabled, as while busy.
  final VoidCallback? onAction;

  // Subtitle only: with a title the card renders one combined run of text.
  @override
  Widget build(BuildContext context) => CarbonNotification(
    kind: warning
        ? CarbonNotificationKind.warning
        : CarbonNotificationKind.info,
    subtitle: text,
    action: action == null
        ? null
        : CarbonNotificationAction(label: action!, onPressed: onAction),
  );
}
