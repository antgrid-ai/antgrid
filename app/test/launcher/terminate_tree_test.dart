import 'dart:io';

import 'package:antgrid/launcher/discovery.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records every signal the escalation sends, in order, as `<pid>:<signal>`.
/// The sign of the pid is the whole point of these tests — a negative pid names
/// a process group, a positive one names a single process — so it is kept
/// verbatim rather than normalised.
class _Signals {
  final List<String> sent = [];

  /// [groupExists] models the only branch that matters: whether the host leads
  /// a process group. It does not on the real spawn, which is why the fallback
  /// is load-bearing rather than defensive.
  bool Function(int, ProcessSignal) send({bool groupExists = false}) =>
      (pid, signal) {
        sent.add('$pid:$signal');
        return pid > 0 || groupExists;
      };
}

void main() {
  group('terminateTreePosix', () {
    test('SIGTERMs first so the bridge can sweep its own PTY trees', () async {
      // The bridge traps SIGTERM and walks its terminals with killProcessTree,
      // which is the only thing that reaches a PTY grandchild — SIGKILL cannot
      // be trapped, so a straight kill leaves them behind.
      final s = _Signals();
      var probes = 0;
      await terminateTreePosix(
        4242,
        send: s.send(),
        alive: (_) async {
          probes++;
          return false;
        },
        delay: (_) async {},
      );

      expect(s.sent, ['-4242:SIGTERM', '4242:SIGTERM']);
      expect(probes, 1, reason: 'a host that exits is not polled again');
    });

    test('falls back to the bare pid when the host leads no group', () async {
      // The real case: HostController spawns with ProcessStartMode.normal, so
      // the host stays in the app's group and `-pid` is a reliable ESRCH.
      // killPid REPORTS that as false rather than throwing, so a fallback keyed
      // on exceptions alone would never signal the host at all.
      final s = _Signals();
      await terminateTreePosix(
        7,
        send: s.send(groupExists: false),
        alive: (_) async => false,
        delay: (_) async {},
      );

      expect(s.sent, ['-7:SIGTERM', '7:SIGTERM']);
    });

    test('signals the group alone when one exists', () async {
      final s = _Signals();
      await terminateTreePosix(
        7,
        send: s.send(groupExists: true),
        alive: (_) async => false,
        delay: (_) async {},
      );

      expect(
        s.sent,
        ['-7:SIGTERM'],
        reason: 'a delivered group signal already reached the leader',
      );
    });

    test('escalates to SIGKILL when the grace elapses', () async {
      final s = _Signals();
      var waited = Duration.zero;
      await terminateTreePosix(
        99,
        send: s.send(),
        alive: (_) async => true,
        delay: (d) async => waited += d,
        grace: const Duration(milliseconds: 300),
      );

      expect(s.sent, [
        '-99:SIGTERM',
        '99:SIGTERM',
        '-99:SIGKILL',
        '99:SIGKILL',
      ]);
      expect(waited, const Duration(milliseconds: 300));
    });

    test('never escalates against a host that exited during the grace', () async {
      // Escalation is not free: SIGKILL on a pid the OS may already have reused
      // is a signal delivered to something else entirely.
      final s = _Signals();
      var polls = 0;
      await terminateTreePosix(
        5,
        send: s.send(),
        alive: (_) async => ++polls < 3,
        delay: (_) async {},
        grace: const Duration(seconds: 5),
      );

      expect(s.sent, ['-5:SIGTERM', '5:SIGTERM']);
      expect(polls, 3);
    });
  });
}
