enum SpeechReadiness { ready, needsModel, needsPermission, unavailable }

class SpeechAvailability {
  const SpeechAvailability(
    this.readiness, {
    this.downloadBytes = 0,
    this.reason,
  });
  static const ready = SpeechAvailability(SpeechReadiness.ready);
  final SpeechReadiness readiness;

  /// What [SpeechEngine.prepare] still has to fetch; 0 when setup is local.
  final int downloadBytes;

  /// Shown to the user as-is when [readiness] is unavailable.
  final String? reason;
}

class SpeechSetupProgress {
  const SpeechSetupProgress(this.fraction, {this.downloading = false});
  final double fraction;
  final bool downloading;
}

/// A failure whose [message] is safe to show the user verbatim.
class SpeechEngineException implements Exception {
  const SpeechEngineException(this.message);
  final String message;
  @override
  String toString() => message;
}

class SpeechEvent {
  const SpeechEvent(
    this.capture,
    this.text, {
    this.finalized = false,
    this.error,
  });
  final int capture;
  final String text;
  final bool finalized;
  final String? error;
}

abstract interface class SpeechEngine {
  /// False when audio leaves the device. Never fall back to such an engine
  /// silently: the UI must say so before capture starts.
  bool get onDevice;
  bool get supportsPartials;
  Future<SpeechAvailability> availability();

  /// Fetches and loads whatever [availability] reported missing. Cancelling
  /// the subscription abandons setup, and must never leave an engine that
  /// later reports ready from a half-finished install.
  Stream<SpeechSetupProgress> prepare();
  Future<bool> requestPermission();

  /// A hint that capture is likely soon: load whatever [start] would
  /// otherwise load on the critical path. Safe to call repeatedly and while
  /// not ready; an engine with nothing to load ignores it.
  void warmUp();

  /// Events carrying a stale [capture] are dropped by the caller, so an engine
  /// need not guarantee silence after [cancel].
  void start(int capture, void Function(SpeechEvent) emit);
  void stop();
  void cancel();
  void dispose();
}
