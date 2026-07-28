// The last hop of the blocked-connection chain: a `Blocked(reason)` the
// supervisor has already reached must reach the WORKSPACE, not just the
// supervisor's own status stream.
//
// The gap this covers shipped: a `session-takeover` arriving mid-use tore the
// E2E session down and blocked the ladder correctly, but the workspace read
// block reasons only off `agentTransportProvider`/`projectSessionProvider`
// errors — which can only be thrown while those providers are RESOLVING. A
// block that lands after they resolved left both in `AsyncData`, so the user
// got a dead session and no notice at all.
import 'package:antgrid/connection/relay_mechanisms.dart'
    show ConnectionBlockedException;
import 'package:antgrid/connection/supervisor_state.dart';
import 'package:antgrid/screens/workspace_shell.dart' show workspaceBlockingError;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a live block surfaces even when BOTH providers are healthy', () {
    // Exactly the takeover shape: the transport and the session resolved fine
    // and are still holding their last good value.
    final error = workspaceBlockingError(
      transportError: null,
      sessionError: null,
      liveStatus: const Blocked(BlockReason.sessionTakenOver),
    );

    expect(
      error,
      isA<ConnectionBlockedException>().having(
        (e) => e.reason,
        'reason',
        BlockReason.sessionTakenOver,
      ),
      reason:
          'a takeover that only ever reaches the supervisor is invisible to '
          'the user — the workspace keeps rendering a session that can no '
          'longer send anything',
    );
  });

  test('every reason that stays blocked until the user acts surfaces, not '
      'just the takeover', () {
    for (final reason in <BlockReason>[
      BlockReason.sessionTakenOver,
      BlockReason.superseded,
      BlockReason.deviceRevoked,
      BlockReason.licenseExpired,
    ]) {
      expect(
        workspaceBlockingError(
          transportError: null,
          sessionError: null,
          liveStatus: Blocked(reason),
        ),
        isA<ConnectionBlockedException>().having(
          (e) => e.reason,
          'reason',
          reason,
        ),
        reason: '$reason must not be a silently dead workspace',
      );
    }
  });

  test('the two SELF-clearing reasons never unmount an established '
      'workspace', () {
    // `notePresence(true)` clears both, and the routable rung reaches
    // agentOffline ~6s after a peer-offline. Taking the screen over would
    // rebuild the terminal, file tree and panes from scratch on every host
    // restart — a flap, for a condition that fixes itself.
    for (final reason in <BlockReason>[
      BlockReason.agentOffline,
      BlockReason.handshakeFailing,
    ]) {
      expect(
        workspaceBlockingError(
          transportError: null,
          sessionError: null,
          liveStatus: Blocked(reason),
        ),
        isNull,
        reason: '$reason clears itself — agentReachabilityProvider surfaces it',
      );
    }
  });

  test('a ladder that has not stopped never takes the workspace over', () {
    for (final status in <SupervisorStatus?>[
      null,
      const Climbing(ConnRung.socket),
      const Connected(),
      const Released(),
    ]) {
      expect(
        workspaceBlockingError(
          transportError: null,
          sessionError: null,
          liveStatus: status,
        ),
        isNull,
        reason: '$status is not a stopped ladder',
      );
    }
  });

  test('a thrown provider error outranks the block reason it reduced to', () {
    final thrown = StateError('agent spawn failed');

    expect(
      workspaceBlockingError(
        transportError: thrown,
        sessionError: null,
        liveStatus: const Blocked(BlockReason.handshakeFailing),
      ),
      same(thrown),
      reason:
          'the thrown exception carries the more specific cause than the '
          'reason the ladder reduced it to',
    );
    expect(
      workspaceBlockingError(
        transportError: null,
        sessionError: thrown,
        liveStatus: const Blocked(BlockReason.handshakeFailing),
      ),
      same(thrown),
    );
  });
}
