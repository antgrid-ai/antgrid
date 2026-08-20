import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../project/project_session.dart';
import '../project/project_session_registry.dart';
import '../services/devices_api.dart';
import '../services/push_identity.dart';
import '../services/sign_out_service.dart';
import 'auth.dart';
import 'chat_composer_drafts.dart';
import 'connection_identity.dart';
import 'device_provisioning.dart';
import 'entry_cleanup.dart';
import 'providers.dart';
import 'push.dart';
import 'recent_agents.dart';
import 'relay_connection.dart';
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
    pushIdentity: PushIdentity.secure(),
    recentAgentsStore: ref.read(recentAgentsStoreProvider),
    clearPushToken: () async {
      final sessions = ref
          .read(projectSessionRegistryProvider)
          .map((id) => ref.read(projectSessionProvider(id)).value)
          .whereType<ProjectSession>();
      // The SAME instance startup registered on — clearToken resets its cached
      // token/registered-set so a re-sign-in re-registers (see push.dart).
      await ref
          .read(pushMessagingServiceProvider)
          .clearToken(sessions: sessions);
    },
    stopMinter: () async {
      final minter = await ref.read(licenseTokenMinterProvider.future);
      minter?.stop();
    },
    closeSessions: () async {
      final controller = ref.read(projectSessionRegistryProvider.notifier);
      // Evict a snapshot — forceEvictAndSettle mutates the underlying list.
      // AWAITED (not the fire-and-forget forceEvict): eviction's `onEvict`
      // writes the project's session + status caches, and `clearCaches` below
      // deletes those very files — same write-then-purge ordering the delete
      // paths depend on. Concurrent across projects — each only touches its
      // own cache entries, so there's no ordering dependency between them.
      await Future.wait([
        for (final id in controller.registry.openProjects.toList())
          controller.forceEvictAndSettle(id),
      ]);
    },
    clearCaches: () => purgeAccountCaches(ref),
    releaseControlPlanes: () async {
      // Per-id release, not disposeAll: disposeAll closes the manager's change
      // stream for good, and the same manager must serve a later re-sign-in.
      final mgr = ref.read(relayConnectionManagerProvider);
      for (final id in mgr.openControlPlaneIds()) {
        mgr.release(id);
      }
    },
  );
});

/// The single hard sign-out entry point. Runs the full teardown, then
/// invalidates the identity- and account-derived providers so the app
/// re-renders in its signed-out state and a fresh sign-in re-provisions
/// cleanly.
///
/// Takes a [ProviderContainer], not a `WidgetRef`: server-driven revocation
/// (see `device_revocation.dart`) has to sign out from an error callback with
/// no widget behind it, and a `WidgetRef` read after the teardown's awaits
/// would throw on a disposed element anyway.
Future<void> performHardSignOut(ProviderContainer ref) async {
  await ref.read(signOutServiceProvider).hardSignOut();
  ref.read(chatComposerDraftsProvider).clear();
  ref.invalidate(licenseTokenMinterProvider);
  ref.invalidate(connectionTokenMinterProvider);
  ref.invalidate(currentUserProvider);
  ref.invalidate(hasStoredSessionProvider);
  ref.invalidate(subscriptionProvider);
  ref.invalidate(pricingCatalogProvider);
  ref.read(deviceCapProvider.notifier).set(null);
  // The caches are gone from disk, but the always-mounted ControlPlaneReaper
  // holds its own in-memory copy (paired-machine list, account inventory,
  // agent catalog, labels/status maps) and would keep serving it for the rest
  // of the process otherwise. `controlPlaneResetProvider` is the reaper's own
  // reset hook — see its doc for why this is one call rather than a hand-kept
  // list of the providers it owns. Without it the drawer and Recent list still
  // show the signed-out account's machines until the app is restarted.
  ref.read(controlPlaneResetProvider)?.call();
}
