import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/widgets/ab_mobile_cta.dart';
import '../design/widgets/ab_snack_bar.dart';
import '../launcher/host_control_client.dart';
import '../providers/mobile_devices_hub.dart';

/// Inert tap handler for the pre-data placeholder CTA (top-level so the
/// placeholder stays a `const` widget).
void _noop() {}

/// Per-project mobile-access toggle for the agent-panel header (local projects
/// only — remote projects show a [RemoteHostChip] instead).
///
/// Reads the machine-level [MobileAccessPolicy] to determine whether this
/// project is enabled, and calls the policy notifier's `enableProject`/
/// `disableProject` verbs directly — so the toggle works even before any phone
/// has paired (same-account default, gated server-side by the bridge).
class MobileAccessToggle extends ConsumerWidget {
  final String projectId;
  const MobileAccessToggle({super.key, required this.projectId});

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

    final enabled = policy.projectIds.contains(projectId);
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
        final notifier = ref.read(mobileAccessPolicyProvider.notifier);
        if (enabled) {
          notifier.disableProject(projectId);
        } else {
          notifier.enableProject(projectId);
        }
      },
    );
  }
}
