import 'package:flutter/widgets.dart';

import '../design/ab_colors.dart';
import '../design/ab_status_tone.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_progress_rule.dart';
import 'terminal_elapsed.dart';

/// Names what a terminal pane is doing while it cannot yet show a trustworthy
/// screen: attaching, refreshing, input paused, or failed with a way to retry.
///
/// Pure presentation — the caller derives [label] and [tone] from
/// `TerminalAttachStage`/`inputPaused` and owns every callback. Mounted as a
/// full-width sibling ABOVE the terminal grid, never as an overlay: a floating
/// strip would sit over a TUI's own prompt line, and this pane's drag-select
/// and wheel-scroll belong to the terminal engine beneath it, not to chrome
/// layered on top.
class TerminalHydrationStrip extends StatelessWidget {
  const TerminalHydrationStrip({
    super.key,
    required this.label,
    required this.tone,
    this.startedAtMs,
    this.onRetry,
  });

  final String label;
  final AbStatusTone tone;

  /// Drives a [TerminalElapsed] readout when set; omitted (no counter) when
  /// null, e.g. a failure with no in-flight pull left to time.
  final int? startedAtMs;

  /// Renders a trailing Retry button when set.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final tint = tone.color(context);
    return Semantics(
      label: label,
      liveRegion: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
          horizontal: AbTokens.space10,
          vertical: AbTokens.space6,
        ),
        decoration: BoxDecoration(
          color: p.bgElevated,
          border: Border.all(color: tint.withValues(alpha: 0.3)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AbTokens.sansStyle(
                      fontSize: AbTokens.fontXs,
                      color: p.textSecondary,
                    ),
                  ),
                ),
                if (startedAtMs != null) ...[
                  const SizedBox(width: AbTokens.space8),
                  TerminalElapsed(startedAtMs: startedAtMs!, color: tint),
                ],
                if (onRetry != null) ...[
                  const SizedBox(width: AbTokens.space8),
                  AbButton(label: 'Retry', compact: true, onTap: onRetry),
                ],
              ],
            ),
            // A strip offering a Retry is waiting on the USER, so it gets no
            // indeterminate rule — an animated bar under "couldn't load this
            // terminal" reads as work still in flight and contradicts both the
            // copy and the button beside it.
            if (onRetry == null) ...[
              const SizedBox(height: AbTokens.space6),
              const AbProgressRule(fraction: null),
            ],
          ],
        ),
      ),
    );
  }
}
