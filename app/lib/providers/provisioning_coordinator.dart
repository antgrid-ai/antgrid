import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../analytics/events.dart';
import '../config/storage_scope.dart';
import '../services/provisioning_coordinator.dart';
import '../util/ab_log.dart';
import 'analytics.dart';
import 'auth.dart';
import 'connection_identity.dart';
import 'device_provisioning.dart';
import 'projects.dart';
import 'providers.dart';
import 'subscription.dart';

final Provider<ProvisioningCoordinator> provisioningCoordinatorProvider =
    Provider<ProvisioningCoordinator>((ref) {
      final container = ref.container;
      final prefs = SharedPreferencesAsync(
        options: desktopSharedPreferencesOptions,
      );
      return ProvisioningCoordinator(
        provisioning: ref.watch(deviceProvisioningProvider),
        store: ref.watch(keychainDeviceStoreProvider),
        readCurrentUser: () => container.read(currentUserProvider.future),
        currentUserId: () => container.read(currentUserProvider).value?.userId,
        readDisplayName: hostDisplayName,
        readLocalHostUuid: () => prefs.getString(kLocalHostUuidKey),
        writeLocalHostUuid: (value) =>
            prefs.setString(kLocalHostUuidKey, value),
        rehostLocalProjects: ({required from, required to}) async {
          try {
            await container
                .read(projectsProvider.notifier)
                .rehost(from: from, to: to);
          } catch (error) {
            AbLog.warn(
              'device_provisioning',
              'host uuid backfill skipped',
              fields: {'error': '$error'},
            );
          }
        },
        publishSuccess: () {
          container
              .read(analyticsServiceProvider)
              ?.track(AnalyticsEvents.deviceProvisioned);
          container.invalidate(licenseTokenMinterProvider);
          container.invalidate(connectionTokenMinterProvider);
          container.invalidate(localDeviceUuidProvider);
          prefetchSubscriptionCache(container);
        },
        publishDeviceCap: (cap) =>
            container.read(deviceCapProvider.notifier).set(cap),
        onProvisioningError: (logTag, error) => AbLog.error(
          logTag,
          'provisioning failed',
          fields: {'code': error.code, 'message': error.message},
        ),
        onUnexpectedError: (logTag, error) => AbLog.warn(
          logTag,
          'skipped machine provisioning',
          fields: {'error': '$error'},
        ),
      );
    });
