import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';

import '../launcher/local_agent_launcher.dart';
import '../models/ab_message.dart';
import '../models/ab_project.dart';
import '../models/session_target.dart';
import '../navigation/nav_controller.dart';
import '../services/app_settings_service.dart';
import '../util/device_id.dart';
import 'account_agents.dart';
import 'auth.dart';
import 'device_provisioning.dart';
import 'projects.dart';
import 'provider_retry.dart';
import 'providers.dart';
import 'recent_agents.dart';
import 'relay_connection.dart';
import 'relay_error_banner.dart';
import 'value_controller.dart';

final selectedTargetProvider =
    NotifierProvider<ValueController<SessionTarget?>, SessionTarget?>(
      () => ValueController(null),
    );

/// Projection used by code that only needs the transport registration id.
final selectedRegistrationIdProvider = Provider<String?>(
  (ref) => ref.watch(selectedTargetProvider)?.registrationId,
);

/// Selects a local project as the focused workspace. A re-tap on the
/// already-active project only re-invalidates the active transport when it is
/// currently in an error state (so the user can retry a failed connection) —
/// invalidating a healthy provider would dispose every service subscription
/// and snap the UI back to its loading state ("waiting for agent", empty
/// sessions list). For a switch to a different id the provider re-runs
/// naturally because it `ref.watch`es the selection.
void selectProject(WidgetRef ref, String projectId) {
  final priorId = ref.read(selectedRegistrationIdProvider);
  final target = LocalProject(projectId);
  if (ref.read(selectedTargetProvider) != target) {
    ref.read(selectedTargetProvider.notifier).set(target);
  }
  if (priorId == projectId) {
    if (ref.read(agentTransportProvider).hasError) {
      ref.invalidate(agentTransportProvider);
      ref.invalidate(agentTransportForProvider(projectId));
    }
    return;
  }
  // New focus: record a workspace history entry. recordProjectFocus owns the
  // guard that skips this while a cross-project session activation is in flight.
  recordProjectFocus(ref);
}

@visibleForTesting
void selectProjectInContainer(ProviderContainer c, String projectId) {
  c.read(selectedTargetProvider.notifier).set(LocalProject(projectId));
}

/// Set to `true` by the local-transport builder when the agent emits an
/// `auth_revoked` stderr event. The UI listens with `ref.listen` and shows a
/// snackbar, then resets this flag to `false` so repeat events re-notify.
final authRevokedBannerProvider = NotifierProvider<ValueController<bool>, bool>(
  () => ValueController(false),
);

/// Riverpod seam for [LocalAgentLauncher]. Override in tests to inject a fake
/// launcher without touching the file system or spawning a real host process.
final localAgentLauncherProvider = Provider<LocalAgentLauncher>(
  (ref) => LocalAgentLauncher(),
);

/// Per-projectId local transport family. Each projectId gets its own
/// `LocalTransport` so the App can hold N projects warm simultaneously.
///
/// Deliberately NOT `autoDispose`. Lifetime is governed by the registry's
/// eviction policy: `onEvict` invalidates this family entry, which fires
/// `ref.onDispose(transport.dispose)`. Letting `autoDispose` also tear down
/// the entry on transient listener detachments (a `.future` read from the
/// session factory, for example, has a temporary subscription that drops
/// the moment its parent build resumes after `await`) caused
/// disposed-mid-build races: by the time `openFolder` resolved, the element
/// was already gone and the just-built transport leaked. Single owner =
/// single lifetime authority = no race.
final agentTransportForProvider =
    FutureProvider.family<AgentTransport?, String>((ref, projectId) async {
      // Relay first: if this id corresponds to a paired remote agent, build
      // the relay stream transport and DO NOT watch the projects list (a watch there
      // would respawn the relay transport on every `projectsProvider.upsert`).
      final relay = await _buildRelayTransportFor(ref, projectId);
      if (relay != null) return relay;
      return _buildLocalTransportFor(ref, projectId);
      // retry: a failed connect/pair must reject `.future` so consumers
      // (controlPlaneClientForProvider, the refresh helpers, the error-screen
      // Retry) observe the error and can re-attempt — not stay pending behind
      // Riverpod 3's default retry loop. See provider_retry.dart.
    }, retry: noProviderRetry);

