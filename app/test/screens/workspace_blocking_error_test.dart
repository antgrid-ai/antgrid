import 'package:antgrid/connection/peer_connection.dart'
    show ConnectionBlockedException;
import 'package:antgrid/connection/supervisor_state.dart';
import 'package:antgrid/screens/workspace_shell.dart'
    show workspaceBlockingError;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a live action-required block surfaces over a healthy workspace', () {
    for (final reason in <BlockReason>[
      BlockReason.sessionTakenOver,
      BlockReason.deviceRevoked,
      BlockReason.licenseExpired,
      BlockReason.peerRejected,
    ]) {
      expect(
        workspaceBlockingError(
          transportError: null,
          sessionError: null,
          liveStatus: Blocked(reason),
        ),
        isA<ConnectionBlockedException>().having(
          (error) => error.reason,
          'reason',
          reason,
        ),
      );
    }
  });

  test('a transient handshake block preserves an established workspace', () {
    expect(
      workspaceBlockingError(
        transportError: null,
        sessionError: null,
        liveStatus: const Blocked(BlockReason.handshakeFailing),
      ),
      isNull,
    );
  });

  test('a climbing native payload ladder never takes the workspace over', () {
    for (final status in <SupervisorStatus?>[
      null,
      const Climbing(ConnRung.payload),
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
    );
  });
}
