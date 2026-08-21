import 'dart:async';
import 'dart:convert' show jsonEncode;
import 'dart:developer' as developer;
import 'dart:io' show File, FileMode, Platform, ProcessInfo;
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/scheduler.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Compile-time flag enabling perf instrumentation.
/// Build with `--dart-define=ANTGRID_DEBUG_PERF=true` to enable.
const bool kDebugPerf = bool.fromEnvironment(
  'ANTGRID_DEBUG_PERF',
  defaultValue: false,
);

/// Lightweight perf recorder that writes per-frame jank, keystroke-to-glyph
/// echo latency, drawer rebuild counts, and process RSS samples to
/// `<appSupport>/perf.log` when [kDebugPerf] is true. No-ops otherwise.
class PerfRecorder {
  int _drawerRebuilds = 0;
  Timer? _rssTimer;
  Timer? _echoSummaryTimer;
  File? _logFile;

  /// Monotonic time base. `DateTime.now()` is wall-clock and can step
  /// backwards across an NTP correction, which would mint negative latencies.
  final Stopwatch _clock = Stopwatch()..start();

  /// Frame budget derived from the panel's live refresh rate. A fixed 16ms
  /// passes every frame that misses a 120Hz deadline — exactly the band worth
  /// seeing on ProMotion and high-refresh Android.
  int _frameBudgetUs = _fallbackFrameBudgetUs;
  bool _budgetLogged = false;
  static const int _fallbackFrameBudgetUs = 16667;

  /// A terminal echo carries no correlation id, so a keystroke is paired with
  /// the NEXT output on the same terminal. That inference only holds when the
  /// terminal was quiet first: agent TUIs stream continuously, and an unguarded
  /// pairing would mostly time unrelated output that happened to land next.
  static const int _echoQuietWindowUs = 150000;

  /// Beyond this, the echo never came (dropped send, session down, a keystroke
  /// the TUI swallowed). Recording it would poison the distribution with
  /// timeouts rather than latencies.
  static const int _echoTimeoutUs = 2000000;

  /// EVERY frame's timings, not just the ones that missed budget.
  ///
  /// Sampling only over-budget frames is biased in the direction that hides
  /// wins: an improvement pushes frames under budget, which deletes them from
  /// the sample and RAISES the surviving p50, so a real gain reads as a
  /// regression. It also yields only tens of samples on a short driven path,
  /// far too few to resolve the 1-2ms effects worth chasing.
  final List<int> _frameTotalUs = [];
  final List<int> _frameBuildUs = [];
  final List<int> _frameRasterUs = [];
  int _framesOverBudget = 0;
  bool _frameSamplesTruncated = false;

  /// ~40 minutes at 120Hz. Instrumentation must not grow without bound in a
  /// session someone leaves running overnight.
  static const int _maxFrameSamples = 300000;

  /// Bucket edges in microseconds, placed around the two deadlines that matter
  /// (8.33ms at 120Hz, 16.67ms at 60Hz) so a distribution can be read against
  /// the budget directly instead of recomputed.
  static const List<int> _histogramEdgesUs = [
    2000,
    4000,
    6000,
    8333,
    10000,
    12000,
    14000,
    16667,
    20000,
    25000,
    33333,
    50000,
  ];

  final Map<_TerminalEchoKey, int> _lastOutputUs = {};
  final Map<_TerminalEchoKey, int> _pendingEchoUs = {};
  final List<_EchoSample> _echoSamples = [];

  Future<void> start() async {
    if (!kDebugPerf) return;
    final dir = await getApplicationSupportDirectory();
    _logFile = File(p.join(dir.path, 'perf.log'));
    await _logFile!.parent.create(recursive: true);
    await _appendLine(
      '=== PerfRecorder started at ${DateTime.now().toIso8601String()} ===',
    );
    _refreshFrameBudget();

    _registerDumpExtension();

    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _rssTimer = Timer.periodic(const Duration(seconds: 2), (_) => _sampleRss());
    _echoSummaryTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _summarizeEcho(),
    );
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

