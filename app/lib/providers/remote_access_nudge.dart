import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../utils/platform_utils.dart';
import 'auth.dart';
import 'demo_mode.dart';
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
/// autoDispose so the five-minute device poll behind
/// [otherAccountMobileDevicesProvider] tears down with the banner.
final remoteAccessNudgeProvider = Provider.autoDispose<RemoteAccessNudge?>((
  ref,
) {
  // ORDER MATTERS: bail on mobile BEFORE touching remoteAccessPolicyProvider —
  // that provider's chain (hostControlClientProvider → ensureHost) spawns the
  // local bridge host, which must never happen from a phone.
  if (isMobilePlatform) return null;
  // Same order, second reason: besides the host spawn, the banner's action is
  // `confirmAndEnableRemoteAccess` — the machine-wide grant. Offering that
  // beside canned data invites a reviewer to open their own machine up from
  // inside a sample project (the guard `agent_panel.dart` makes for the title
  // bar's version of the same control).
  if (ref.watch(demoModeProvider)) return null;
  // The checklist has the floor: its "Connect your phone" step covers the same
  // ground, and it now sits in the sidebar for the whole session — so a banner
  // saying the same thing on the canvas would be a second voice, permanently.
  if (ref.watch(firstRunChecklistVisibleProvider)) return null;
  if (ref.watch(signedInProvider) != true) return null;
  final policy = ref.watch(remoteAccessPolicyProvider).value;
  // Unknown (still loading / host unreachable) or already on → say nothing.
  if (policy == null || policy.enabled) return null;
  final fr = ref.watch(firstRunProvider);
  // Both variants dismissed → nothing can ever render; return BEFORE watching
  // the device inventory so its poll tears down instead of fetching forever
  // for a value that can only be null.
  if (fr.nudgeSoftDismissed && fr.nudgeDeviceDismissed) return null;
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
