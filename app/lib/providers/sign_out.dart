import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../connection/connection_supervisor.dart';
import '../connection/peer_runtime_owner.dart';
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
import 'peer_runtime.dart';
import 'subscription.dart';
import 'value_controller.dart';

final signOutCleanupErrorProvider =
    NotifierProvider<
      ValueController<SignOutCleanupIncomplete?>,
      SignOutCleanupIncomplete?
    >(() => ValueController<SignOutCleanupIncomplete?>(null));

/// Assembles a [SignOutService] from the live providers, wiring the two
/// Riverpod-dependent steps (minter stop, session eviction) as callbacks.
final signOutServiceProvider = Provider<SignOutService>((ref) {
  final auth = ref.read(authServiceProvider);
  final machineConnections = ref.read(relayConnectionManagerProvider);
  final peerRuntimeOwner = ref.read(peerRuntimeOwnerProvider);
  return SignOutService(
    authService: auth,
    keychainStore: ref.read(keychainDeviceStoreProvider),
    devicesApi: DevicesApi(
      licenseApiUrl: ref.read(licenseApiUrlProvider),
      cookieProvider: () => auth.storage.readCookie(),
    ),
    pushIdentity: PushIdentity.secure(),
    recentAgentsStore: ref.read(recentAgentsStoreProvider),
    blockNewWork: machineConnections.blockNewWork,
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
      final results = await machineConnections.disposeAll();
      final incomplete = results.entries
          .where((entry) => entry.value == NativeStopResult.cleanupIncomplete)
          .map((entry) => entry.key)
          .toList(growable: false);
      if (incomplete.isNotEmpty) {
        throw StateError(
          'machine cleanup incomplete for ${incomplete.length} connection(s)',
        );
      }
    },
    clearPeerRuntime: () async {
      final result = await peerRuntimeOwner.clear();
      if (!result.complete) {
        throw PeerRuntimeOwnerLockedException(peerRuntimeOwner.cleanupFailure!);
      }
    },
    onCleanupLocked: (failure) =>
        ref.read(signOutCleanupErrorProvider.notifier).set(failure),
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
  ref.read(signOutCleanupErrorProvider.notifier).set(null);
  ref.read(chatComposerDraftsProvider).clear();
  ref.invalidate(peerRuntimeProvider);
  ref.invalidate(peerRuntimeOwnerProvider);
  ref.invalidate(relayConnectionManagerProvider);
  ref.invalidate(signOutServiceProvider);
  ref.invalidate(licenseTokenMinterProvider);
  // Load-bearing on its own, and NOT covered by the minter invalidate below:
  // this is a non-autoDispose FutureProvider, so invalidating a provider that
  // merely watches it leaves the resolved record cached for the life of the
  // process. hardSignOut has just deleted that controller row and its OAuth
  // client server-side, so a surviving record mints `400 invalid_client`
  // forever — never the 401 the recovery paths are gated on (see
  // device_revocation.dart), and the controller row is never re-provisioned.
  ref.invalidate(connectionDeviceRecordProvider);
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
