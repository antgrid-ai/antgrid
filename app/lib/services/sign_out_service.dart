import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import 'auth_service.dart';
import 'devices_api.dart';
import 'keychain_device_store.dart';
import 'phone_identity.dart';
import 'push_identity.dart';
import '../storage/recent_agents_store.dart';

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
    required this.phoneIdentity,
    required this.pushIdentity,
    required this.recentAgentsStore,
    this.stopMinter,
    this.clearPushToken,
    this.closeSessions,
    void Function(Object error, StackTrace stack)? onStepError,
  }) : _onStepError = onStepError ?? _debugReport;

  final AuthService authService;
  final KeychainDeviceStore keychainStore;
  final DevicesApi devicesApi;
  final PhoneIdentity phoneIdentity;

  /// The machine-wide X25519 push key. Wiped on sign-out so a signed-out
  /// machine keeps no usable push-decryption key at rest — the seed is treated
  /// as account-sensitive material alongside the phone keys and keychain.
  final PushIdentity pushIdentity;

  final RecentAgentsStore recentAgentsStore;

  /// Cancels the license-token refresh timer so it can't re-mint mid-teardown.
  final Future<void> Function()? stopMinter;

  /// Tells every warm session's paired agent to stop pushing to this device
  /// (empty-token `push:register`). Must run before [closeSessions] tears down
  /// the transports it needs to send on — a signed-out phone with no more live
  /// sessions can't ask agents to stop later.
  final Future<void> Function()? clearPushToken;

  /// Initiates teardown of live relay/project transports. Note this only
  /// *starts* the teardown — the registry's eviction is fire-and-forget, so a
  /// transport may briefly outlive the credentials cleared below. Acceptable:
  /// sign-out is terminal and the relay cascade-closes paired peers on the
  /// agent's own disconnect.
  final Future<void> Function()? closeSessions;

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
    await _swallow('clearPhoneKeys', phoneIdentity.clearAll);
    await _swallow('clearPushIdentity', pushIdentity.clear);
    await _swallow('clearRecentAgents', recentAgentsStore.clear);
  }

  /// Look up this device's account row by its stable `deviceUuid` and delete it.
  /// No-op when the device was never provisioned (nothing to remove).
  Future<void> _revokeDeviceServerSide() async {
    final device = await keychainStore.read();
    if (device == null) return;
    final all = await devicesApi.list();
    final match = all.firstWhereOrNull((d) => d.deviceId == device.deviceUuid);
    if (match != null) await devicesApi.revoke(match.id);
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
    if (kDebugMode) debugPrint('SignOutService: $error');
  }
}
