import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../launcher/host_controller.dart';
import '../project/project_session_registry.dart';
import '../util/ab_log.dart';
import '../utils/platform_utils.dart';
import 'agent_transport.dart' show agentTransportForProvider;
import 'control_plane.dart' show hostControllerProvider;
import 'remote_access.dart' show hostControlClientProvider;

/// Supervision state of the local bridge host (see [HostController.statusStream]).
/// The UI's single source of truth for "is this machine's own bridge alive" —
/// remote machines are covered by `supervisorStatusProvider` instead.
final hostStatusProvider = StreamProvider<HostStatus>((ref) {
  return ref.watch(hostControllerProvider).statusStream;
});

/// Re-binds everything wired to the old host process after it comes back from a
/// death we did not ask for: every open LOCAL project, and the loopback control
/// client. The respawned host has none of the old cores open, its sockets died
/// with the process, and it binds a fresh port under a fresh token — so without
/// this the supervised restart would bring the bridge back under a workspace
/// still wired to dead transports.
///
/// Desktop-only, and must stay listened for the app's whole life — `listen` it
/// from bootstrap alongside `localHostWarmupProvider`.
final hostRestartRebindProvider = Provider<void>((ref) {
  if (isMobilePlatform) return;

  // Generation of the host the open sessions were last bound against. A
  // different generation on the next `up` means the process underneath them
  // was REPLACED — crash respawn, wedged-host reap, forced respawn — no
  // matter which intermediate phases happened to be observable (the
  // wedged-reap path publishes only `starting → up`, and an attached host
  // killed externally has no exit handle at all).
  int? boundGeneration;

  ref.listen<AsyncValue<HostStatus>>(hostStatusProvider, (_, next) {
    final s = next.value;
    if (s == null || s.phase != HostPhase.up) return;
    final prev = boundGeneration;
    boundGeneration = s.generation;
    // First `up` of this app run: nothing was bound yet, nothing to re-bind.
    if (prev == null || prev == s.generation) return;

    // The loopback control client is bound to the DEAD process's port AND
    // token, and nothing else ever re-resolves it — so every remote-access
    // surface (the machine switch, the device roster) posts into a closed
    // socket for the rest of the app's life. Invalidated ABOVE the early
    // return below on purpose: it is stale whether or not a project is open.
    ref.invalidate(hostControlClientProvider);

    final open = ref
        .read(projectSessionRegistryProvider.notifier)
        .localOpenProjects();
    if (open.isEmpty) return;
    AbLog.info(
      'HostRestartRebind',
      'host back up — re-opening local projects against the fresh host',
      fields: {'count': open.length},
    );
    for (final id in open) {
      // Same pair the eviction path invalidates: session first, then the
      // transport family entry that owns the dead loopback socket.
      ref.invalidate(projectSessionProvider(id));
      ref.invalidate(agentTransportForProvider(id));
    }
  });
});
