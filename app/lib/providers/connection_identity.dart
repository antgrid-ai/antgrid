import 'dart:convert';
import 'dart:io' show Platform;

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/devices_api.dart';
import '../services/keychain_device_store.dart';
import '../services/license_token_minter.dart';
import 'auth.dart';
import 'device_provisioning.dart';
import 'provider_retry.dart';

/// Test seam for the desktop/mobile split. Read through a provider rather than
/// touching [Platform] at the use site so tests can exercise both branches.
/// Gates on the PLATFORM, not on a stored device kind — the app never persists
/// a kind.
final isMobilePlatformProvider = Provider<bool>(
  (_) => Platform.isIOS || Platform.isAndroid,
);

/// The identity a REMOTE-CONTROL connection presents to the relay and signs the
/// E2E transcript with. Mobile: the main account [DeviceRecord] (`kind:"app"`,
/// already in the peers inventory). Desktop: a dedicated controller record —
/// the main desktop record is the LOCAL bridge's relay identity
/// (`kind:"agent"`); reusing it would epoch-collide with our own bridge.
///
/// Lazily provisions the controller record on first read, so a desktop that has
/// never remote-controlled anything registers no extra device.
final connectionDeviceRecordProvider = FutureProvider<DeviceRecord>((
  ref,
) async {
  if (ref.watch(isMobilePlatformProvider)) {
    return ensureCurrentUserDeviceRecord(ref);
  }

  // The user comes FIRST, then the cached record — the read must be
  // user-scoped. Switching accounts without a hard sign-out leaves the previous
  // user's controller in the slot, and its clientId/clientSecret mint OAuth
  // tokens under THAT account: the relay would stamp this socket's userId with
  // the wrong account and evaluate entitlement and peer visibility against it.
  // Remote control needs the network anyway, so requiring the session lookup
  // costs nothing an offline fallback could buy back.
  final store = ref.read(keychainDeviceStoreProvider);
  final user = await ref.read(currentUserProvider.future);
  if (user == null) {
    throw ProvisioningException('AUTH', 'Sign in required');
  }

  final cached = await store.readControllerIfMatchesUser(user.userId);
  if (cached != null) return cached;

  return ref
      .read(deviceProvisioningProvider)
      .ensureControllerProvisioned(
        userId: user.userId,
        displayName: '${await hostDisplayName()} (controller)',
      );
  // retry: a provisioning rejection (device cap, auth) must reject `.future` so
  // the awaiting connection surfaces it instead of stalling in Riverpod 3's
  // retry loop — and so a capped account isn't retried into the API ten times.
}, retry: noProviderRetry);

/// The token minter for the record a remote-control connection actually
/// authenticates with — NOT `licenseTokenMinterProvider`, which is hard-wired
/// to the MAIN record. The relay checks revocation against the token's own
/// `deviceUuid` claim, so sharing one device's token across two devices would
/// make revoking either one kill both.
///
/// Null when no record can be resolved (signed out, or provisioning refused):
/// the dial then presents an empty token and the relay's license verdict is what
/// tells the user to sign in.
final connectionTokenMinterProvider = FutureProvider<LicenseTokenMinter?>((
  ref,
) async {
  final DeviceRecord record;
  try {
    record = await ref.watch(connectionDeviceRecordProvider.future);
  } on ProvisioningException {
    return null;
  }
  return LicenseTokenMinter(
    licenseApiUrl: ref.watch(licenseApiUrlProvider),
    clientId: record.clientId,
    clientSecret: record.clientSecret,
  );
}, retry: noProviderRetry);

/// [DeviceRecord.ed25519Priv] is the raw 32-byte Ed25519 seed
/// (`AgentKeys.generate` persists `extractPrivateKeyBytes()`), which is exactly
/// what the relay client's signing helpers expect.
///
/// [machineDeviceId] scopes the relay slot this identity dials with, so the app
/// can hold one socket per machine open at once — see [relaySlotId]. It changes
/// the transport address ONLY: the E2E transcript is signed with the bare
/// `deviceUuid` (`phoneDeviceId` in `RelayMechanisms`), which is what the agent
/// resolves us by in the account peers inventory.
DeviceIdentity connectionIdentityFor(
  DeviceRecord r, {
  required String machineDeviceId,
}) => DeviceIdentity(
  deviceId: relaySlotId(r.deviceUuid, machineDeviceId),
  name: 'Antgrid App',
  ed25519PublicKey: base64Decode(r.ed25519Pub),
  ed25519PrivateKey: base64Decode(r.ed25519Priv),
  x25519PublicKey: base64Decode(r.x25519Pub),
  x25519PrivateKey: base64Decode(r.x25519Priv),
);
