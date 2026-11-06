import 'package:flutter/widgets.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_status_tone.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_icon_button.dart';
import '../../design/widgets/ab_status_dot.dart';
import '../../models/memory.dart';

/// The machine-wide status folded into one word. [projectPaused] is separate
/// because status is machine-wide while the screen may be showing one paused
/// project.
({AbStatusTone tone, String word}) memoryStatusWord(
  MemoryStatus status, {
  bool projectPaused = false,
}) {
  if (status.needsAttention) {
    return (tone: AbStatusTone.warning, word: 'Needs attention');
  }
  if (status.paused || projectPaused) {
    return (tone: AbStatusTone.muted, word: 'Saving paused');
  }
  return (tone: AbStatusTone.success, word: 'Saving on');
}

class MemoryStatusPill extends StatelessWidget {
  const MemoryStatusPill(this.status, {super.key, this.projectPaused = false});
  final MemoryStatus status;
  final bool projectPaused;

  @override
  Widget build(BuildContext context) {
    final word = memoryStatusWord(status, projectPaused: projectPaused);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AbStatusDot(tone: word.tone),
        const SizedBox(width: AbTokens.space6),
        Text(
          word.word,
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontSm,
            color: context.antgrid.textSecondary,
          ),
        ),
      ],
    );
  }
}

class MemoryHeader extends StatelessWidget {
  const MemoryHeader({
    super.key,
    required this.target,
    this.status,
    this.projectPaused = false,
    this.onSettings,
    this.onMore,
    required this.onClose,
  }) : onBack = null,
       backTooltip = 'Back',
       compact = false;

  const MemoryHeader.compact({
    super.key,
    required VoidCallback this.onBack,
    this.backTooltip = 'Back',
    this.onSettings,
  }) : target = null,
       status = null,
       projectPaused = false,
       onMore = null,
       onClose = null,
       compact = true;

  final MemoryTarget? target;
  final MemoryStatus? status;
  final bool projectPaused;
  final VoidCallback? onSettings;

  /// Receives the ⋯ button's own context so the menu can anchor to it.
  final ValueChanged<BuildContext>? onMore;
  final VoidCallback? onClose;
  final VoidCallback? onBack;
  final String backTooltip;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = context.antgrid;
    final settings = onSettings == null
        ? null
        : AbIconButton(
            icon: AbIcons.settings,
            tooltip: 'Memory settings',
            onTap: onSettings,
          );
    return Container(
      height: AbTokens.rowHeightLg,
      padding: EdgeInsets.only(
        left: compact ? AbTokens.space8 : AbTokens.space16,
        right: AbTokens.space8,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.borderSubtle)),
      ),
      child: compact
          ? Row(
              children: [
                AbIconButton(
                  icon: AbIcons.back,
                  tooltip: backTooltip,
                  onTap: onBack,
                ),
                const SizedBox(width: AbTokens.space4),
                Text(
                  'Memory',
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontLg,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                ?settings,
              ],
            )
          : Row(
              children: [
                Text(
                  'MEMORY',
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontSm,
                    color: colors.textSecondary,
                    letterSpacing: 1.4,
                  ),
                ),
                const SizedBox(width: AbTokens.space12),
                Expanded(
                  child: Text(
                    target!.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AbTokens.sansStyle(
                      fontSize: AbTokens.fontMd,
                      color: colors.textMuted,
                    ),
                  ),
                ),
                if (status case final status?) ...[
                  MemoryStatusPill(status, projectPaused: projectPaused),
                  const SizedBox(width: AbTokens.space8),
                ],
                ?settings,
                if (onMore case final onMore?)
                  Builder(
                    builder: (anchor) => AbIconButton(
                      icon: AbIcons.more,
                      tooltip: 'More actions',
                      onTap: () => onMore(anchor),
                    ),
                  ),
                AbIconButton(
                  icon: AbIcons.close,
                  tooltip: 'Close',
                  onTap: onClose,
                ),
              ],
            ),
    );
  }
}
