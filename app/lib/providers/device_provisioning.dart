import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../config/storage_scope.dart';
import '../models/ab_project.dart';
import '../services/device_provisioning.dart';
import '../services/devices_api.dart';
import '../services/keychain_device_store.dart';
import '../util/ab_log.dart';
import 'auth.dart';
import 'projects.dart';
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

Future<DeviceRecord> ensureCurrentUserDeviceRecord(dynamic ref) async {
  final store = ref.read(keychainDeviceStoreProvider);
  final existingRecord = await store.read();
  if (existingRecord != null) return existingRecord;

  final user = await ref.read(currentUserProvider.future);
  if (user == null) {
    throw ProvisioningException('AUTH', 'Sign in required');
  }

  final prefs = SharedPreferencesAsync();
  final existing = await prefs.getString(kLocalHostUuidKey);
  final record = await ref
      .read(deviceProvisioningProvider)
      .ensureProvisioned(
        userId: user.userId,
        displayName: await hostDisplayName(),
        existingDeviceUuid: existing,
      );

  // Re-read rather than reuse `existing`: the desktop self-heal in
  // [localDeviceUuidProvider] mints and persists an anonymous uuid whenever it
  // is read with an empty keychain, which can land during the provisioning
  // round trip above — and a folder opened in that window is stamped with it.
  final outgoing = await prefs.getString(kLocalHostUuidKey);
  if (outgoing != record.deviceUuid) {
    await prefs.setString(kLocalHostUuidKey, record.deviceUuid);
    if (outgoing != null) {
      await _rehostLocalProjects(ref, from: outgoing, to: record.deviceUuid);
    }
  }
  ref.invalidate(localDeviceUuidProvider);
  return record;
}

/// Moves projects recorded against a replaced host identity onto the new one.
///
/// This is the only place a persisted host uuid is replaced by a *different*
/// value, so it is the only place that can repair the rows carrying the old
/// one: the prefs key self-heals, project rows never did, and a row left behind
/// fails [AbProject.isLocalFor] forever — losing its working-directory actions
/// and wearing a "Remote host" chip for a folder on this disk.
///
/// Swallowed: a failed repair must not fail provisioning, and the same rows are
/// still fixed by re-opening the folder (`registerPickedFolder`).
Future<void> _rehostLocalProjects(
  dynamic ref, {
  required String from,
  required String to,
}) async {
  try {
    await ref.read(projectsProvider.notifier).rehost(from: from, to: to);
  } catch (e) {
    AbLog.warn(
      'device_provisioning',
      'host uuid backfill skipped',
      fields: {'error': '$e'},
    );
  }
}

/// Best-effort resolve of the machine [DeviceRecord] to carry into a host
/// bootstrap: the keychain record if present, else provision one when a user is
/// signed in. ANY failure (auth fetch offline, provisioning rejected) resolves
/// to null so the caller proceeds machine-less — never blocks/aborts the spawn.
/// [logTag] prefixes the skip diagnostic. Shared by the eager warm-up and the
/// per-project open path, which must resolve the device identically.
Future<DeviceRecord?> resolveDeviceRecord(
  dynamic ref, {
  required String logTag,
}) async {
  final store = ref.read(keychainDeviceStoreProvider);
  DeviceRecord? device = await store.read();
  if (device == null) {
    try {
      // Await the future (not .value): a still-pending currentUserProvider
      // for a genuinely signed-in user would otherwise read as null and silently
      // skip provisioning.
      final signedIn = (await ref.read(currentUserProvider.future)) != null;
      if (signedIn) {
        device = await ensureCurrentUserDeviceRecord(ref);
      }
    } on ProvisioningException catch (e) {
      AbLog.error(
        logTag,
        'provisioning failed',
        fields: {'code': e.code, 'message': e.message},
      );
    } catch (e) {
      AbLog.warn(
        logTag,
        'skipped machine provisioning',
        fields: {'error': '$e'},
      );
    }
  }
  return device;
}

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

  final prefs = SharedPreferencesAsync();
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
