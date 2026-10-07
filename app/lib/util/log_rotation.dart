import 'dart:io';

/// Max bytes before a log file is rotated. 10 MiB — big enough for a long
/// debugging session, small enough to bound disk now that both host.log and
/// app.log write in every build mode.
const int kMaxLogBytes = 10 * 1024 * 1024;

/// The single previous generation [rotateLogIfNeeded] keeps; log sharing reads
/// the same name.
String rotatedLogPath(String path) => '$path.old';

/// If [path] exists and exceeds [maxBytes], move it to `<path>.old`
/// (overwriting any prior `.old`) so the caller can start fresh. One generation
/// only. Fail-open: any filesystem error is swallowed — logging must never
/// crash the app.
void rotateLogIfNeeded(String path, {int maxBytes = kMaxLogBytes}) {
  try {
    final f = File(path);
    if (!f.existsSync()) return;
    if (f.lengthSync() <= maxBytes) return;
    final old = File(rotatedLogPath(path));
    if (old.existsSync()) old.deleteSync();
    f.renameSync(rotatedLogPath(path));
  } catch (_) {
    // Best-effort; never throw.
  }
}
