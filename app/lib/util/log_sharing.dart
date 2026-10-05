import 'dart:io';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:share_plus/share_plus.dart';

import '../launcher/host_discovery.dart' show hostDir;
import 'ab_log.dart';
import 'log_location.dart';
import 'log_rotation.dart';

enum LogShareOutcome { presented, noLogFiles, failed }

/// The log files worth sharing from [dir]; missing and empty files are
/// skipped. The push isolate's file comes first: it is the lesser context.
List<String> shareableLogFiles(String dir) {
  final push = '$dir/$kPushLogFileName';
  final current = '$dir/$kAppLogFileName';
  return [
    rotatedLogPath(push),
    push,
    rotatedLogPath(current),
    current,
  ].where((p) {
    try {
      final f = File(p);
      return f.existsSync() && f.lengthSync() > 0;
    } catch (_) {
      return false;
    }
  }).toList();
}

/// Flushes AbLog, then opens the OS share sheet with app.log and the push
/// isolate's log (and their rotated predecessors). [origin] anchors the iPad
/// popover; iPhone/Android ignore it.
/// Never throws.
Future<LogShareOutcome> shareAppLogs({
  Rect? origin,
  @visibleForTesting String? logDir,
  @visibleForTesting Future<void> Function()? flush,
  @visibleForTesting Future<ShareResult> Function(ShareParams params)? share,
}) async {
  try {
    final dir = logDir ?? await AbLog.initLogDirectory();
    await (flush ?? AbLog.flush)();
    if (dir == null) return LogShareOutcome.noLogFiles;
    final files = shareableLogFiles(dir);
    if (files.isEmpty) return LogShareOutcome.noLogFiles;
    await (share ?? SharePlus.instance.share)(
      ShareParams(
        files: [for (final p in files) XFile(p, mimeType: 'text/plain')],
        subject: 'Antgrid app logs',
        sharePositionOrigin: origin,
      ),
    );
    // A dismissed or unavailable sheet is the user's choice, not a failure.
    return LogShareOutcome.presented;
  } catch (e) {
    AbLog.warn('LogSharing', 'share failed', fields: {'error': '$e'});
    return LogShareOutcome.failed;
  }
}

/// Desktop: reveal the log directory (app.log and host.log both live in
/// hostDir()). Returns false when the file manager could not be launched.
Future<bool> openLogFolder({String? dir}) async {
  final d = dir ?? hostDir(); // host.log lives here (one host per machine)
  try {
    await Directory(d).create(recursive: true);
    if (Platform.isWindows) {
      // hostDir() yields a mixed-separator path (e.g. C:\Users\me/.antgrid).
      // explorer.exe treats '/' as a switch prefix and silently opens the
      // default Documents view, so hand it pure backslashes.
      await Process.start('explorer.exe', [
        d.replaceAll('/', r'\'),
      ], runInShell: false);
    } else if (Platform.isMacOS) {
      await Process.start('open', [d]);
    } else {
      await Process.start('xdg-open', [d]);
    }
    return true;
  } catch (_) {
    return false;
  }
}
