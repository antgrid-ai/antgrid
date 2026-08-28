import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

/// Probe whether [pid] is alive without delivering a signal.
///
/// Async to avoid blocking the UI isolate during project switches —
/// `tasklist` on Windows is slow (50–200ms) and was the dominant freeze
/// during local-mode reattach.
///
/// CRITICAL: do NOT use [Process.killPid] for existence probing — it actually
/// delivers the signal. Shell out instead.
Future<bool> isPidAlive(int pid) async {
  try {
    if (Platform.isWindows) {
      final r = await Process.run('tasklist', [
        '/FI',
        'PID eq $pid',
        '/NH',
        '/FO',
        'CSV',
      ]);
      return r.stdout.toString().contains('"$pid"');
    }
    final r = await Process.run('kill', ['-0', '$pid']);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// Cross-platform terminate. Windows uses `taskkill /F /PID`; Unix sends SIGTERM.
///
/// Async so awaiting it preserves kill-before-respawn ordering without
/// `Process.runSync` freezing the UI isolate.
Future<void> terminatePid(int pid) async {
  try {
    if (Platform.isWindows) {
      await Process.run('taskkill', ['/F', '/PID', '$pid']);
    } else {
      Process.killPid(pid, ProcessSignal.sigterm);
    }
  } catch (_) {
    // best-effort
  }
}

/// How long the POSIX path waits for a SIGTERMed host to sweep its own trees
/// before escalating. Long enough for the bridge's `shutdown()` to walk its
/// terminals (measured in the low hundreds of ms), short enough that the app
/// close this backstops doesn't visibly stall on a host that is past helping.
const _posixTreeGrace = Duration(milliseconds: 1500);

/// Force-kill [pid] AND its child process tree. Unlike [terminatePid], this
/// reaps grandchildren — the host's PTYs (claude/codex/dev servers) — which a
/// plain process kill would orphan. Used as the backstop when a graceful
/// `host:shutdown` doesn't exit in time on app close, and when a host from
/// another build has to be replaced.
Future<void> terminateTree(int pid) async {
  try {
    if (Platform.isWindows) {
      await Process.run('taskkill', ['/F', '/T', '/PID', '$pid']);
      return;
    }
    await terminateTreePosix(pid);
  } catch (_) {
    // best-effort
  }
}

/// The POSIX half, with the process seams injected so the escalation is
/// testable — the real one signals live pids and cannot be exercised in a unit
/// test.
///
/// **Signalling the group is not enough here, and on this spawn it reaches
/// nothing at all.** POSIX names a process GROUP, which exists only if the
/// target leads one, and nothing makes the host lead one: `HostController`
/// starts it with `ProcessStartMode.normal`, which leaves it in the app's
/// group (the bridge states the same precondition for its own children in
/// bridge/src/terminal-session.ts, and satisfies it there with `detached`). So
/// `-pid` is a reliable ESRCH and every call lands on the bare-pid fallback,
/// which reaches the host and nothing under it.
///
/// SIGTERM first is what closes that gap without changing how the host is
/// spawned — the bridge traps it (bridge/src/index.ts) and its `shutdown()`
/// runs `killProcessTree` over every terminal, which DOES name each PTY's own
/// group, because a PTY child is a session leader by construction. Escalating
/// to SIGKILL only after [grace] keeps the old behaviour as the floor.
///
/// Changing the spawn to a detached mode would fix the group directly, but it
/// is entangled with the Windows job-object assignment and the bootstrap-write
/// ordering in `spawnHostProcess` — the two things standing between a mistake
/// there and a bricked MSIX package. This stays on the signalling side.
@visibleForTesting
Future<void> terminateTreePosix(
  int pid, {
  bool Function(int pid, ProcessSignal signal) send = Process.killPid,
  Future<bool> Function(int pid) alive = isPidAlive,
  Future<void> Function(Duration d) delay = _delayFor,
  Duration grace = _posixTreeGrace,
}) async {
  // killPid returns false — it does NOT throw — when no group carries this id.
  // Fall back on a false return, not just on an exception, or a host that
  // leads no group is never signalled at all.
  if (!send(-pid, ProcessSignal.sigterm)) {
    send(pid, ProcessSignal.sigterm);
  }
  final deadline = grace;
  var waited = Duration.zero;
  const step = Duration(milliseconds: 100);
  while (waited < deadline) {
    if (!await alive(pid)) return;
    await delay(step);
    waited += step;
  }
  // Past helping: take what we can reach. A host wedged badly enough to ignore
  // SIGTERM was never going to sweep its own children, so this is the same
  // orphan risk that shipped before — not a regression, just the floor.
  if (!send(-pid, ProcessSignal.sigkill)) {
    send(pid, ProcessSignal.sigkill);
  }
}

Future<void> _delayFor(Duration d) => Future<void>.delayed(d);
