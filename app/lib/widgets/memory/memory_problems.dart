import 'package:flutter/widgets.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_status_tone.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_button.dart';
import '../../design/widgets/ab_status_dot.dart';
import '../../models/memory.dart';

class MemoryProblems extends StatelessWidget {
  const MemoryProblems({
    super.key,
    required this.status,
    required this.busy,
    required this.onRepair,
    required this.onShowMemory,
  });

  final MemoryStatus status;
  final bool busy;
  final VoidCallback onRepair;
  final ValueChanged<MemoryFailure> onShowMemory;

  @override
  Widget build(BuildContext context) {
    final pending = status.pendingOperations;
    final failed = status.failedOperations;
    final lines = <Widget>[
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
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.symmetric(
          vertical: AbTokens.space6,
          horizontal: AbTokens.space16,
        ),
        decoration: BoxDecoration(
          color: context.antgrid.bgSurface,
          border: Border(
            bottom: BorderSide(color: context.antgrid.borderSubtle),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: lines,
        ),
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
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colors = context.antgrid;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 32),
      child: Row(
        children: [
          AbStatusDot(tone: warning ? AbStatusTone.warning : AbStatusTone.muted),
          const SizedBox(width: AbTokens.space8),
          Expanded(
            child: Text(
              text,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontMd,
                color: warning ? null : colors.textSecondary,
              ),
            ),
          ),
          if (action != null) ...[
            const SizedBox(width: AbTokens.space8),
            AbButton(label: action!, compact: true, onTap: onAction),
          ],
        ],
      ),
    );
  }
}
