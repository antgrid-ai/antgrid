import 'package:flutter/widgets.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_status_tone.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_icon_button.dart';
import '../../design/widgets/ab_status_dot.dart';
import '../../models/memory.dart' show MemoryStatus;

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
    this.machine,
    this.status,
    this.projectPaused = false,
    this.onSettings,
    this.onMore,
  }) : onBack = null,
       onOpenDrawer = null,
       backTooltip = 'Back',
       compact = false;

  const MemoryHeader.compact({
    super.key,
    this.onBack,
    this.onOpenDrawer,
    this.backTooltip = 'Back',
    this.onSettings,
    this.onMore,
    this.machine,
  }) : status = null,
       projectPaused = false,
       compact = true;

  /// The machine selector, which the screen owns.
  final Widget? machine;
  final MemoryStatus? status;
  final bool projectPaused;
  final VoidCallback? onSettings;

  /// Receives the ⋯ button's own context so the menu can anchor to it.
  final ValueChanged<BuildContext>? onMore;
  final VoidCallback? onBack;
  final VoidCallback? onOpenDrawer;
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
    final more = onMore == null
        ? null
        : Builder(
            builder: (anchor) => AbIconButton(
              icon: AbIcons.more,
              tooltip: 'More actions',
              onTap: () => onMore!(anchor),
            ),
          );
    final lead = onBack != null
        ? AbIconButton(icon: AbIcons.back, tooltip: backTooltip, onTap: onBack)
        : onOpenDrawer != null
        ? AbIconButton(
            icon: AbIcons.menu,
            tooltip: 'Open drawer',
            onTap: onOpenDrawer,
          )
        : null;
    return Container(
      height: AbTokens.rowHeightLg,
      padding: EdgeInsets.only(
        left: compact && lead != null ? AbTokens.space8 : AbTokens.space16,
        right: AbTokens.space8,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.borderSubtle)),
      ),
      child: compact
          ? Row(
              children: [
                if (lead != null) ...[
                  lead,
                  const SizedBox(width: AbTokens.space4),
                ],
                Text(
                  'Memory',
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontLg,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (machine case final machine?) ...[
                  const SizedBox(width: AbTokens.space8),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: machine,
                    ),
                  ),
                ] else
                  const Spacer(),
                ?settings,
                ?more,
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
                  child: Align(alignment: Alignment.centerLeft, child: machine),
                ),
                if (status case final status?) ...[
                  MemoryStatusPill(status, projectPaused: projectPaused),
                  const SizedBox(width: AbTokens.space8),
                ],
                ?settings,
                ?more,
              ],
            ),
    );
  }
}
