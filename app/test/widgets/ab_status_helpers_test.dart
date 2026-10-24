import 'dart:async';

import 'package:antgrid_relay_client/antgrid_relay_client.dart'
    show RpcException;
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/connection/supervisor_state.dart';
import 'package:antgrid/launcher/host_control_client.dart';
import 'package:antgrid/services/pending_reply.dart';
import 'package:antgrid/widgets/ab_status_helpers.dart';

void main() {
  test('BlockReason presentation is complete and owns interruption policy', () {
    for (final reason in BlockReason.values) {
      final presentation = blockReasonPresentation(reason);
      expect(presentation.statusLabel, isNotEmpty);
      expect(presentation.connectFailure, startsWith('Connect failed:'));
      expect(presentation.workspaceHeadline, isNotEmpty);
      expect(presentation.workspaceTip, isNotEmpty);
      expect(presentation.retryLabel, isNotEmpty);
    }
    expect(
      blockReasonPresentation(BlockReason.handshakeFailing).interruptsWorkspace,
      isFalse,
    );
  });

  group('sessionRefusalCopy', () {
    test('dedicated copy outranks the bridge\'s own wording', () {
      // The whole point of an arm in friendlyErrorCopy is that the bridge's
      // sentence names something the reader can't act on ("mobile access is
      // disabled on this machine" names neither the switch nor where it lives),
      // so a raw message must never win over one.
      final copy = sessionRefusalCopy(
        'NOT_ALLOWED',
        'mobile access is disabled on this machine',
        'Could not do that',
      );
      expect(copy, friendlyErrorCopy('NOT_ALLOWED'));
      expect(copy, isNot(contains('mobile access')));
    });

    test('a code with no arm keeps the bridge message verbatim', () {
      // WORKTREE_CREATE_FAILED spans causes as unlike as a locked checkout and a
      // repository with no commit; only the raw message says which.
      expect(
        sessionRefusalCopy(
          'WORKTREE_CREATE_FAILED',
          'fatal: invalid reference: nope',
          'Could not do that',
        ),
        'fatal: invalid reference: nope',
      );
    });

    test('neither a code nor a message falls back to the caller\'s copy', () {
      expect(
        sessionRefusalCopy(null, null, 'Could not do that'),
        'Could not do that',
      );
    });
  });

  group('caughtErrorCopy', () {
    const fallback = 'Try again.';

    test('shows what the machine said, never the exception class', () {
      final copy = caughtErrorCopy(
        RpcException('E_GIT', 'not a git repository'),
        fallback,
      );
      expect(copy, 'not a git repository');
      expect(
        caughtErrorCopy(RpcException('NOT_ALLOWED', 'raw'), fallback),
        friendlyErrorCopy('NOT_ALLOWED'),
      );
    });

    test('codes the app mints carry developer text, so they fall back', () {
      for (final error in <Object>[
        RpcException('BAD_RESPONSE', 'malformed git.branches response: {}'),
        RpcException('E_SEND_FAILED', 'request git.branches: SocketException'),
        HostControlException('TRANSPORT', 'control POST failed: x'),
        StateError('Bad state: no element'),
        const FormatException('Unexpected character'),
      ]) {
        expect(caughtErrorCopy(error, fallback), fallback, reason: '$error');
      }
    });

    test('a reply that never came says so', () {
      expect(
        caughtErrorCopy(TimeoutException('t'), fallback),
        "The machine didn't answer. Try again.",
      );
      expect(
        caughtErrorCopy(RpcException('E_TIMEOUT', 'request x timed out'), ''),
        "The machine didn't answer. Try again.",
      );
      expect(
        caughtErrorCopy(const SessionDownException(), fallback),
        const SessionDownException().toString(),
      );
    });
  });
}
