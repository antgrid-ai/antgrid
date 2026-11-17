import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/update_available.dart';
import '../update/update_install_controller.dart';
import '../update/update_strategy.dart';
import '../update/update_check_controller.dart';
import '../update/update_check_result.dart';
import '../util/detached.dart';
import 'drawer/drawer_chrome_row.dart';

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
    final downloading =
        ref.watch(updateCheckControllerProvider).result?.status ==
        UpdateCheckStatus.downloading;
    final live = install.canStart && !downloading;
    final title = switch (install) {
      // 0 is the pre-download plateau, not progress — the Store re-scans and
      // shows both consent dialogs before the first byte, so a hard "0%" would
      // read as stalled for the whole of it.
      UpdateInstallWorking(:final percent) when percent > 0 =>
        'Updating... $percent%',
      UpdateInstallWorking() || UpdateInstallDone() => 'Updating...',
      _ => downloading ? 'Updating...' : strategy.rowTitle,
    };

    final t = CarbonTheme.of(context);
    final c = t.colors;
    final row = DrawerChromeRow(
      icon: CarbonIcons.download,
      label: title,
      semanticLabel: live ? '$title, ${strategy.rowActionLabel}' : title,
      iconColor: live ? c.linkPrimary : c.iconDisabled,
      onPressed: live
          ? () => detached(
              'UpdateRow',
              'install sequence',
              () => ref
                  .read(updateInstallControllerProvider.notifier)
                  .start(context),
            )
          : null,
      // An action label on a row that refuses taps reads as a dead button, so
      // it goes away while one is running.
      trailing: live
          ? Padding(
              padding: const EdgeInsetsDirectional.only(
                start: CarbonSpacing.spacing03,
                end: CarbonSpacing.spacing02,
              ),
              child: Text(
                strategy.rowActionLabel,
                style: t.typography.control.copyWith(color: c.linkPrimary),
              ),
            )
          : null,
    );
    if (install is! UpdateInstallWorking) return row;

    // Overlaid rather than stacked in a Column: the row must not change height
    // when the bar appears.
    return Stack(
      children: [
        row,
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          // Indeterminate until the platform actually ticks: a bar pinned at
          // zero for minutes is indistinguishable from a stuck one. The band
          // rests instead of sweeping, so a row that sits in the drawer for
          // the length of an install adds no perpetual animation.
          child: CarbonProgressBar(
            size: CarbonProgressBarSize.small,
            hideLabel: true,
            label: 'Update progress',
            animateIndeterminate: false,
            value: install.percent == 0 ? null : install.percent / 100,
          ),
        ),
      ],
    );
  }
}