/// Resolves the pinned identity for the machine backing [projectId] (PairedAgent
/// → RecentAgent → cached InventoryAgent), opens (or reuses) that machine's
/// single [MachineSession] via `RelayConnectionManager.connectionFor(uuid)`,
/// then binds [projectId] to a stream over it: the control plane (stream "0")
/// for a bare machine id, or the project's data-plane stream for a compound
/// `<uuid>.<projectId>` — 0 RTT when the agent already advertised its streamId,
/// else `project:start` + await `stream-ready` (design §7.4). No new socket, no
/// per-project pair/handshake, so the v2 drill-in race is gone. Rekey lives
/// inside [MachineSession]; keys hot-swap under the live streams with no
/// invalidate here.
Future<AgentTransport?> _buildRelayTransportFor(
  Ref ref,
  String projectId,
) async {
  final mgr = ref.read(relayConnectionManagerProvider);
  final crypto = ref.read(cryptoServiceProvider);
  final recentStore = ref.read(recentAgentsStoreProvider);

  // Machine-level identity: a compound project id resolves via its base machine.
  final base = baseDeviceUuid(projectId);

  // Read the PairingService LAZILY, inside the resolved `flow` closures — and
  // keyed by the MACHINE uuid (pairing is machine-level in v3). Reading it up
  // front would materialize a stray RelayConnection for a LOCAL (dotless)
  // project whose `resolve` stays null; deferring means that never happens.
  pairing() => ref.read(pairingServiceForProvider(base));

  // Each resolved case yields the PairedAgent, the pinned handshake inputs
  // (bare phoneDeviceId + agent Ed25519 pubkey), and a flow that, given the
  // resolved DeviceIdentity, drives the machine socket to `paired` (grant).
  ({
    PairedAgent agent,
    String? phoneDeviceId,
    String agentEd25519PubB64,
    Future<void> Function(DeviceIdentity) flow,
  })?
  resolve;

  final agents = ref.read(pairedAgentProvider).value ?? const <PairedAgent>[];
  final paired = agents.firstWhereOrNull(
    (a) => baseDeviceUuid(a.agentDeviceId) == base,
  );
  final recent = recentStore.list().firstWhereOrNull(
    (r) => baseDeviceUuid(r.agentDeviceId) == base,
  );
  if (paired != null && recent != null) {
    resolve = (
      agent: paired,
      phoneDeviceId: recent.phoneDeviceId,
      agentEd25519PubB64: recent.agentEd25519Pubkey,
      flow: (id) => pairing().reconnect(recent, id),
    );
  } else if (recent != null) {
    resolve = (
      agent: PairedAgent(
        relayUrl: recent.relayUrl,
        agentDeviceId: recent.agentDeviceId,
        agentName: recent.agentLabel,
      ),
      phoneDeviceId: recent.phoneDeviceId,
      agentEd25519PubB64: recent.agentEd25519Pubkey,
      flow: (id) => pairing().reconnect(recent, id),
    );
  } else {
    final cachedInventory = ref.read(accountAgentsProvider).value;
    if (cachedInventory != null) {
      final localUuid = await ref.read(localDeviceUuidProvider.future);
      final inv = cachedInventory.firstWhereOrNull(
        (a) => a.deviceUuid == base && a.deviceUuid != localUuid,
      );
      if (inv != null) {
        resolve = (
          agent: PairedAgent(
            relayUrl: inv.relayUrl!, // autoOpen also throws on a null relayUrl
            agentDeviceId: inv.deviceUuid,
            agentName: inv.displayName,
          ),
          phoneDeviceId: null,
          agentEd25519PubB64: inv.ed25519Pub,
          flow: (id) => pairing().autoOpen(inv, id),
        );
      }
    }
  }

  if (resolve == null) return null;

  final identity = await ref.read(deviceIdentityProvider.future);
  // v3: the handshake/pair-request/hello all carry the BARE phone device id —
  // sub-deviceIds are gone (one socket per machine, one E2E session).
  final phoneDeviceId = resolve.phoneDeviceId ?? identity.deviceId;
  final phoneKp = await ref.read(phoneIdentityProvider).ensureKeypair(base);
  final r = resolve;

  final conn = mgr.connectionFor(base);
  // Rebind the machine's PairingService to THIS connection's live relay: a
  // reconnect (release + connectionFor) mints a fresh RelayService, and a
  // pairing service cached against the disposed one would send onto a closed
  // stream. The lazy `pairing()` read above picks up the rebuild.
  ref.invalidate(pairingServiceForProvider(base));

  final session = await conn.open(
    pairFlow: () => r.flow(identity),
    crypto: crypto,
    phoneDeviceId: phoneDeviceId,
    agentEd25519PubB64: r.agentEd25519PubB64,
    phoneEd25519Seed: phoneKp.privSeed,
  );

  final StreamTransport transport;
  if (projectId == base) {
    // Bare machine id → the control-plane stream.
    transport = session.streamFor(kControlStreamId);
  } else {
    final projId = baseProjectId(projectId);
    final known = session.streamIdForProject(projId);
    final streamId = known ??
        await session.bindProject(
          projId,
          createAbMessage('project:start', {'projectId': projId}),
        );
    transport = session.streamFor(streamId);
  }
  await transport.connect();
  // Detach only THIS stream on teardown; the machine connection's lifetime is
  // governed by the control-plane reaper / registry eviction, not here.
  ref.onDispose(() => unawaited(transport.dispose()));
  return transport;
}

