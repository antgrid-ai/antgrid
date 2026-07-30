import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/app_settings_service.dart' show defaultRelayUrlProvider;
import '../services/auth_service.dart' show CurrentUser;
import '../services/keychain_device_store.dart' show DeviceRecord;
import '../util/ab_log.dart';
import '../utils/platform_utils.dart';
import 'agent_transport.dart' show localAgentLauncherProvider;
import 'auth.dart' show currentUserProvider, licenseApiUrlProvider;
import 'device_provisioning.dart' show resolveDeviceRecord;

/// Eagerly warms the local bridge host at app launch so the always-on control
/// plane is live (machine phone-reachable) and the first project open is just an
/// attach + RPC. Desktop-only — mobile has no local host. `read()` once during
/// bootstrap (main.dart); it kicks an initial warm-up on a microtask and wires a
/// sign-in listener that respawns whenever the account device changes.
///
/// Best-effort and non-blocking: the warm-up never blocks startup and swallows
/// every failure (offline, not-signed-in, spawn error) — the legacy lazy path
/// still spawns the host on the first project open.
final localHostWarmupProvider = Provider<void>((ref) {
  if (isMobilePlatform) return;

  // OAuth client of the account device the LIVE warm host was spawned with, or
  // null when it came up machine-less. The host reads its credentials once,
  // from stdin, and never re-reads them, so this is the only record of what it
  // is actually running on — compared on sign-in to decide whether to respawn.
  String? spawnedClientId;
  var warmedOnce = false;
  // A respawn spans two awaits (keychain resolve, then teardown + spawn) and
  // `spawnedClientId` only updates at the end, so every sign-in event arriving
  // in that window would re-pass the mismatch check and kill the host again.
  // currentUserProvider is invalidated on resume as well as on sign-in, so
  // overlapping events are ordinary, not a corner case.
  var respawning = false;

  /// The account device to spawn with; null when signed out or the lookup
  /// fails, in which case the host comes up machine-less (local work still
  /// works, there is just no relay control plane).
  Future<DeviceRecord?> resolve() async {
    try {
      return await resolveDeviceRecord(ref, logTag: 'localHostWarmup');
    } catch (e) {
      AbLog.warn(
        'localHostWarmup',
        'device resolve failed (non-fatal)',
        fields: {'error': '$e'},
      );
      return null;
    }
  }

  Future<void> warm(DeviceRecord? device, {required bool forceRespawn}) async {
    try {
      final launcher = ref.read(localAgentLauncherProvider);
      await launcher.warmHost(
        device: device,
        licenseApiUrl: device != null ? ref.read(licenseApiUrlProvider) : null,
        relayUrl: device != null ? ref.read(defaultRelayUrlProvider) : null,
        forceRespawn: forceRespawn,
      );
      spawnedClientId = device?.clientId;
      warmedOnce = true;
    } catch (e) {
      AbLog.warn(
        'localHostWarmup',
        'warm-up failed (non-fatal)',
        fields: {'error': '$e'},
      );
    }
  }

  // Initial warm-up: microtask, so it yields on its first await and never blocks
  // the synchronous startup path (no first-frame gate needed).
  unawaited(() async {
    await warm(await resolve(), forceRespawn: false);
  }());

  // Sign-in: replace the warm host whenever the account device it is running on
  // is no longer the one we would spawn today — either it came up machine-less
  // (cold signed-out launch) or it holds a PREVIOUS device's credentials.
  // Signing out rotates the account device and the web deletes its OAuth
  // client, so the running host's cached pair is dead: its mint fails, the
  // machine never reaches the relay, and phones read it as permanently
  // offline. Keying on "came up machine-less" alone missed that second case,
  // which is the common one — a sign-out/sign-in cycle appeared to do nothing.
  //
  // Guarded on warmedOnce so an early sign-in event can't race a double spawn
  // before the initial warm resolves. (Known limitation: a force-respawn drops
  // any open local project's loopback transport — acceptable since a sign-in
  // normally has none open.)
  ref.listen<AsyncValue<CurrentUser?>>(currentUserProvider, (prev, next) {
    if (next.value == null || !warmedOnce || respawning) return;
    respawning = true;
    unawaited(() async {
      try {
        final device = await resolve();
        // Nothing better to spawn with, or already running on it — leave it be.
        if (device == null || device.clientId == spawnedClientId) return;
        await warm(device, forceRespawn: true);
      } finally {
        respawning = false;
      }
    }());
  });
});
