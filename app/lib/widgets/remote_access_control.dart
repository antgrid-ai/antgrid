import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/widgets/ab_menu.dart';
import '../design/widgets/ab_snack_bar.dart';
import '../design/widgets/ab_state_chip.dart';
import '../design/widgets/pulsing_opacity.dart';
import '../launcher/host_control_client.dart';
import '../providers/remote_access.dart';
import 'remote_access_panel.dart';

/// Machine-wide remote-access state in the desktop title bar: is THIS machine
/// reachable from your other devices at all. Not scoped to a project or to one
/// device — every account-trusted device is admitted or none is.
///
/// Reports the state; the switch lives one tap away in [RemoteAccessPanel].
/// Splitting them is the point. A header chip labelled with the ACTION next to
/// an on-coloured fill contradicts itself, and a one-tap grant of the whole
/// machine — every project, to every device on the account — deserves a surface
/// that can say so before it happens.
///
/// Reads the machine-level [RemoteAccessPolicy] over the loopback control
/// plane, so it reports honestly before any device has ever connected.
class RemoteAccessControl extends ConsumerWidget {
  const RemoteAccessControl({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Surface a failed load/enable/disable as a snackbar. The provider retains
    // the last-known policy under the error (copyWithPrevious), so the chip
    // keeps showing prior state rather than vanishing; this only fires on the
    // transition INTO error to avoid re-toasting on every rebuild.
    ref.listen<AsyncValue<RemoteAccessPolicy>>(remoteAccessPolicyProvider, (
      prev,
      next,
    ) {
      if (next is AsyncError && prev is! AsyncError) {
        showAbSnackBar(context, 'Could not update remote access. Try again.');
      }
    });

    final async = ref.watch(remoteAccessPolicyProvider);
    final policy = async.value;
    final enabled = policy?.enabled == true;

    final chip = AbStateChip(
      key: const Key('remote-access-chip'),
      icon: AbIcons.radioTower,
      // No value yet — first load, or an error that never resolved to one. The
      // chip stays visible and still opens the panel: with the control gone the
      // user has no affordance and no retry surface on a persistent host error,
      // and a chip that looks decided while knowing nothing is worse than one
      // that admits it doesn't know yet.
      label: policy == null
          ? 'Remote'
          : enabled
          ? 'Remote on'
          : 'Remote off',
      tone: enabled ? context.antgrid.statusRunning : null,
      active: enabled,
      tooltip: policy == null
          ? 'Remote access — checking this machine…'
          : enabled
          ? 'Any device signed in to your account can drive this machine'
          : 'This machine is not reachable from your other devices',
      onTap: (chipContext) {
        final anchor = abMenuAnchorRect(chipContext);
        if (anchor == null) return;
        showAbPanel<void>(
          context: chipContext,
          anchorRect: anchor,
          width: 320,
          builder: (_) => const RemoteAccessPanel(),
        );
      },
    );

    // Dimming a control that reports state reads as "unavailable"; a flip in
    // flight is the opposite of unavailable, so it pulses instead.
    return async.isLoading ? PulsingOpacity(child: chip) : chip;
  }
}
