import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:antgrid/services/keychain_device_store.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';

import 'host_control_client.dart';
import 'host_controller.dart';
import 'project_id.dart';
import '../util/ab_log.dart';

// ---------------------------------------------------------------------------
// BootstrapPayload
// ---------------------------------------------------------------------------

/// Serialized as a single JSON line written to the host's stdin on spawn.
/// Mirror of `bridge/src/auth/credentials.ts` `BootstrapPayloadSchema`:
/// `{ machine?, firstProject?: { projectId, projectPath, mode }, ownerPid? }`.
///
/// The desktop driver always opens the first project as `mode: "local"`; the
/// `machine` block is included whenever a [DeviceRecord] exists so the host can
/// later open a remote core over the control plane without respawning.
/// Use [BootstrapPayload.machineOnly] to spawn a project-less host (omits `firstProject`).
class BootstrapPayload {
  BootstrapPayload({
    required String this.projectId,
    required String this.projectPath,
    this.mode = 'local',
    this.device,
    this.licenseApiUrl,
    this.relayUrl,
    this.ownerPid,
  });

  /// A project-less spawn: the host boots its control plane and waits for
  /// project:open RPCs. Used by the eager warm-up at app launch (no project is
  /// selected yet). [device]/[licenseApiUrl]/[relayUrl] bring up the remote
  /// control plane when present; absent → a warm local host only.
  BootstrapPayload.machineOnly({
    this.device,
    this.licenseApiUrl,
    this.relayUrl,
    this.ownerPid,
  }) : projectId = null,
       projectPath = null,
       mode = 'local';

  final String? projectId;
  final String? projectPath;

  /// Pid of this app process. The host runs an owner-watchdog that self-exits
  /// when this pid vanishes — the backstop for app exits that never reach the
  /// `didRequestAppExit` teardown (force-kill, crash, or a window close under
  /// `flutter run --machine`). Null leaves the host untethered (CLI spawns).
  final int? ownerPid;

  /// First-core mode. The app only ever spawns `local`; the field stays a
  /// parameter because the bridge's `BootstrapPayloadSchema` also accepts
  /// `remote`, which additionally requires a `machine` block.
  final String mode;
  final DeviceRecord? device;
  final String? licenseApiUrl;
  final String? relayUrl;

  String toJsonLine() {
    final j = <String, dynamic>{
      if (projectId != null && projectPath != null)
        'firstProject': {
          'projectId': projectId,
          'projectPath': projectPath,
          'mode': mode,
        },
      if (ownerPid != null) 'ownerPid': ownerPid,
    };
    final d = device;
    if (d != null && licenseApiUrl != null && relayUrl != null) {
      j['machine'] = {
        'relayUrl': relayUrl,
        'licenseApiUrl': licenseApiUrl,
        'auth': {
          'clientId': d.clientId,
          'clientSecret': d.clientSecret,
          'ed25519Pub': d.ed25519Pub,
          'ed25519Priv': d.ed25519Priv,
          'x25519Pub': d.x25519Pub,
          'x25519Priv': d.x25519Priv,
          'deviceUuid': d.deviceUuid,
        },
      };
    }
    return '${jsonEncode(j)}\n';
  }
}

/// A structured event parsed from the agent's stderr JSON lines.
class AgentEvent {
  AgentEvent(this.kind, this.payload);
  final String kind; // e.g. 'auth_revoked'
  final Map<String, dynamic> payload;
}

class LaunchResult {
  final LocalTransport transport;
  final int agentPid;

  /// `true` when this app process spawned the agent; `false` when we attached
  /// to an orphan agent left over from a prior App run.
  final bool owned;
  final String projectId;

  /// Structured events emitted by the agent via stderr JSON lines.
  /// Closed when the agent process exits.
  /// Empty stream for orphan-attached agents (no process to listen to).
  final Stream<AgentEvent> events;

  LaunchResult({
    required this.transport,
    required this.agentPid,
    required this.owned,
    required this.projectId,
    Stream<AgentEvent>? events,
  }) : events = events ?? const Stream.empty();
}

void _log(String msg) {
  AbLog.info('LocalAgentLauncher', msg);
}

class LocalAgentLauncher {
  LocalAgentLauncher({HostController? host}) : _host = host ?? sharedHost;

  /// One host per app process. Shared across launcher instances so every
  /// project opens against the same host (and ensureHost single-flights).
  static final HostController sharedHost = HostController();
  final HostController _host;

  static final Map<String, Future<LaunchResult>> _inFlight = {};

