import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';

import '../analytics/events.dart';
import '../connection/connection_supervisor.dart';
import '../connection/relay_mechanisms.dart';
import '../launcher/local_agent_launcher.dart';
import '../models/ab_message.dart';
import '../models/ab_project.dart';
import '../models/session_target.dart';
import '../navigation/nav_controller.dart';
import '../services/account_agents_api.dart';
import '../services/app_settings_service.dart';
import '../services/keychain_device_store.dart';
import '../services/license_token_minter.dart';
import '../storage/recent_agents_store.dart';
import '../util/ab_log.dart';
import '../util/device_id.dart';
import 'account_agents.dart';
import 'agent_coordinates.dart';
import 'analytics.dart';
import 'auth.dart';
import 'connection_identity.dart';
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
final agentTransportForProvider = FutureProvider.family<AgentTransport?, String>((
  ref,
  projectId,
) async {
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

/// Resolves the coordinates for the machine backing [projectId] (RecentAgent →
/// cached InventoryAgent, freshness-first), opens (or reuses) that machine's
/// single [MachineSession] via `RelayConnectionManager.connectionFor(uuid)`,
/// then binds [projectId] to a stream over it: the control plane (stream "0")
/// for a bare machine id, or the project's data-plane stream for a compound
/// `<uuid>.<projectId>` — 0 RTT when the agent already advertised its streamId,
/// else `project:start` + await `stream-ready` (design §7.4). No new socket, no
/// per-project handshake, so the v2 drill-in race is gone. Rekey lives inside
/// [MachineSession]; keys hot-swap under the live streams with no invalidate
/// here.
///
/// Admission is ACCOUNT trust: there is no pair-request and no relay grant. The
/// app connects and signs the E2E transcript as its own `kind:"app"`
/// [DeviceRecord], which the agent recognises from the account peers inventory.
Future<AgentTransport?> _buildRelayTransportFor(
  Ref ref,
  String projectId,
) async {
  final mgr = ref.read(relayConnectionManagerProvider);
  final crypto = ref.read(cryptoServiceProvider);
  final recentStore = ref.read(recentAgentsStoreProvider);

  // Machine-level identity: a compound project id resolves via its base machine.
  final base = baseDeviceUuid(projectId);

  // The resolved machine: its dial endpoint and the Ed25519 key the handshake
  // pins the agent against. Null for a LOCAL (dotless, unknown) project, which
  // must fall through WITHOUT materializing a stray RelayConnection.
  ({PairedAgent agent, String agentEd25519PubB64})? resolve;

  // Set only when the machine was resolved from the account inventory with no
  // cached row behind it — the case that owes the reconnect list a write.
  InventoryAgent? uncachedInventoryHit;

  final inventory = ref.read(accountAgentsProvider).value;
  final agents = ref.read(pairedAgentProvider).value ?? const <PairedAgent>[];
  final paired = agents.firstWhereOrNull(
    (a) => baseDeviceUuid(a.agentDeviceId) == base,
  );
  final recent = recentStore.list().firstWhereOrNull(
    (r) => baseDeviceUuid(r.agentDeviceId) == base,
  );
  // Freshness-first coordinates: prefer /account/agents (the relay-independent
  // TLS anchor) over the values pinned on `recent`, so a host that moved relay
  // or re-provisioned its Ed25519 identity is dialed/verified against the live
  // inventory instead of a dead pin. `recent` guarantees a non-null fallback.
  final coords = resolveAgentCoordinates(
    base: base,
    inventory: inventory,
    cached: recent,
  );
  if (paired != null && recent != null && coords != null) {
    resolve = (agent: paired, agentEd25519PubB64: coords.ed25519Pub);
  } else if (recent != null && coords != null) {
    resolve = (
      agent: PairedAgent(
        relayUrl: coords.relayUrl ?? recent.relayUrl,
        agentDeviceId: recent.agentDeviceId,
        agentName: coords.label,
      ),
      agentEd25519PubB64: coords.ed25519Pub,
    );
  } else {
    if (inventory != null) {
      final localUuid = await ref.read(localDeviceUuidProvider.future);
      final inv = inventory.firstWhereOrNull(
        (a) => a.deviceUuid == base && a.deviceUuid != localUuid,
      );
      // A host with no relayUrl has not enabled mobile access — nothing to dial.
      if (inv != null && inv.relayUrl != null) {
        uncachedInventoryHit = inv;
        resolve = (
          agent: PairedAgent(
            relayUrl: inv.relayUrl!,
            agentDeviceId: inv.deviceUuid,
            agentName: inv.displayName,
          ),
          agentEd25519PubB64: inv.ed25519Pub,
        );
      }
    }
  }

  if (resolve == null) return null;

  // The ONE remote-control identity: the app's own `kind:"app"` DeviceRecord.
  // It authenticates the relay hello AND signs the E2E transcript, so the agent
  // resolves us from the account peers inventory.
  final record = await ref.read(connectionDeviceRecordProvider.future);
  // Scoped to THIS machine so each of the app's sockets holds its own relay
  // slot: the relay arbitrates per `hello.deviceId` and supersedes an equal
  // epoch, so sharing one slot across machines lets the second machine wanted
  // kill the first (see [relaySlotId]).
  final identity = connectionIdentityFor(record, machineDeviceId: base);
  // The E2E transcript stays on the BARE device id even though the hello is
  // scoped: it is what the agent resolves us by in the account peers inventory,
  // so it must name the account device, not the transport address.
  final phoneDeviceId = record.deviceUuid;
  final phoneEd25519Seed = base64Decode(record.ed25519Priv);
  final r = resolve;

  final invHit = uncachedInventoryHit;
  if (invHit != null) {
    // The activation funnel for the no-QR path. `uncachedInventoryHit` is set
    // only when no cached row backed the machine, so this fires once per
    // newly-reached machine rather than on every warm rebuild. The `reconnect`
    // variant this event used to carry has no successor: reconnecting is the
    // supervisor's automatic job now, not a user activation.
    ref
        .read(analyticsServiceProvider)
        ?.track(AnalyticsEvents.agentPaired, props: {'method': 'same_account'});

    // The reconnect list must also accumulate machines reached from the
    // inventory: it is what renders them in the drawer while `/account/agents`
    // is unreachable, and what lets a cold start resolve a persisted focus.
    // Fire-and-forget — a prefs write is never allowed to delay or fail a dial.
    final now = DateTime.now();
    unawaited(
      recentStore
          .upsert(
            RecentAgent(
              agentDeviceId: invHit.deviceUuid,
              agentLabel: invHit.displayName,
              agentEd25519Pubkey: invHit.ed25519Pub,
              relayUrl: invHit.relayUrl!,
              pairedAt: now,
              lastConnectedAt: now,
              hostMachineName: invHit.machineName,
            ),
          )
          .catchError((Object e) {
            AbLog.warn(
              'AgentTransport',
              'recent-agent upsert failed',
              fields: {'error': '$e'},
            );
          }),
    );
  }

  final conn = mgr.connectionFor(base);

  final epoch = await ref.read(relayEpochProvider.future);
  // Resolved once because it holds CREDENTIALS, not a token — every dial still
  // mints. Failing to resolve one is deliberately not fatal: the dial then
  // presents an empty token and the relay's license verdict is what tells the
  // user to sign in, which is the same feedback the pre-supervisor flow gave.
  LicenseTokenMinter? minter;
  try {
    minter = await ref.read(connectionTokenMinterProvider.future);
  } catch (e) {
    AbLog.warn(
      'AgentTransport',
      'no license-token minter',
      fields: {'machine': base, 'error': '$e'},
    );
  }
  final tokenMinter = minter;
  // Freshness-first, same polarity as the pubkey: the inventory-resolved
  // endpoint wins over the one pinned on the stored PairedAgent, which is
  // exactly the value that goes stale when a host moves relay.
  final relayUrl = coords?.relayUrl ?? r.agent.relayUrl;
  // Read through the container-lifetime resolvers, never through THIS
  // element's `ref`: the connection outlives the element (see
  // [ConnectionCoordsResolver]).
  final coordsResolver = ref.read(connectionCoordsResolverProvider);
  final minterResolver = ref.read(connectionMinterResolverProvider);
  var resolveCalls = 0;

  conn.ensureStarted(
    mechanisms: RelayMechanisms(
      relay: conn.relay,
      crypto: crypto,
      machineDeviceId: base,
      identity: identity,
      phoneDeviceId: phoneDeviceId,
      phoneEd25519Seed: phoneEd25519Seed,
      epoch: epoch,
      resolveCoords: () {
        // Re-read on every call, never a closure over the build-time answer:
        // the supervisor re-runs this step precisely when the last answer has
        // stopped being dialable — a host that moved relay or re-provisioned
        // its Ed25519 identity — and replaying the same values would make the
        // re-resolve pointless. The first call reuses whatever the inventory
        // already holds; later ones refresh it, because they only happen after
        // the socket rung has failed against the previous answer.
        final refresh = resolveCalls++ > 0;
        return coordsResolver.resolve(
          base: base,
          refreshInventory: refresh,
          fallback: ConnCoords(
            relayUrl: relayUrl,
            agentEd25519PubB64: r.agentEd25519PubB64,
          ),
        );
      },
      mintToken: () async {
        // Through the container-lifetime resolver, never this element's `ref`,
        // for the same reason as the coords step — see
        // [ConnectionMinterResolver].
        final live = await minterResolver.resolve(tokenMinter);
        // Fresh per attempt, never a cached token: one minted before a long
        // backoff is already expired by the time its dial runs.
        return live == null ? '' : live.mint();
      },
    ),
  );
  // A changed agent pin makes the mechanisms swap the whole MachineSession,
  // which disposes the StreamTransport built below. Nothing else rebuilds this
  // entry — Retry only invalidates the FOCUSED id — so without this every other
  // warm project on this machine would keep serving a dead transport. Wired
  // before the session is awaited so a swap mid-handshake is not missed.
  final replacements = conn.sessionReplacements.listen((_) {
    if (ref.mounted) ref.invalidateSelf();
  });
  ref.onDispose(replacements.cancel);

  final session = await conn.awaitSession();

  final StreamTransport transport;
  if (projectId == base) {
    // Bare machine id → the control-plane stream.
    transport = session.streamFor(kControlStreamId);
  } else {
    final projId = baseProjectId(projectId);
    final known = session.streamIdForProject(projId);
    final streamId =
        known ??
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

/// Hard deadline on the inventory refresh inside a coords step. The step runs
/// under the supervisor's single-flight guard, so anything it waits out is
/// time the whole ladder cannot use to react — and the cached pin below is a
/// perfectly good answer for a machine that has not moved.
const Duration _kCoordsInventoryTimeout = Duration(seconds: 8);

/// Answers "where does this machine live" for a connection ladder that is
/// already running, from the authoritative sources: the account inventory
/// (`/account/agents`, the relay-independent TLS anchor) with the stored
/// [RecentAgent] pin as the offline fallback.
///
/// Deliberately owned by [connectionCoordsResolverProvider] — a
/// container-lifetime provider — and NOT by the transport element that built
/// the mechanisms. `retryAgentConnection()` invalidates that element WITHOUT
/// releasing the connection, and `RelayConnection.ensureStarted` discards the
/// rebuild's mechanisms, so the live coords closure outlives the element that
/// created it. Reading through that element's `Ref` therefore answers every
/// resolution after the user's first Retry from a disposed `Ref` — i.e. the
/// build-time endpoint, forever — which is precisely the dead-address state
/// the re-resolve exists to escape.
class ConnectionCoordsResolver {
  ConnectionCoordsResolver(this._ref);

  final Ref _ref;

  /// One resolution. Bounded by construction — it reads, never dials and never
  /// provisions, and falls back to [fallback] rather than failing the rung when
  /// the account service is unreachable.
  Future<ConnCoords> resolve({
    required String base,
    required bool refreshInventory,
    required ConnCoords fallback,
  }) async {
    // Only true once the whole container is gone (app teardown); there is no
    // longer anything to read from.
    if (!_ref.mounted) return fallback;
    List<InventoryAgent>? inventory;
    if (refreshInventory) {
      try {
        _ref.invalidate(accountAgentsProvider);
        inventory = await _ref
            .read(accountAgentsProvider.future)
            .timeout(_kCoordsInventoryTimeout);
      } catch (_) {
        // Unreachable account service is not a coords failure: the cached pin
        // can still reach a machine that never moved, and failing here would
        // stall a connection that has everything it needs.
        inventory = _ref.mounted
            ? _ref.read(accountAgentsProvider).value
            : null;
      }
    } else {
      // Whatever the inventory already holds — the first resolve must not put a
      // network round-trip in front of the very first dial.
      inventory = _ref.read(accountAgentsProvider).value;
    }
    if (!_ref.mounted) return fallback;
    final cached = _ref
        .read(recentAgentsStoreProvider)
        .list()
        .firstWhereOrNull((r) => baseDeviceUuid(r.agentDeviceId) == base);
    final coords = resolveAgentCoordinates(
      base: base,
      inventory: inventory,
      cached: cached,
    );
    return ConnCoords(
      relayUrl: coords?.relayUrl ?? cached?.relayUrl ?? fallback.relayUrl,
      agentEd25519PubB64: coords?.ed25519Pub ?? fallback.agentEd25519PubB64,
    );
  }
}

final connectionCoordsResolverProvider = Provider<ConnectionCoordsResolver>(
  (ref) => ConnectionCoordsResolver(ref),
);

/// Answers "which credentials does this connection mint with" for a ladder that
/// is already running.
///
/// Container-lifetime for exactly the reason spelled out on
/// [ConnectionCoordsResolver]: the live mechanisms outlive the transport
/// element that built them, so a read through that element's `Ref` stops
/// resolving the moment `retryAgentConnection()` invalidates it. Every later
/// mint would then fall back to the minter captured at build time — and a
/// device re-provisioned since (fresh clientId/secret after a device-cap
/// remediation or a sign-out/sign-in that left this machine warm) keeps minting
/// on retired credentials, which the web answers with 401 `invalid_client`.
/// That surfaces as a permanent `Blocked(deviceRevoked)` no Retry can clear.
class ConnectionMinterResolver {
  ConnectionMinterResolver(this._ref);

  final Ref _ref;

  /// The minter to dial with, or [fallback] when the container is gone or the
  /// provider cannot produce one.
  Future<LicenseTokenMinter?> resolve(LicenseTokenMinter? fallback) async {
    // Only true once the whole container is gone (app teardown).
    if (!_ref.mounted) return fallback;
    try {
      return await _ref.read(connectionTokenMinterProvider.future) ?? fallback;
    } catch (_) {
      // Already logged at build time; a dial with no token gets the relay's
      // license verdict, which is the actionable message.
      return fallback;
    }
  }
}

final connectionMinterResolverProvider = Provider<ConnectionMinterResolver>(
  (ref) => ConnectionMinterResolver(ref),
);

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
    AbLog.info(
      'AgentTransport',
      'no folder registered yet — returning null transport (will rebuild '
          'when the project is upserted)',
      fields: {'projectId': projectId},
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
      AbLog.info(
        'AgentTransport',
        'auth_revoked event received — clearing keychain device record',
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
