import 'dart:io';
import 'package:uuid/uuid.dart';
import 'agent_keys.dart';
import 'devices_api.dart' show ProvisioningException;
import 'devices_api_contract.dart';
import 'keychain_device_store.dart';

export 'devices_api_contract.dart' show DevicesApiCreator;

class DeviceProvisioning {
  DeviceProvisioning({
    required this.api,
    required this.store,
    required this.platform,
  });

  final DevicesApiCreator api;
  final KeychainDeviceStore store;
  final String platform;

  // postSignInProvisioning, localHostWarmup, and agentTransport each resolve
  // the device record independently at sign-in and would otherwise race:
  // concurrent calls all see no cached record, each mint their OWN keypair,
  // and each re-upload via createDevice — the server ends up with whichever
  // upload's network call lands last, which need not be the same keypair any
  // one caller (e.g. the bridge bootstrap) actually captured. That skew is
  // silent until the agent signs a handshake with a key `/account/agents`
  // no longer reports, which the app then (correctly) rejects as a possible
  // MITM. Sharing one in-flight future makes every caller await the SAME
  // single attempt instead of racing independent ones.
  Future<DeviceRecord>? _inFlight;

  Future<DeviceRecord> ensureProvisioned({
    required String userId,
    required String displayName,
    String? existingDeviceUuid,
  }) {
    return _inFlight ??= _doEnsureProvisioned(
      userId: userId,
      displayName: displayName,
      existingDeviceUuid: existingDeviceUuid,
    ).whenComplete(() => _inFlight = null);
  }

  Future<DeviceRecord> _doEnsureProvisioned({
    required String userId,
    required String displayName,
    String? existingDeviceUuid,
  }) async {
    final cached = await store.readIfMatchesUser(userId);
    if (cached != null) return cached;
    // Either no record or a userId mismatch — clear and start fresh.
    await store.clear();

    final keys = await AgentKeys.generate();
    // Reuse an existing anonymous/local device UUID when provided (e.g. one
    // persisted by `_resolveLocalHostUuid` for projects opened before sign-in).
    // Otherwise mint fresh. Reusing keeps this device's identity stable across
    // the anonymous→signed-in transition so inventory dedup, isLocalFor(), and
    // any project rows already stamped with the prefs UUID continue to align.
    final deviceUuid = existingDeviceUuid ?? const Uuid().v4();
    final created = await api.createDevice(
      deviceUuid: deviceUuid,
      ed25519Pub: keys.ed25519PubBase64,
      x25519Pub: keys.x25519PubBase64,
      platform: platform,
      displayName: displayName,
    );

    if (created.clientSecret == null) {
      // We generated a brand-new deviceUuid; server should never return an
      // idempotent 200 on a fresh provision. Treat as failure.
      throw ProvisioningException(
        'UNKNOWN',
        'server returned existing device without secret on fresh provision',
      );
    }

    final rec = DeviceRecord(
      userId: userId,
      deviceUuid: created.deviceUuid,
      clientId: created.clientId,
      clientSecret: created.clientSecret!,
      ed25519Pub: keys.ed25519PubBase64,
      ed25519Priv: keys.ed25519PrivBase64,
      x25519Pub: keys.x25519PubBase64,
      x25519Priv: keys.x25519PrivBase64,
    );
    try {
      await store.write(rec);
    } catch (e) {
      throw ProvisioningException('UNKNOWN', 'keychain write failed: $e');
    }
    return rec;
  }
}

String detectPlatform() {
  if (Platform.isMacOS) return 'macos';
  if (Platform.isWindows) return 'windows';
  if (Platform.isLinux) return 'linux';
  if (Platform.isIOS) return 'ios';
  if (Platform.isAndroid) return 'android';
  return 'linux';
}
