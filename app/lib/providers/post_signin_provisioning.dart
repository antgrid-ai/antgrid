import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../analytics/events.dart';
import '../services/auth_service.dart';
import '../services/devices_api.dart' show ProvisioningException;
import 'analytics.dart';
import 'auth.dart';
import 'device_provisioning.dart';
import 'providers.dart';
import 'subscription.dart';

/// Activates an idempotent provisioning hook tied to `currentUserProvider`:
///
///   - Signed out (`null`) → no-op.
///   - Signed in (`CurrentUser`) → call `DeviceProvisioning.ensureProvisioned`
///     (which short-circuits if a record for that user already exists in the
///     keychain). After it succeeds, invalidate both `licenseTokenMinterProvider`
///     and `localDeviceUuidProvider` so subsequent reads pick up the new keychain
///     record.
///
/// The hook MUST be kept subscribed for the whole app lifetime — `main.dart`
/// does `container.listen(postSignInProvisioningProvider, ...)`.
final postSignInProvisioningProvider = Provider<void>((ref) {
  ref.listen<AsyncValue<CurrentUser?>>(currentUserProvider, (prev, next) {
    final user = next.value;
    if (user == null) {
      // Deferred: `fireImmediately` runs this synchronously while this very
      // provider is still building, and writing another provider's state
      // mid-build trips riverpod's "modified while building" assertion.
      Future.microtask(() {
        // The container may have disposed before this tick; ref.mounted guards
        // the post-async-gap read (a bare read would throw UnmountedRefException).
        if (ref.mounted) ref.read(deviceCapProvider.notifier).set(null);
      });
      return;
    }
    () async {
      try {
        final prefs = SharedPreferencesAsync();
        final existing = await prefs.getString(kLocalHostUuidKey);
        final rec = await ref
            .read(deviceProvisioningProvider)
            .ensureProvisioned(
              userId: user.userId,
              displayName: await hostDisplayName(),
              existingDeviceUuid: existing,
            );
        if (await prefs.getString(kLocalHostUuidKey) != rec.deviceUuid) {
          await prefs.setString(kLocalHostUuidKey, rec.deviceUuid);
        }
        // The container may have disposed during the awaits above (e.g. test
        // teardown); a bare ref.read/invalidate past that point throws
        // UnmountedRefException.
        if (!ref.mounted) return;
        ref.read(analyticsServiceProvider)?.track(AnalyticsEvents.deviceProvisioned);
        ref.read(deviceCapProvider.notifier).set(null);
        ref.invalidate(licenseTokenMinterProvider);
        ref.invalidate(localDeviceUuidProvider);
        prefetchSubscriptionCache(ref);
      } on ProvisioningException catch (e) {
        // This closure is fire-and-forget: the user may have signed out (which
        // already cleared deviceCapProvider) or switched accounts while the
        // network round-trip was in flight. Re-check identity before writing —
        // otherwise a late cap rejection pops a phantom dialog over the
        // signed-out auth screen.
        if (!ref.mounted) return;
        if (ref.read(currentUserProvider).value?.userId != user.userId) {
          return;
        }
        if (e.code == 'DEVICE_CAP' && e.cap != null) {
          // Fair-use cap reached — surface the actionable "remove a device"
          // flow (see deviceCapProvider watcher), NOT a silent failure or an
          // upgrade prompt (upgrading can't raise deviceLimit; it's flat).
          ref.read(deviceCapProvider.notifier).set(e.cap);
        } else {
          debugPrint(
            '[postSignInProvisioning] provisioning failed (${e.code}): ${e.message}',
          );
        }
      } catch (e) {
        debugPrint('[postSignInProvisioning] device provisioning failed: $e');
      }
    }();
  }, fireImmediately: true);
});

/// Re-attempt machine provisioning after the user freed a device slot from the
/// device-cap dialog. Mirrors the success side-effects of
/// [postSignInProvisioningProvider]. Rethrows [ProvisioningException] (e.g.
/// still over cap) so the caller can keep the remediation UI open.
Future<void> retryDeviceProvisioning(WidgetRef ref) async {
  await ensureCurrentUserDeviceRecord(ref);
  ref.read(deviceCapProvider.notifier).set(null);
  ref.invalidate(licenseTokenMinterProvider);
  ref.invalidate(localDeviceUuidProvider);
  prefetchSubscriptionCache(ref);
}
