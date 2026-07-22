import 'dart:async';
import 'dart:io' show File, FileMode, Platform, ProcessInfo;

import 'package:flutter/scheduler.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Compile-time flag enabling perf instrumentation.
/// Build with `--dart-define=ANTGRID_DEBUG_PERF=true` to enable.
const bool kDebugPerf = bool.fromEnvironment(
  'ANTGRID_DEBUG_PERF',
  defaultValue: false,
);

/// Lightweight perf recorder that writes per-frame jank, drawer rebuild
/// counts, and process RSS samples to `<appSupport>/perf.log` when
/// [kDebugPerf] is true. No-ops otherwise.
class PerfRecorder {
  int _drawerRebuilds = 0;
  Timer? _rssTimer;
  File? _logFile;

  Future<void> start() async {
    if (!kDebugPerf) return;
    final dir = await getApplicationSupportDirectory();
    _logFile = File(p.join(dir.path, 'perf.log'));
    await _logFile!.parent.create(recursive: true);
    await _appendLine(
      '=== PerfRecorder started at ${DateTime.now().toIso8601String()} ===',
    );

    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _rssTimer = Timer.periodic(const Duration(seconds: 2), (_) => _sampleRss());
  }

  void noteDrawerRebuild() {
    if (!kDebugPerf) return;
    _drawerRebuilds++;
  }

  void noteFocusSwitch(String fromId, String toId) {
    if (!kDebugPerf) return;
    _appendLine(
      'focus-switch from=$fromId to=$toId ts=${DateTime.now().toIso8601String()}',
    );
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      final total = t.totalSpan.inMicroseconds;
      if (total > 16000) {
        _appendLine(
          'jank frame total=${total}us '
          'build=${t.buildDuration.inMicroseconds}us '
          'raster=${t.rasterDuration.inMicroseconds}us',
        );
      }
    }
  }

  void _sampleRss() {
    if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) return;
    final rss = ProcessInfo.currentRss;
    _appendLine('rss bytes=$rss drawerRebuilds=$_drawerRebuilds');
    _drawerRebuilds = 0;
  }

  Future<void> _appendLine(String line) async {
    final f = _logFile;
    if (f == null) return;
    try {
      await f.writeAsString('$line\n', mode: FileMode.append, flush: false);
    } catch (_) {
      // Swallow logging errors; instrumentation must never crash the app.
    }
  }

  void dispose() {
    _rssTimer?.cancel();
    _rssTimer = null;
  }
}

/// Singleton recorder. Inert unless [kDebugPerf] is true.
final PerfRecorder perfRecorder = PerfRecorder();
