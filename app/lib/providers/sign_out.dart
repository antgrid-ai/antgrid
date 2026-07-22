import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../project/project_session.dart';
import '../project/project_session_registry.dart';
import '../services/devices_api.dart';
import '../services/push_identity.dart';
import '../services/sign_out_service.dart';
import 'auth.dart';
import 'device_provisioning.dart';
import 'providers.dart';
import 'push.dart';
import 'recent_agents.dart';
import 'subscription.dart';

/// Assembles a [SignOutService] from the live providers, wiring the two
/// Riverpod-dependent steps (minter stop, session eviction) as callbacks.
final signOutServiceProvider = Provider<SignOutService>((ref) {
  final auth = ref.read(authServiceProvider);
  return SignOutService(
    authService: auth,
    keychainStore: ref.read(keychainDeviceStoreProvider),
    devicesApi: DevicesApi(
      licenseApiUrl: ref.read(licenseApiUrlProvider),
      cookieProvider: () => auth.storage.readCookie(),
    ),
    phoneIdentity: ref.read(phoneIdentityProvider),
    pushIdentity: PushIdentity.secure(),
    recentAgentsStore: ref.read(recentAgentsStoreProvider),
    clearPushToken: () async {
      final sessions = ref
          .read(projectSessionRegistryProvider)
          .map((id) => ref.read(projectSessionProvider(id)).value)
          .whereType<ProjectSession>();
      // The SAME instance startup registered on — clearToken resets its cached
      // token/registered-set so a re-sign-in re-registers (see push.dart).
      await ref.read(pushMessagingServiceProvider).clearToken(sessions: sessions);
    },
    stopMinter: () async {
      final minter = await ref.read(licenseTokenMinterProvider.future);
      minter?.stop();
    },
    closeSessions: () async {
      final controller = ref.read(projectSessionRegistryProvider.notifier);
      // Evict a snapshot — forceEvict mutates the underlying list.
      for (final id in controller.registry.openProjects.toList()) {
        controller.forceEvict(id);
      }
    },
  );
});

/// The single hard sign-out entry point for the UI. Runs the full teardown,
/// then invalidates the identity-derived providers so the app re-renders in its
/// signed-out state and a fresh sign-in re-provisions cleanly.
Future<void> performHardSignOut(WidgetRef ref) async {
  await ref.read(signOutServiceProvider).hardSignOut();
  ref.invalidate(licenseTokenMinterProvider);
  ref.invalidate(currentUserProvider);
  ref.invalidate(hasStoredSessionProvider);
  ref.invalidate(subscriptionProvider);
  ref.invalidate(pricingCatalogProvider);
  ref.read(deviceCapProvider.notifier).set(null);
}