  /// Arms the echo timer for one terminal in one project checkout. Silently
  /// declines when the pairing would be unsound — see [_echoQuietWindowUs].
  void noteTerminalInput({
    required String projectId,
    required String checkoutId,
    required String terminalId,
  }) {
    if (!kDebugPerf) return;
    final key = (
      projectId: projectId,
      checkoutId: checkoutId,
      terminalId: terminalId,
    );
    if (_pendingEchoUs.containsKey(key)) return;
    final now = _clock.elapsedMicroseconds;
    final lastOut = _lastOutputUs[key];
    if (lastOut != null && now - lastOut < _echoQuietWindowUs) return;
    _pendingEchoUs[key] = now;
  }

  /// Closes the echo timer if one is armed for this project checkout and
  /// terminal.
  void noteTerminalOutput({
    required String projectId,
    required String checkoutId,
    required String terminalId,
  }) {
    if (!kDebugPerf) return;
    final key = (
      projectId: projectId,
      checkoutId: checkoutId,
      terminalId: terminalId,
    );
    final now = _clock.elapsedMicroseconds;
    _lastOutputUs[key] = now;
    final startedUs = _pendingEchoUs.remove(key);
    if (startedUs == null) return;
    final wireUs = now - startedUs;
    if (wireUs > _echoTimeoutUs) return;

    // Post-frame runs after build/layout/paint of the frame carrying this
    // output but BEFORE the raster thread finishes, so true photon latency is
    // one raster longer than `screen` reports. It also only fires once some
    // frame is scheduled — a background terminal may not schedule one at all,
    // hence the second timeout guard.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      final screenUs = _clock.elapsedMicroseconds - startedUs;
      if (screenUs > _echoTimeoutUs) return;
      // Add only completed pairs. A reporting timer can run between wire
      // receipt and this callback, so maintaining separate lists would split
      // the two halves across summary windows.
      _echoSamples.add(_EchoSample(wireUs: wireUs, screenUs: screenUs));
      _appendLine(
        'echo project=$projectId checkout=$checkoutId terminal=$terminalId '
        'wire=${wireUs}us screen=${screenUs}us',
      );
    });
  }

  void _refreshFrameBudget() {
    final hz = PlatformDispatcher.instance.implicitView?.display.refreshRate;
    // Platforms report 0 before the first frame settles.
    final budget = (hz != null && hz > 1)
        ? (1000000 / hz).round()
        : _fallbackFrameBudgetUs;
    // Always emit the first resolve. A detected 60Hz panel computes the same
    // number as the fallback, so change-detection alone would leave "60Hz" and
    // "the query failed" looking identical in the log.
    if (_budgetLogged && budget == _frameBudgetUs) return;
    _budgetLogged = true;
    _frameBudgetUs = budget;
    _appendLine(
      'display refreshRate=${hz?.toStringAsFixed(1) ?? 'unavailable'}Hz '
      'frameBudget=${budget}us',
    );
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      final total = t.totalSpan.inMicroseconds;
      final build = t.buildDuration.inMicroseconds;
      final raster = t.rasterDuration.inMicroseconds;

      if (total > _frameBudgetUs) {
        _framesOverBudget++;
        _appendLine(
          'jank frame total=${total}us budget=${_frameBudgetUs}us '
          'build=${build}us raster=${raster}us',
        );
      }

      if (_frameTotalUs.length >= _maxFrameSamples) {
        _frameSamplesTruncated = true;
        continue;
      }
      _frameTotalUs.add(total);
      _frameBuildUs.add(build);
      _frameRasterUs.add(raster);
    }
  }

  /// Cumulative distribution of every frame seen since [start] or the last
  /// [resetFrames].
  String frameSummary() {
    if (_frameTotalUs.isEmpty) return 'frame-summary n=0';
    final buffer = StringBuffer()
      ..writeln(
        'frame-summary n=${_frameTotalUs.length} '
        'overBudget=$_framesOverBudget budget=${_frameBudgetUs}us'
        '${_frameSamplesTruncated ? ' TRUNCATED' : ''}',
      )
      ..writeln('  raster ${_distribution(_frameRasterUs)}')
      ..writeln('  build  ${_distribution(_frameBuildUs)}')
      ..writeln('  total  ${_distribution(_frameTotalUs)}')
      ..write('  raster-hist ${_histogram(_frameRasterUs)}');
    return buffer.toString();
  }

  /// Starts a fresh measurement window.
  void resetFrames() {
    _frameTotalUs.clear();
    _frameBuildUs.clear();
    _frameRasterUs.clear();
    _framesOverBudget = 0;
    _frameSamplesTruncated = false;
  }

  /// `ext.antgrid.perfDump?reset=true` writes [frameSummary] on demand, so a
  /// measured window can be bounded by whoever is driving the app rather than
  /// by a timer that may never tick during a short scripted run.
  void _registerDumpExtension() {
    try {
      developer.registerExtension('ext.antgrid.perfDump', (_, params) async {
        final summary = frameSummary();
        await _appendLine(summary);
        if (params['reset'] == 'true') resetFrames();
        return developer.ServiceExtensionResponse.result(
          jsonEncode({'summary': summary}),
        );
      });
    } catch (_) {
      // Already registered — a hot restart re-runs start(). The first
      // registration still points at this same singleton.
    }
  }

  String _distribution(List<int> samples) {
    if (samples.isEmpty) return 'n/a';
    final sorted = List<int>.of(samples)..sort();
    String at(double q) {
      final i = ((sorted.length - 1) * q).round();
      return (sorted[i] / 1000).toStringAsFixed(1);
    }

    final mean = sorted.reduce((a, b) => a + b) / sorted.length / 1000;
    return 'p50=${at(0.50)} p90=${at(0.90)} p95=${at(0.95)} p99=${at(0.99)} '
        'max=${(sorted.last / 1000).toStringAsFixed(1)} '
        'mean=${mean.toStringAsFixed(1)} (ms)';
  }

  /// Empty buckets are omitted: the interesting shape is where the mass sits,
  /// and a fixed 13-column line pads it out with zeros that bury it.
  String _histogram(List<int> samples) {
    final counts = List<int>.filled(_histogramEdgesUs.length + 1, 0);
    for (final v in samples) {
      var i = 0;
      while (i < _histogramEdgesUs.length && v >= _histogramEdgesUs[i]) {
        i++;
      }
      counts[i]++;
    }
    final parts = <String>[];
    for (var i = 0; i < counts.length; i++) {
      if (counts[i] == 0) continue;
      final lo = i == 0
          ? '0'
          : (_histogramEdgesUs[i - 1] / 1000).toStringAsFixed(1);
      final hi = i == _histogramEdgesUs.length
          ? 'inf'
          : (_histogramEdgesUs[i] / 1000).toStringAsFixed(1);
      parts.add('$lo-$hi:${counts[i]}');
    }
    return parts.join(' ');
  }

  void _summarizeEcho() {
    // Re-read here too: an adaptive panel switches rate at runtime, so a budget
    // sampled only at startup goes stale mid-session.
    _refreshFrameBudget();
    // Frame distributions are intentionally dump-only: sorting three large,
    // cumulative sample lists on this periodic UI-isolate timer would create
    // the jank this recorder is meant to measure.
    if (_echoSamples.isEmpty) return;
    final samples = List<_EchoSample>.of(_echoSamples);
    _echoSamples.clear();
    _appendLine(
      'echo-summary n=${samples.length} '
      'wire=${_percentileLine(samples.map((sample) => sample.wireUs))} '
      'screen=${_percentileLine(samples.map((sample) => sample.screenUs))}',
    );
  }

  String _percentileLine(Iterable<int> samples) {
    if (samples.isEmpty) return 'n/a';
    final sorted = samples.toList()..sort();
    String at(double q) {
      final i = ((sorted.length - 1) * q).round();
      return '${(sorted[i] / 1000).toStringAsFixed(1)}ms';
    }

    return 'p50=${at(0.50)} p95=${at(0.95)} p99=${at(0.99)}';
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
    _echoSummaryTimer?.cancel();
    _echoSummaryTimer = null;
  }
}

typedef _TerminalEchoKey = ({
  String projectId,
  String checkoutId,
  String terminalId,
});

class _EchoSample {
  const _EchoSample({required this.wireUs, required this.screenUs});

  final int wireUs;
  final int screenUs;
}

/// Singleton recorder. Inert unless [kDebugPerf] is true.
final PerfRecorder perfRecorder = PerfRecorder();
