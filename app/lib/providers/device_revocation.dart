import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/license_token_minter.dart';
import '../util/ab_log.dart';
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
  bool signingOut = false;
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
  final coordinator = ref.read(_coordinatorProvider);
  if (coordinator.signingOut || ref.read(revokedNoticeProvider)) return;
  coordinator.signingOut = true;

  AbLog.warn('Revocation', 'device revoked by the account — signing out');
  try {
    await performHardSignOut(ref);
  } finally {
    coordinator.signingOut = false;
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
/// so `/api/auth/oauth2/token` answers 401 → [DeviceRevokedException].
///
/// **Only that exception signs anyone out.** A transport failure means offline,
/// not revoked, and must leave the session alone.
Future<void> checkDeviceRevoked(ProviderContainer ref) async {
  final coordinator = ref.read(_coordinatorProvider);
  final now = DateTime.now();
  final last = coordinator.lastProbe;
  if (last != null && now.difference(last) < _kProbeCooldown) return;
  if (ref.read(revokedNoticeProvider)) return;

  coordinator.lastProbe = now;
  try {
    // The MAIN account record, not the desktop controller record: this is the
    // installation's identity on the account, and it is the one a cold start
    // has without dialling anything.
    final minter = await ref.read(licenseTokenMinterProvider.future);
    if (minter == null) return; // signed out, or never provisioned
    await minter.mint();
  } on DeviceRevokedException {
    await handleDeviceRevoked(ref);
  } catch (error) {
    AbLog.debug('Revocation', 'probe inconclusive: $error');
  }
}
