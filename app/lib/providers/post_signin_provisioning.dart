import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/auth_service.dart';
import '../services/devices_api.dart';
import '../util/ab_log.dart';
import '../util/detached.dart';
import 'auth.dart';
import 'provisioning_coordinator.dart';

/// Activates the account provisioning hook for the app lifetime.
///
/// main.dart keeps this provider subscribed. The listener captures a
/// [ProviderContainer] and a typed coordinator before starting asynchronous
/// work, so disposing a widget cannot invalidate an in-flight attempt.
final postSignInProvisioningProvider = Provider<void>((ref) {
  final container = ref.container;
  ref.listen<AsyncValue<CurrentUser?>>(currentUserProvider, (prev, next) {
    final coordinator = container.read(provisioningCoordinatorProvider);
    final user = next.value;
    if (user == null) {
      // fireImmediately runs during this provider's build. Defer the write so
      // Riverpod does not see another provider modified mid-build.
      Future<void>.microtask(coordinator.clearDeviceCap);
      return;
    }

    detached('postSignInProvisioning', 'provision signed-in device', () async {
      try {
        await coordinator.provisionSignedInUser(user.userId);
      } on ProvisioningException catch (error) {
        final capped =
            error.code == 'APP_DEVICE_CAP' || error.code == 'WORKER_CAP';
        if (!capped) {
          AbLog.error(
            'postSignInProvisioning',
            'provisioning failed',
            fields: {'code': error.code, 'message': error.message},
          );
        }
      } catch (error) {
        AbLog.error(
          'postSignInProvisioning',
          'device provisioning failed',
          fields: {'error': '$error'},
        );
      }
    });
  }, fireImmediately: true);
});
