import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../../models/memory.dart' show MemoryStatus;

/// The machine-wide status folded into one word. [projectPaused] is separate
/// because status is machine-wide while the screen may be showing one paused
/// project.
({CarbonIconIndicatorKind kind, String word}) memoryStatusWord(
  MemoryStatus status, {
  bool projectPaused = false,
}) {
  if (status.needsAttention) {
    return (
      kind: CarbonIconIndicatorKind.cautionMinor,
      word: 'Needs attention',
    );
  }
  if (status.paused || projectPaused) {
    return (kind: CarbonIconIndicatorKind.notStarted, word: 'Saving paused');
  }
  return (kind: CarbonIconIndicatorKind.succeeded, word: 'Saving on');
}

class MemoryStatusPill extends StatelessWidget {
  const MemoryStatusPill(this.status, {super.key, this.projectPaused = false});
  final MemoryStatus status;
  final bool projectPaused;

  @override
  Widget build(BuildContext context) {
    final word = memoryStatusWord(status, projectPaused: projectPaused);
    // Not compact: the word is the pill's text, not a tooltip.
    return CarbonIconIndicator(kind: word.kind, label: word.word);
  }
}

class MemoryHeader extends StatelessWidget {
  const MemoryHeader({
    super.key,
    this.machine,
    this.status,
    this.projectPaused = false,
    this.onSettings,
    this.moreEntries,
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
    this.moreEntries,
    this.machine,
  }) : status = null,
       projectPaused = false,
       compact = true;

  /// The machine selector, which the screen owns.
  final Widget? machine;
  final MemoryStatus? status;
  final bool projectPaused;
  final VoidCallback? onSettings;

  /// The overflow menu's commands; null leaves the menu out.
  final List<CarbonMenuEntry>? moreEntries;
  final VoidCallback? onBack;
  final VoidCallback? onOpenDrawer;
  final String backTooltip;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final t = CarbonTheme.of(context);
    final settings = onSettings == null
        ? null
        : CarbonButton.iconOnly(
            icon: const CarbonIcon(CarbonIcons.settings),
            semanticLabel: 'Memory settings',
            onPressed: onSettings,
          );
    final more = moreEntries == null
        ? null
        : CarbonOverflowMenu(
            semanticLabel: 'More actions',
            entries: moreEntries!,
          );
    final lead = onBack != null
        ? CarbonButton.iconOnly(
            icon: const CarbonIcon(CarbonIcons.arrowLeft),
            semanticLabel: backTooltip,
            onPressed: onBack,
          )
        : onOpenDrawer != null
        ? CarbonButton.iconOnly(
            icon: const CarbonIcon(CarbonIcons.menu),
            semanticLabel: 'Open drawer',
            onPressed: onOpenDrawer,
          )
        : null;
    final title = Semantics(
      header: true,
      child: Text(
        'Memory',
        style: t.typography.heading.copyWith(color: t.colors.textPrimary),
      ),
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.borderSubtle(1))),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: CarbonSizes.lg),
        child: Padding(
          padding: EdgeInsetsDirectional.only(
            start: compact && lead != null
                ? CarbonSpacing.spacing03
                : CarbonSpacing.spacing05,
            end: CarbonSpacing.spacing03,
          ),
          child: compact
              ? Row(
                  children: [
                    if (lead != null) ...[
                      lead,
                      const SizedBox(width: CarbonSpacing.spacing02),
                    ],
                    title,
                    const SizedBox(width: CarbonSpacing.spacing03),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: machine,
                      ),
                    ),
                    ?settings,
                    ?more,
                  ],
                )
              : Row(
                  children: [
                    title,
                    const SizedBox(width: CarbonSpacing.spacing04),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: machine,
                      ),
                    ),
                    if (status case final status?) ...[
                      MemoryStatusPill(status, projectPaused: projectPaused),
                      const SizedBox(width: CarbonSpacing.spacing03),
                    ],
                    ?settings,
                    ?more,
                  ],
                ),
        ),
      ),
    );
  }
}
