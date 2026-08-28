import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_progress_rule.dart';
import '../providers/update_available.dart';
import '../update/update_install_controller.dart';
import '../update/update_strategy.dart';
import '../util/detached.dart';

/// Persistent "Update available" drawer row, shown directly above the account
/// footer while a newer version is waiting ([updateAvailableProvider]).
/// Collapses to nothing otherwise, so up-to-date builds and platforms without
/// an update path pay no layout cost.
///
/// The row survives a declined or cancelled install on purpose — the update
/// stays pending until the app restarts, so the affordance must remain
/// clickable whenever the user is ready. It goes inert for exactly as long as
/// an attempt is live: the first seconds of a Windows install are silent (the
/// Store re-scans its pending set before showing anything of its own), and a
/// second tap in that window starts a second install.
class UpdateRow extends ConsumerWidget {
  const UpdateRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final available = ref.watch(updateAvailableProvider);
    if (!available) return const SizedBox.shrink();

    // The row only renders while `updateAvailableProvider` is lit, and only
    // the platform's UpdateStrategy check can light it — so the same
    // strategy object carries this row's copy (single per-platform table,
    // see update_strategy.dart) while the controller owns the tap, shared
    // with the update toasts so both cannot start an install at once.
    final strategy = ref.watch(updateStrategyProvider);
    assert(strategy != null, 'UpdateRow lit on a platform with no strategy');
    if (strategy == null) return const SizedBox.shrink();

    final install = ref.watch(updateInstallControllerProvider);
    final live = install.canStart;
    final title = switch (install) {
      // 0 is the pre-download plateau, not progress — the Store re-scans and
      // shows both consent dialogs before the first byte, so a hard "0%" would
      // read as stalled for the whole of it.
      UpdateInstallWorking(:final percent) when percent > 0 =>
        'Updating... $percent%',
      UpdateInstallWorking() => 'Updating...',
      UpdateInstallDone() => 'Updating...',
      _ => strategy.rowTitle,
    };

    final p = context.antgrid;
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: p.borderSubtle)),
      ),
      child: InkWell(
        hoverColor: p.bgElevated,
        onTap: live
            ? () => detached(
                'UpdateRow',
                'install sequence',
                () => ref
                    .read(updateInstallControllerProvider.notifier)
                    .start(context),
              )
            : null,
        child: SizedBox(
          height: AbTokens.commandTrayHeight,
          child: Stack(
            // Tight constraints for the Row, so the label stays centred in the
            // tray height rather than hugging the top.
            fit: StackFit.expand,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AbTokens.space16,
                ),
                child: Row(
                  children: [
                    AbIcon(
                      AbIcons.arrowDown,
                      size: 12,
                      color: live ? p.accent : p.textMuted,
                    ),
                    const SizedBox(width: AbTokens.space10),
                    Expanded(
                      child: Text(
                        title,
                        style: AbTokens.sansStyle(
                          fontSize: AbTokens.fontXs,
                          color: p.textSecondary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    // An action label on a row that refuses taps reads as a
                    // dead button, so it goes away while one is running.
                    if (live)
                      Text(
                        strategy.rowActionLabel,
                        style: AbTokens.sansStyle(
                          fontSize: AbTokens.fontXs,
                          color: p.accent,
                        ),
                      ),
                  ],
                ),
              ),
              // Overlaid rather than stacked in a Column: the row must not
              // change height when the rule appears.
              if (install is UpdateInstallWorking)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  // Indeterminate until the platform actually ticks: a rule
                  // pinned at zero for minutes is indistinguishable from a
                  // stuck one.
                  child: AbProgressRule(
                    fraction: install.percent == 0
                        ? null
                        : install.percent / 100,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