  /// Resolve-or-open [folder] as a LOCAL core on the singleton host and return
  /// a connected loopback transport. [device]/[licenseApiUrl]/[relayUrl] are
  /// carried into the host's machine bootstrap (so a later remote open works);
  /// they do NOT change the desktop's loopback data plane.
  Future<LaunchResult> openProject(
    String folder, {
    DeviceRecord? device,
    String? licenseApiUrl,
    String? relayUrl,
  }) async {
    // A host computes repository identity because only it can correctly fold a
    // linked worktree into its primary checkout. Older hosts predate this
    // loopback verb, where the old path hash remains safe for shared sessions.
    _host.bootstrapBuilder ??= () => BootstrapPayload.machineOnly(
      device: device,
      licenseApiUrl: licenseApiUrl,
      relayUrl: relayUrl,
      ownerPid: pid,
    );
    final host = await _host.ensureHost();
    final resolveClient = HostControlClient(
      port: host.controlPort,
      token: host.token,
    );
    String projectId;
    String repoPath;
    try {
      final resolved = await resolveClient.projectResolve(folder);
      projectId = resolved.projectId;
      repoPath = resolved.repoPath;
    } on HostControlException catch (e) {
      if (e.code != 'BAD_REQUEST' && e.code != 'UNKNOWN_VERB') rethrow;
      projectId = await computeProjectId(folder);
      repoPath = folder;
    } finally {
      resolveClient.close();
    }
    final existing = _inFlight[projectId];
    if (existing != null) {
      _log('openProject: projectId=$projectId — coalescing with in-flight');
      return existing;
    }
    final fut = _openInner(
      repoPath,
      projectId,
      device,
      licenseApiUrl,
      relayUrl,
    );
    _inFlight[projectId] = fut;
    try {
      return await fut;
    } finally {
      // remove() returns the (already-awaited) cached Future; discarding it
      // here is intentional, not a dropped await.
      // ignore: unawaited_futures
      _inFlight.remove(projectId);
    }
  }

  /// Eagerly bring up the singleton host with a project-less (machine-only)
  /// bootstrap, so the control plane is live at app launch and the first
  /// `openProject` only has to attach + send a `project:open` RPC. Best-effort:
  /// callers run this fire-and-forget and swallow failures.
  ///
  /// [forceRespawn] tears down the host THIS app owns before re-spawning — used
  /// when a machine-less warm host must be replaced with a device-bearing one
  /// after sign-in (so `startRemoteControlPlane` runs). Unlike `openProject`'s
  /// `??=`, this ASSIGNS the builder so the new (device-bearing) bootstrap wins.
  ///
  /// Edge: if a project is opened after a machine-less warm-up but before the
  /// sign-in respawn fires, `openProject`'s `??=` keeps this machine-less builder,
  /// so a fresh spawn there would lack the device block — the sign-in respawn is
  /// what reconciles it. The common path (signed in at launch) carries the device
  /// from the first warm-up, so this never arises there.
  Future<void> warmHost({
    DeviceRecord? device,
    String? licenseApiUrl,
    String? relayUrl,
    bool forceRespawn = false,
  }) async {
    _host.bootstrapBuilder = () => BootstrapPayload.machineOnly(
      device: device,
      licenseApiUrl: licenseApiUrl,
      relayUrl: relayUrl,
      ownerPid: pid,
    );
    if (forceRespawn) {
      // Let any concurrent spawn settle first so the teardown+respawn below
      // doesn't kill a half-born host and then get joined to that same dying
      // spawn by ensureHost's single-flight (it would inherit the OLD,
      // machine-less bootstrap instead of this device-bearing one).
      await _host.drainInFlight();
      await _host.shutdownOwnedHost();
      _host.invalidate();
    }
    await _host.ensureHost();
  }

  Future<LaunchResult> _openInner(
    String folder,
    String projectId,
    DeviceRecord? device,
    String? licenseApiUrl,
    String? relayUrl,
  ) async {
    // The host's stdin bootstrap, consumed only if ensureHost must spawn fresh.
    // `??=`: the FIRST project to open wins, so whichever device record was
    // resolvable then is what the host runs on for its whole life — it reads
    // stdin once, and no app path pushes fresh credentials into a live host.
    // A stale (or machine-less) block is reconciled only by the sign-in
    // force-respawn in `local_host_warmup.dart`.
    _host.bootstrapBuilder ??= () => BootstrapPayload(
      projectId: projectId,
      projectPath: folder,
      device: device,
      licenseApiUrl: licenseApiUrl,
      relayUrl: relayUrl,
      // dart:io `pid` — this app process; the host watches it and self-exits
      // when we die, so it can't outlive the app on any exit path.
      ownerPid: pid,
    );

    final host = await _host.ensureHost();
    final client = HostControlClient(port: host.controlPort, token: host.token);
    try {
      final res = await client.projectOpen(
        projectId: projectId,
        projectPath: folder,
      );
      final connect = res.connect;
      if (connect == null) {
        throw StateError(
          'project:open returned no connect info for local project $projectId',
        );
      }
      final t = LocalTransport(
        port: connect.port,
        token: connect.token,
        appPid: pid,
      );
      await t.connect();
      _log('opened project $projectId (port ${connect.port})');
      return LaunchResult(
        transport: t,
        agentPid: host.pid,
        owned: _host.ownedHostPid != null,
        projectId: projectId,
        events: _host.hostEvents,
      );
    } catch (_) {
      // Any failure against the cached host — control error, data-plane
      // `t.connect()` failure, or malformed response — means it can't be
      // trusted. Drop the cache so the next openProject re-probes instead of
      // reusing a dead endpoint within the 3s TTL.
      _host.invalidate();
      rethrow;
    } finally {
      client.close();
    }
  }
}
