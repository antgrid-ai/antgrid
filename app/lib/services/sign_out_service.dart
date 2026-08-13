import 'package:collection/collection.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'auth_service.dart';
import 'devices_api.dart';
import 'keychain_device_store.dart';
import 'push_identity.dart';
import '../config/storage_scope.dart';
import '../storage/recent_agents_store.dart';
import '../util/ab_log.dart';

/// Secure-storage key prefixes of the retired per-machine phone pairing
/// keypairs. The class that wrote them (`PhoneIdentity`) is gone, so these are
/// the only remaining handle on the seeds it left at rest.
const _kRetiredPhonePrivPrefix = 'antgrid.phone_priv.';
const _kRetiredPhonePubPrefix = 'antgrid.phone_pub.';

/// Orchestrates a **hard** sign-out: revoke this device on the account, then
/// wipe every piece of local identity and connection state so the app lands in
/// a clean signed-out condition.
///
/// Two principles drive the ordering and error handling:
///   - **Server revoke happens while the cookie is still valid** — it runs
///     before [AuthService.signOut] clears the session.
///   - **Local teardown always completes.** Server revoke, minter stop, and
///     session close are best-effort; a failure in any one of them must not
///     leave a half-signed-out state with stale keys at rest.
///
/// Provider invalidation and the live-session eviction are injected as
/// [stopMinter]/[closeSessions] callbacks so this class stays free of Riverpod
/// and is unit-testable in isolation. See `providers/sign_out.dart` for the
/// wiring that both UI entry points call.
class SignOutService {
  SignOutService({
    required this.authService,
    required this.keychainStore,
    required this.devicesApi,
    required this.pushIdentity,
    required this.recentAgentsStore,
    this.stopMinter,
    this.clearPushToken,
    this.closeSessions,
    this.clearCaches,
    this.releaseControlPlanes,
    FlutterSecureStorage? secureStorage,
    void Function(Object error, StackTrace stack)? onStepError,
  }) : _secureStorage = secureStorage ?? const FlutterSecureStorage(),
       _onStepError = onStepError ?? _debugReport;

  final AuthService authService;
  final KeychainDeviceStore keychainStore;
  final DevicesApi devicesApi;

  /// The machine-wide X25519 push key. Wiped on sign-out so a signed-out
  /// machine keeps no usable push-decryption key at rest — the seed is treated
  /// as account-sensitive material alongside the keychain records.
  final PushIdentity pushIdentity;

  final RecentAgentsStore recentAgentsStore;

  /// Cancels the license-token refresh timer so it can't re-mint mid-teardown.
  final Future<void> Function()? stopMinter;

  /// Tells every warm session's paired agent to stop pushing to this device
  /// (empty-token `push:register`). Must run before [closeSessions] tears down
  /// the transports it needs to send on — a signed-out phone with no more live
  /// sessions can't ask agents to stop later.
  final Future<void> Function()? clearPushToken;

  /// Tears down live relay/project transports, awaiting each eviction so the
  /// callbacks that write the session/status caches have settled before
  /// [clearCaches] deletes them.
  final Future<void> Function()? closeSessions;

  /// Wipes every persisted cache derived from the account — cached session
  /// lists, project labels and work status, remembered ports, the agent
  /// catalog, the paired-machine list, per-project file-tree prefs. Identity
  /// material has its own steps below; this is the DATA those machines
  /// reported, which the drawer and Recent list render straight off disk on the
  /// next launch, signed in or not. Runs after [closeSessions] so no live
  /// write-through can land behind it.
  final Future<void> Function()? clearCaches;

  /// Closes every machine control-plane socket still open (eager launch dials,
  /// viewed machines — [closeSessions] only evicts project sessions, never
  /// machine sockets). Runs LAST: the reaper normally owns release, but
  /// sign-out unmounts it in a race against the recents-clear ripple, and a
  /// resume during the slow revoke steps can even dial fresh sockets — this
  /// step is the deterministic backstop that a signed-out app holds no open
  /// relay connections.
  final Future<void> Function()? releaseControlPlanes;

  /// Backs the retired-key sweep below. Everything else on this class reaches
  /// secure storage through its own narrow seam; this one needs the raw store
  /// because the keys it deletes have no owner left to ask.
  final FlutterSecureStorage _secureStorage;

  /// Reports a swallowed step failure. Best-effort steps never throw out of
  /// [hardSignOut], but a failed server revoke must remain observable — it
  /// means the device is still live on the account despite the user's intent.
  final void Function(Object error, StackTrace stack) _onStepError;

