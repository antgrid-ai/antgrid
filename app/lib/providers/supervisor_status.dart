import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../connection/supervisor_state.dart';
import 'relay_connection.dart';

/// Read-only [SupervisorStatus] for [bareDeviceUuid]'s machine socket — `peek`
/// only, NEVER dials. Null when nothing has been dialed for this machine yet.
///
/// This is the ONE source of truth the workspace UI reads: every
/// connection-health surface (reachability, status chips, boot-screen phases,
/// blocked-state banners) reads the supervisor instead of the raw relay
/// `RelayConnectionState`, which stopped being able to say "the agent showed
/// up" once the pairing rung was deleted.
///
/// Subscribes to [RelayConnection.statusStream], never to `supervisor` — the
/// supervisor is built several awaits after the connection appears, so a
/// one-shot peek at it would dead-end on the normal cold-launch ordering.
final supervisorStatusProvider = StreamProvider.autoDispose
    .family<SupervisorStatus?, String>((ref, bareDeviceUuid) async* {
      ref.watch(relayConnectionChangesProvider);
      final conn = ref
          .read(relayConnectionManagerProvider)
          .peek(bareDeviceUuid);
      if (conn == null) {
        yield null;
        return;
      }
      yield* conn.statusStream;
    });
