import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../utils/platform_utils.dart';
import 'auth.dart';
import 'first_run.dart';
import 'remote_access.dart';

/// What the New Session canvas should say about remote access, if anything.
sealed class RemoteAccessNudge {
  const RemoteAccessNudge();
}

/// One-time mention that remote control exists: signed in, remote off, and no
/// second device on the account yet to make it concrete.
final class SoftRemoteNudge extends RemoteAccessNudge {
  const SoftRemoteNudge();
}

/// A real prompt: a phone/tablet signed in to the account but this machine's
/// remote access is off, so that device can see nothing.
final class DeviceRemoteNudge extends RemoteAccessNudge {
  const DeviceRemoteNudge(this.deviceName);

  final String deviceName;
}

/// Decides which remote-access nudge (if any) the New Session canvas shows.
///
/// autoDispose so the minute-cadence device poll behind
/// [otherAccountMobileDevicesProvider] tears down with the banner.
final remoteAccessNudgeProvider = Provider.autoDispose<RemoteAccessNudge?>((
  ref,
) {
  // ORDER MATTERS: bail on mobile BEFORE touching remoteAccessPolicyProvider —
  // that provider's chain (hostControlClientProvider → ensureHost) spawns the
  // local bridge host, which must never happen from a phone.
  if (isMobilePlatform) return null;
  // The checklist has the floor: its "Connect your phone" step covers the same
  // ground, and two onboarding cards stacked would drown each other out.
  if (ref.watch(firstRunChecklistVisibleProvider)) return null;
  if (ref.watch(signedInProvider) != true) return null;
  final policy = ref.watch(remoteAccessPolicyProvider).value;
  // Unknown (still loading / host unreachable) or already on → say nothing.
  if (policy == null || policy.enabled) return null;
  final fr = ref.watch(firstRunProvider);
  // The ACCOUNT device inventory, not the bridge roster (remoteDevicesProvider)
  // — the roster only lists devices that already connected to this machine,
  // which mostly can't happen before remote access is on; the nudge's whole
  // trigger is "signed in, not yet connected".
  final others = ref.watch(otherAccountMobileDevicesProvider).value ?? const [];
  if (others.isNotEmpty) {
    return fr.nudgeDeviceDismissed
        ? null
        : DeviceRemoteNudge(others.first.displayName);
  }
  return fr.nudgeSoftDismissed ? null : const SoftRemoteNudge();
});
