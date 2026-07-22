import 'dart:io';

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

/// Force-kill [pid] AND its child process tree. Unlike [terminatePid], this
/// reaps grandchildren — the host's PTYs (claude/codex/dev servers) — which a
/// plain process kill would orphan. Used as the backstop when a graceful
/// `host:shutdown` doesn't exit in time on app close.
Future<void> terminateTree(int pid) async {
  try {
    if (Platform.isWindows) {
      await Process.run('taskkill', ['/F', '/T', '/PID', '$pid']);
    } else {
      // Negative pid targets the whole process group (reaps PTY grandchildren
      // when the host leads its own group). killPid returns false — it does NOT
      // throw — when the group doesn't exist (e.g. the host shares the app's
      // group, so `pid` is not a PGID). Fall back to the bare pid on a false
      // return, not just on an exception, or the host would survive entirely.
      if (!Process.killPid(-pid, ProcessSignal.sigkill)) {
        Process.killPid(pid, ProcessSignal.sigkill);
      }
    }
  } catch (_) {
    // best-effort
  }
}
