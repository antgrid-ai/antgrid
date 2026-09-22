import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../config/storage_scope.dart';
import '../services/device_provisioning.dart';
import '../services/devices_api.dart';
import '../services/keychain_device_store.dart';
import 'auth.dart';
import 'provider_retry.dart';

bool _isDesktopPlatform() =>
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.linux;

final keychainDeviceStoreProvider = Provider<KeychainDeviceStore>((ref) {
  return KeychainDeviceStore();
});

/// Full [DevicesApi] (list / revoke / create) for the signed-in account.
/// Provisioning goes through [deviceProvisioningProvider] (the create slice);
/// this exposes list + revoke for the device-cap remediation UI.
final devicesApiProvider = Provider<DevicesApi>((ref) {
  final auth = ref.watch(authServiceProvider);
  return DevicesApi(
    licenseApiUrl: ref.watch(licenseApiUrlProvider),
    cookieProvider: () => auth.storage.readCookie(),
  );
});

final deviceProvisioningProvider = Provider<DeviceProvisioning>((ref) {
  // Reuse the single account [DevicesApi] (list / revoke / create) rather than
  // building a second instance with its own http.Client for the same account.
  return DeviceProvisioning(
    api: ref.watch(devicesApiProvider),
    store: ref.watch(keychainDeviceStoreProvider),
    platform: detectPlatform(),
  );
});

/// Resolves the stable UUID that identifies THIS device as a local host.
///
/// Priority:
/// 1. The signed-in [DeviceRecord.deviceUuid] from the keychain.
/// 2. A persisted anonymous UUID in SharedPreferences (key `antgrid.local_host_uuid`).
/// 3. On desktop, a freshly-minted UUIDv4 persisted under the same key — so the
///    provider is non-null for any desktop host. This self-heals the case where
///    a project pre-existed (migrated, or selected from the drawer) and never
///    went through `open_folder_button.dart`'s fresh-open path. Without it,
///    the remote-host chip and any host-identity check would stay unresolved
///    for such projects.
/// 4. `null` — only on mobile/web, where there is no local-host concept.
final localDeviceUuidProvider = FutureProvider<String?>((ref) async {
  final store = ref.read(keychainDeviceStoreProvider);
  final record = await store.read();
  if (record != null) return record.deviceUuid;

  final prefs = SharedPreferencesAsync(
    options: desktopSharedPreferencesOptions,
  );
  final existing = await prefs.getString(kLocalHostUuidKey);
  if (existing != null) return existing;

  // No keychain record and nothing persisted. On desktop, mint + persist an
  // anonymous host UUID now so local projects are always identifiable and the
  // enable-mobile affordance shows. On mobile/web, stay null (no local host).
  if (!_isDesktopPlatform()) return null;
  final fresh = const Uuid().v4();
  await prefs.setString(kLocalHostUuidKey, fresh);
  return fresh;
  // retry: a keychain read error must reject `.future` so the transport build
  // awaiting it surfaces the failure (→ machine-less open / offline handling)
  // rather than stalling in Riverpod 3's retry loop. See provider_retry.dart.
}, retry: noProviderRetry);

/// SharedPreferences key for this device's anonymous local-host UUID. The ONE
/// key shared across providers/widgets (here, [postSignInProvisioningProvider],
/// `open_folder_button.dart`), so it lives in a single const — a divergent
/// literal would silently re-mint the host identity. Read via cacheless
/// [SharedPreferencesAsync] (never WithCache) precisely because it's shared:
/// per-instance sync caches would drift.
final kLocalHostUuidKey = scopedStorageKey('antgrid.local_host_uuid');

/// `Platform.localHostname` is the kernel network hostname, not a human
/// device label — on Android it's commonly the literal string "localhost",
/// which is worse than useless in a device-picker UI. Prefer a real
/// device-info source per platform: iOS exposes the user-assigned name
/// (Settings > General > About > Name) directly; Android has no equivalent
/// public API, so manufacturer+model is the closest available substitute.
/// Desktop hostnames are meaningful as-is, so they skip device_info_plus.
///
/// Shared with [postSignInProvisioningProvider]: both entry points provision
/// the same machine record, so a divergent label here would rename the device
/// depending on which one happened to win the race.
Future<String> hostDisplayName() async {
  if (Platform.isAndroid) {
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      final label = '${info.manufacturer} ${info.model}'.trim();
      if (label.isNotEmpty) return label;
    } catch (_) {}
  } else if (Platform.isIOS) {
    try {
      final info = await DeviceInfoPlugin().iosInfo;
      if (info.name.isNotEmpty) return info.name;
    } catch (_) {}
  }
  try {
    return Platform.localHostname;
  } catch (_) {
    return 'antgrid-client';
  }
}