  Future<void> hardSignOut() async {
    // Tell paired agents to stop pushing to this device while sessions are
    // still live — closeSessions below tears down the transports this needs.
    await _swallow('clearPushToken', () async => clearPushToken?.call());

    // Stop token churn and begin tearing down live connections first, before we
    // revoke and drop the credentials they depend on.
    await _swallow('stopMinter', () async => stopMinter?.call());
    await _swallow('closeSessions', () async => closeSessions?.call());

    // Revoke this device server-side while the session cookie is still valid.
    await _swallow('revokeDevice', _revokeDeviceServerSide);

    // Drop the session (server sign-out + clear cookie). Must come AFTER the
    // server revoke above, which needs the cookie.
    await _swallow('signOut', authService.signOut);

    // Wipe persisted identity material so nothing replayable remains at rest.
    await _swallow('clearKeychain', keychainStore.clear);
    await _swallow('clearControllerKeychain', keychainStore.clearController);
    await _swallow('clearPushIdentity', pushIdentity.clear);
    await _swallow('clearRecentAgents', recentAgentsStore.clear);
    await _swallow('clearRetiredPhoneKeys', _sweepRetiredPhonePairingKeys);
    await _swallow('clearCaches', () async => clearCaches?.call());

    // After clearRecentAgents: anything a mid-sign-out resume eagerly dialed
    // is caught here too.
    await _swallow(
      'releaseControlPlanes',
      () async => releaseControlPlanes?.call(),
    );
  }

  /// Deletes the retired per-machine phone pairing seeds.
  ///
  /// Pre-cutover builds persisted these seeds at rest; installs upgraded from
  /// one still carry them even though account trust never reads them. Stale
  /// key material must not linger on a shared or lost phone, so sign-out
  /// sweeps it every time as a one-time cleanup for those installs.
  ///
  /// Prefix-scanned rather than [FlutterSecureStorage.deleteAll]: the device
  /// records, session cookie and push seed each have their own teardown step,
  /// and a blanket wipe would also take unrelated entries. The prefixes go
  /// through [scopedStorageKey] so a local dev build only ever sweeps its own
  /// keys.
  Future<void> _sweepRetiredPhonePairingKeys() async {
    final privPrefix = scopedStorageKey(_kRetiredPhonePrivPrefix);
    final pubPrefix = scopedStorageKey(_kRetiredPhonePubPrefix);
    // Snapshot the key set: deleting while iterating the live view is unsafe.
    final keys = (await _secureStorage.readAll()).keys.toList(growable: false);
    var failed = 0;
    for (final key in keys) {
      if (!key.startsWith(privPrefix) && !key.startsWith(pubPrefix)) continue;
      try {
        await _secureStorage.delete(key: key);
      } catch (_) {
        // Each seed is independent — one stubborn entry must not skip the rest.
        failed++;
      }
    }
    // Count only: naming a surviving key would leak into the log which machines
    // this phone was trusted by.
    if (failed > 0) {
      throw StateError(
        '$failed retired phone pairing key(s) survived the wipe',
      );
    }
  }

  /// Look up this device's account row(s) by stable `deviceUuid` and delete
  /// them. Desktop carries two independent rows — the main record and the
  /// controller record (see `keychain_device_store.dart`) — and both must be
  /// revoked here or the controller row survives every sign-out/sign-in cycle
  /// and burns an account `app_device_limit` slot forever. Both reads happen
  /// before either keychain slot is wiped further down in [hardSignOut].
  Future<void> _revokeDeviceServerSide() async {
    final device = await keychainStore.read();
    final controller = await keychainStore.readController();
    if (device == null && controller == null) return;
    final all = await devicesApi.list();
    var failed = 0;
    for (final record in <DeviceRecord?>[device, controller]) {
      if (record == null) continue;
      final match = all.firstWhereOrNull(
        (d) => d.deviceId == record.deviceUuid,
      );
      if (match == null) continue;
      try {
        await devicesApi.revoke(match.id);
      } catch (_) {
        // The rows are independent, and [hardSignOut] wipes the local pointer
        // to both a few steps later. Letting one transient failure abort the
        // loop would orphan the other row on the account — burning an
        // app_device_limit slot with nothing left locally to retry from.
        failed++;
      }
    }
    if (failed > 0) {
      throw StateError('$failed device row(s) survived the server revoke');
    }
  }

  Future<void> _swallow(String step, Future<void> Function() op) async {
    try {
      await op();
    } catch (e, st) {
      // Best-effort: every step is independent and local teardown must finish
      // even if an earlier (often network-dependent) step fails — but the
      // failure is reported, never silently dropped.
      _onStepError(StateError('hard sign-out step "$step" failed: $e'), st);
    }
  }

  static void _debugReport(Object error, StackTrace stack) {
    AbLog.error('SignOutService', '$error');
  }
}
