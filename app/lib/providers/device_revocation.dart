import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/license_token_minter.dart';
import '../util/ab_log.dart';
import '../util/detached.dart';
import '../utils/platform_utils.dart';
import 'control_plane.dart' show hostControllerProvider;
import 'providers.dart';
import 'sign_out.dart';
import 'value_controller.dart';

/// Set once this device has been signed out *because the account revoked it*
/// (as opposed to the user signing out themselves). Its one job is to force the
/// sign-in gate on desktop, which is otherwise mobile-only — the screen carries
/// no revocation copy, by design.
///
/// Cleared by [clearRevokedNotice] on a fresh sign-in. That clear is
/// load-bearing, not cosmetic: while this is set the root pins itself to the
/// sign-in screen, so nothing else can retire it.
final revokedNoticeProvider = NotifierProvider<ValueController<bool>, bool>(
  () => ValueController(false),
);

/// Minimum spacing between [checkDeviceRevoked] network probes. Launch and
/// every resume call it; without this a foreground/background flap would mint a
/// token per flap.
const _kProbeCooldown = Duration(minutes: 5);

/// Cross-call state for revocation handling. Lives on a plain [Provider] so it
/// survives the provider invalidation `performHardSignOut` performs — the guard
/// is worthless if the teardown it guards resets it.
class _RevocationCoordinator {
  DateTime? lastProbe;
}

final _coordinatorProvider = Provider<_RevocationCoordinator>(
  (ref) => _RevocationCoordinator(),
);

/// Signs this device out because the account no longer recognises it.
///
/// **Idempotent.** Every open machine supervisor reports the same revocation
/// independently (one relay socket per machine), and the mint path can raise it
/// again on top — the teardown must run exactly once.
Future<void> handleDeviceRevoked(ProviderContainer ref) async {
  if (hardSignOutInFlight(ref) || ref.read(revokedNoticeProvider)) return;

  AbLog.warn('Revocation', 'device revoked by the account — signing out');
  try {
    await performHardSignOut(ref);
  } finally {
    // Set last: the notice is what flips the root to the sign-in screen, and
    // the screen must not appear while credentials are still being wiped.
    ref.read(revokedNoticeProvider.notifier).set(true);
  }
}

/// Clears the revoked banner + the probe cooldown after a successful sign-in,
/// so a later revocation in the same process is handled afresh.
void clearRevokedNotice(ProviderContainer ref) {
  ref.read(_coordinatorProvider).lastProbe = null;
  ref.read(revokedNoticeProvider.notifier).set(false);
}

/// The cold-start / resume revocation check.
///
/// Revoking a device does NOT invalidate this app's Better-Auth session cookie,
/// so `/account/me` keeps returning a user and nothing else would notice until
/// a relay dial happens (which on desktop may be never). Minting is the
/// authoritative oracle instead: revocation deletes the device's OAuth client,
/// so `/api/auth/oauth2/token` rejects it with `invalid_client`, which becomes
/// [DeviceRevokedException].
///
/// **Only that exception signs anyone out.** A transport failure means offline,
/// not revoked, and must leave the session alone.
///
/// [force] skips the cooldown, for a caller that already holds evidence the
/// credentials died rather than a mere lifecycle tick.
Future<void> checkDeviceRevoked(
  ProviderContainer ref, {
  bool force = false,
}) async {
  final coordinator = ref.read(_coordinatorProvider);
  final now = DateTime.now();
  final last = coordinator.lastProbe;
  if (!force && last != null && now.difference(last) < _kProbeCooldown) return;
  if (ref.read(revokedNoticeProvider)) return;

  coordinator.lastProbe = now;
  LicenseTokenMinter? minter;
  try {
    // The MAIN account record, not the desktop controller record: this is the
    // installation's identity on the account, and it is the one a cold start
    // has without dialling anything.
    minter = await ref.read(licenseTokenMinterProvider.future);
    if (minter == null) return; // signed out, or never provisioned
    await minter.mint();
  } on DeviceRevokedException {
    // A sign-out that finished while the mint was out has already retired
    // these credentials, and its own revoke is what the mint just heard.
    if (!identical(await ref.read(licenseTokenMinterProvider.future), minter)) {
      return;
    }
    await handleDeviceRevoked(ref);
  } catch (error) {
    AbLog.debug('Revocation', 'probe inconclusive: $error');
  }
}

/// Routes the local host's `auth_revoked` into [checkDeviceRevoked].
///
/// The host runs on the MAIN account record, so its relay or its token mint is
/// usually the first to learn that record was revoked; without this a desktop
/// that dials no machine finds out only at the next cooldown-gated resume
/// probe. The event is evidence, not the verdict: the bridge raises it for
/// LICENSE_INVALID too, a binding fault that is no reason to sign anyone out,
/// so the mint decides. Ignored during a sign-out, whose own server-side
/// revoke the host hears as one.
///
/// Never clears the keychain on its own. An empty keychain reads as "never
/// provisioned" to the probe, and the next resolve re-creates the same device
/// uuid, which the web answers by REACTIVATING the revoked row — undoing the
/// revocation with no one signing in.
///
/// Desktop-only; must stay listened for the app's whole life.
final hostRevocationWatchProvider = Provider<void>((ref) {
  if (isMobilePlatform) return;
  final container = ref.container;
  final sub = ref.read(hostControllerProvider).hostEvents.listen((event) {
    // The in-flight check only spares a mint: [handleDeviceRevoked] is what
    // keeps a sign-out's own revoke from starting a second one.
    if (event.kind != 'auth_revoked' || hardSignOutInFlight(container)) return;
    AbLog.info('Revocation', 'local host reported auth_revoked — probing');
    detached(
      'Revocation',
      'probe after host auth_revoked',
      () => checkDeviceRevoked(container, force: true),
    );
  });
  ref.onDispose(sub.cancel);
});
