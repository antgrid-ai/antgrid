import 'dart:io';

/// Max bytes before a log file is rotated. 10 MiB — big enough for a long
/// debugging session, small enough to bound disk now that both host.log and
/// app.log write in every build mode.
const int kMaxLogBytes = 10 * 1024 * 1024;

/// If [path] exists and exceeds [maxBytes], move it to `<path>.old`
/// (overwriting any prior `.old`) so the caller can start fresh. One generation
/// only. Fail-open: any filesystem error is swallowed — logging must never
/// crash the app.
void rotateLogIfNeeded(String path, {int maxBytes = kMaxLogBytes}) {
  try {
    final f = File(path);
    if (!f.existsSync()) return;
    if (f.lengthSync() <= maxBytes) return;
    final old = File('$path.old');
    if (old.existsSync()) old.deleteSync();
    f.renameSync('$path.old');
  } catch (_) {
    // Best-effort; never throw.
  }
}
