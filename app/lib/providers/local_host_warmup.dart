import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/app_settings_service.dart' show defaultRelayUrlProvider;
import '../services/auth_service.dart' show CurrentUser;
import '../util/ab_log.dart';
import '../utils/platform_utils.dart';
import 'agent_transport.dart' show localAgentLauncherProvider;
import 'auth.dart' show currentUserProvider, licenseApiUrlProvider;
import 'device_provisioning.dart' show resolveDeviceRecord;

/// Eagerly warms the local bridge host at app launch so the always-on control
/// plane is live (machine phone-reachable) and the first project open is just an
/// attach + RPC. Desktop-only — mobile has no local host. `read()` once during
/// bootstrap (main.dart); it kicks an initial warm-up on a microtask and wires a
/// sign-in listener for the cold (signed-out launch → sign-in) respawn.
///
/// Best-effort and non-blocking: the warm-up never blocks startup and swallows
/// every failure (offline, not-signed-in, spawn error) — the legacy lazy path
/// still spawns the host on the first project open.
final localHostWarmupProvider = Provider<void>((ref) {
  if (isMobilePlatform) return;

  // Did the live warm host come up WITH a device block (relay control plane up)?
  // Cold signed-out launch comes up machine-less; flip true once we warm with a
  // device, so the sign-in listener respawns at most once.
  var spawnedWithDevice = false;
  var warmedOnce = false;

  Future<void> warm({required bool forceRespawn}) async {
    try {
      final device = await resolveDeviceRecord(ref, logTag: 'localHostWarmup');
      final launcher = ref.read(localAgentLauncherProvider);
      await launcher.warmHost(
        device: device,
        licenseApiUrl: device != null ? ref.read(licenseApiUrlProvider) : null,
        relayUrl: device != null ? ref.read(defaultRelayUrlProvider) : null,
        forceRespawn: forceRespawn,
      );
      spawnedWithDevice = device != null;
      warmedOnce = true;
    } catch (e) {
      AbLog.warn('localHostWarmup', 'warm-up failed (non-fatal)', fields: {'error': '$e'});
    }
  }

  // Initial warm-up: microtask, so it yields on its first await and never blocks
  // the synchronous startup path (no first-frame gate needed).
  unawaited(warm(forceRespawn: false));

  // Cold sign-in: if we launched machine-less, replace the warm host with a
  // device-bearing one so startRemoteControlPlane runs. Guarded on warmedOnce so
  // an early sign-in event can't race a double spawn before the initial warm
  // resolves. (Known limitation: a force-respawn drops any open local project's
  // loopback transport — acceptable since cold sign-in normally has none open.)
  ref.listen<AsyncValue<CurrentUser?>>(currentUserProvider, (prev, next) {
    if (next.value != null && warmedOnce && !spawnedWithDevice) {
      unawaited(warm(forceRespawn: true));
    }
  });
});