/// Thin forwarder for the currently-selected project. Use this when a caller
/// doesn't already know the focus id; otherwise prefer
/// `agentTransportForProvider(id)` directly.
final agentTransportProvider = FutureProvider<AgentTransport?>((ref) async {
  final id = ref.watch(selectedRegistrationIdProvider);
  if (id == null) return null;
  return ref.watch(agentTransportForProvider(id).future);
  // retry: forwards the family entry's error verbatim (which itself does not
  // retry) so the error screen sees it immediately. See provider_retry.dart.
}, retry: noProviderRetry);

/// Builds a [LocalTransport] for the given [projectId]. Returns null when no
/// matching [AbProject] is registered. Wires up the project-scoped listeners
/// (auth status, relay errors, mobile-access notice) and disposes them when
/// the provider is torn down.
Future<AgentTransport?> _buildLocalTransportFor(
  Ref ref,
  String projectId,
) async {
  // Watch only the matching project's `folder` — a String, so `select`
  // value-equality dedupes identical content. Watching the whole list
  // would re-fire on every `upsert`: each call rebuilds `state` from a
  // fresh `_store.list()` (new `List` + new `AbProject` instances), so
  // even a `lastOpenedAt`-only churn (fired by every drawer tap) would
  // otherwise tear down and respawn this transport. Rapid taps then race
  // parallel `openFolder()` calls against the agent's single-owner socket
  // lock — symptom: `LocalTransport` reports "socket closed before ready"
  // because the new WS opens while the old one is still half-closed.
  // We also deliberately do not watch `hostDeviceUuid`: a relay-promotion
  // flow updates it via `upsert`, and a watcher there would dispose the
  // very transport that is driving the flow.
  final folder = ref.watch(
    projectsProvider.select((projects) {
      for (final p in projects) {
        if (p.projectId == projectId) return p.folder;
      }
      return null;
    }),
  );
  if (folder == null) {
    // Transient: the id was selected/built a beat before its AbProject landed
    // in projectsProvider. Returning null here would strand projectSessionProvider
    // ("No transport available") if it read-once — it now `watch`es this family,
    // so the folder-watch rebuild above re-runs the build once the project is
    // registered. Logged so a stray null build is visible in a repro.
    debugPrint(
      '[agentTransport] no folder registered yet for "$projectId" — '
      'returning null transport (will rebuild when the project is upserted)',
    );
    return null;
  }

  // Resolve machine credentials (keychain, else provision when signed in).
  // postSignInProvisioningProvider already runs this idempotently on sign-in, so
  // the keychain is normally non-null here — provisioning is a best-effort
  // secondary safety net. Machine-level credentials are carried unconditionally;
  // relay access is not gated on any per-project flag. Failure resolves to null
  // (open proceeds machine-less) — provisioning must never block the open.
  final device = await resolveDeviceRecord(ref, logTag: 'agentTransport');
  final launcher = ref.read(localAgentLauncherProvider);
  // The desktop always opens a LOCAL core and connects over loopback. The
  // device + endpoints are always carried into the host's machine bootstrap
  // whenever a device record exists, so the always-on control plane runs for
  // every local host — independent of any per-project flag. The desktop's own
  // transport stays loopback. (See design §"Data plane".)
  final result = await launcher.openProject(
    folder,
    device: device,
    licenseApiUrl: device != null ? ref.read(licenseApiUrlProvider) : null,
    relayUrl: device != null ? ref.read(defaultRelayUrlProvider) : null,
  );
  // NOTE: we deliberately do NOT terminate the host on app quit, even when this
  // process spawned it (result.owned). The host is a machine-level singleton
  // daemon: it persists across app runs (see HostController — attach via
  // host.json) so a subsequent launch reuses it and, crucially, a phone promoted
  // onto a core keeps its connection after the desktop UI closes. Killing it
  // here would drop every project's core and any paired phone. In dev, stale
  // hosts are reaped+respawned by HostController on the next launch.
  ref.onDispose(result.transport.dispose);

  // Listen for structured stderr events from the spawned agent process.
  // For orphan-attached agents result.events is an empty stream (no-op).
  final eventSub = result.events.listen((event) async {
    if (event.kind == 'auth_revoked') {
      debugPrint(
        '[agentTransport] auth_revoked event received — clearing keychain device record',
      );
      await ref.read(keychainDeviceStoreProvider).clear();
      ref.read(authRevokedBannerProvider.notifier).set(true);
    }
  });
  ref.onDispose(eventSub.cancel);

  // Parallel listener for agent:relayError → inline AbBanner. Unlike the
  // mobileEnabled-only sub below, this one fires for every project mode so
  // any runtime relay error surfaces above the workspace body instead of
  // being swallowed.
  final errSub = result.transport.messages.listen((m) {
    if (m.json['type'] != 'agent:relayError') return;
    final code = (m.json['code'] as String?) ?? 'UNKNOWN';
    final msg = (m.json['message'] as String?) ?? '';
    ref
        .read(relayErrorBannerProvider.notifier)
        .set(RelayErrorBanner(code, msg));
  });
  ref.onDispose(errSub.cancel);

  return result.transport;
}
