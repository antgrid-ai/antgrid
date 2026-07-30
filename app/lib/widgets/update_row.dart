import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_icon.dart';
import '../providers/update_available.dart';
import '../update/update_strategy.dart';

/// Persistent "Update available" drawer row, shown directly above the account
/// footer while a newer version is waiting ([updateAvailableProvider]).
/// Collapses to nothing otherwise, so up-to-date builds and platforms without
/// an update path pay no layout cost.
///
/// The row survives dismissal/cancellation of the platform's install dialog
/// on purpose — the update stays pending until the app restarts, so the
/// affordance must remain clickable whenever the user is ready.
class UpdateRow extends ConsumerWidget {
  const UpdateRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final available = ref.watch(updateAvailableProvider);
    if (!available) return const SizedBox.shrink();

    // The row only renders while `updateAvailableProvider` is lit, and only
    // the platform's UpdateStrategy check can light it — so the same
    // strategy object carries this row's copy AND its tap's install route
    // (single per-platform table, see update_strategy.dart). Strategies
    // never throw, surface their own UI, and tolerate a repeat tap by
    // re-opening the flow.
    final strategy = ref.watch(updateStrategyProvider);
    assert(strategy != null, 'UpdateRow lit on a platform with no strategy');
    if (strategy == null) return const SizedBox.shrink();

    final p = context.antgrid;
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: p.borderSubtle)),
      ),
      child: InkWell(
        hoverColor: p.bgElevated,
        onTap: () => unawaited(strategy.install(context)),
        child: SizedBox(
          height: AbTokens.commandTrayHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AbTokens.space16),
            child: Row(
              children: [
                AbIcon(AbIcons.arrowDown, size: 12, color: p.accent),
                const SizedBox(width: AbTokens.space10),
                Expanded(
                  child: Text(
                    strategy.rowTitle,
                    style: AbTokens.sansStyle(
                      fontSize: AbTokens.fontXs,
                      color: p.textSecondary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
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
        ),
      ),
    );
  }
}
