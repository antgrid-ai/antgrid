import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/widgets/ab_mobile_cta.dart';
import '../design/widgets/ab_snack_bar.dart';
import '../launcher/host_control_client.dart';
import '../providers/mobile_devices_hub.dart';

/// Inert tap handler for the pre-data placeholder CTA (top-level so the
/// placeholder stays a `const` widget).
void _noop() {}

/// Machine-wide mobile-access switch for the desktop title bar: is THIS machine
/// reachable from mobile at all. Not scoped to a project or to a phone — every
/// account-trusted phone is admitted or none is.
///
/// Reads and writes the machine-level [MobileAccessPolicy] over the loopback
/// control plane, so the switch works before any phone has ever connected.
class MobileAccessToggle extends ConsumerWidget {
  const MobileAccessToggle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Surface a failed load/enable/disable as a snackbar. The provider retains
    // the last-known policy under the error (copyWithPrevious), so the button
    // keeps showing prior state rather than vanishing; this only fires on the
    // transition INTO error to avoid re-toasting on every rebuild.
    ref.listen<AsyncValue<MobileAccessPolicy>>(mobileAccessPolicyProvider, (prev, next) {
      if (next is AsyncError && prev is! AsyncError) {
        showAbSnackBar(context, 'Could not update mobile access. Try again.');
      }
    });

    final async = ref.watch(mobileAccessPolicyProvider);
    final policy = async.value;
    // No value yet — very first load (pre-data) or an error that never resolved
    // to a value. Keep the control VISIBLE but inert rather than hiding it: a
    // vanished button leaves the user with no affordance and no retry surface on
    // a persistent host error. Render the inactive shape; the brief sub-second
    // window before the real state arrives is far better than a disappearing CTA.
    if (policy == null) {
      return const AbMobileCta(
        active: false,
        kbdHint: null,
        activeLabel: 'Disable mobile access',
        inactiveLabel: 'Enable mobile access',
        onTap: _noop,
      );
    }

    final enabled = policy.enabled;
    // A mutation/refresh is in flight — ignore taps so a double-click can't
    // spawn a second concurrent verb racing the first.
    final busy = async.isLoading;

    return AbMobileCta(
      active: enabled,
      kbdHint: null,
      activeLabel: 'Disable mobile access',
      inactiveLabel: 'Enable mobile access',
      onTap: () {
        if (busy) return;
        ref.read(mobileAccessPolicyProvider.notifier).setEnabled(!enabled);
      },
    );
  }
}
