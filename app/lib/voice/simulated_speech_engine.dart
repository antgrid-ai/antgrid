import 'dart:async';

import 'speech_engine.dart';

enum VoiceScenario {
  streaming,
  finalOnly,
  revised,
  longPrompt,
  noSpeech,
  permissionDenied,
  preparationFailure,
  interrupted,
  modelDownload,
  unavailable,
}

/// Scripted input never requests microphone access or leaves the UI process.
class SimulatedSpeechEngine implements SpeechEngine {
  SimulatedSpeechEngine([this.scenario = VoiceScenario.streaming]);
  final VoiceScenario scenario;
  bool _prepared = false;
  bool _granted = false;

  /// Lets the harness leave the denied state without switching scenario.
  bool allowAfterDenial = false;

  Timer? _timer;
  int _capture = 0;
  void Function(SpeechEvent)? _emit;
  String _text = '';
  static const sample =
      'Explain the failing Riverpod test in agent-core.ts and suggest a fix.';
  static const _downloadBytes = 487 * 1000 * 1000;

  String get result => scenario == VoiceScenario.noSpeech
      ? ''
      : scenario == VoiceScenario.longPrompt
      ? List.filled(12, sample).join(' ')
      : sample;

  /// What [availability] reports before any setup, for callers that must
  /// show a state synchronously when switching scenario.
  static SpeechAvailability initial(VoiceScenario scenario) => switch (scenario) {
    VoiceScenario.unavailable => const SpeechAvailability(
      SpeechReadiness.unavailable,
      reason: 'On-device dictation is unavailable for this simulated device.',
    ),
    VoiceScenario.modelDownload => const SpeechAvailability(
      SpeechReadiness.needsModel,
      downloadBytes: _downloadBytes,
    ),
    _ => const SpeechAvailability(SpeechReadiness.needsModel),
  };

  @override
  bool get onDevice => true;

  @override
  bool get supportsPartials => scenario != VoiceScenario.finalOnly;

  @override
  Future<SpeechAvailability> availability() async {
    if (scenario == VoiceScenario.unavailable || !_prepared) {
      return initial(scenario);
    }
    return _granted
        ? SpeechAvailability.ready
        : const SpeechAvailability(SpeechReadiness.needsPermission);
  }

  @override
  Stream<SpeechSetupProgress> prepare() async* {
    for (var step = 1; step <= 4; step++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      yield SpeechSetupProgress(
        step / 4,
        downloading: scenario == VoiceScenario.modelDownload,
      );
    }
    if (scenario == VoiceScenario.preparationFailure) {
      throw const SpeechEngineException(
        'Model preparation failed (simulated). Retry setup.',
      );
    }
    _prepared = true;
  }

  @override
  Future<bool> requestPermission() async {
    _granted =
        scenario != VoiceScenario.permissionDenied || allowAfterDenial;
    return _granted;
  }

  @override
  void start(int capture, void Function(SpeechEvent) emit) {
    cancel();
    _capture = capture;
    _emit = emit;
    var tick = 0;
    _timer = Timer.periodic(const Duration(milliseconds: 700), (_) {
      tick++;
      if (scenario == VoiceScenario.interrupted && tick == 4) {
        _timer?.cancel();
        emit(
          SpeechEvent(
            capture,
            _text,
            error: 'Microphone disconnected (simulated).',
          ),
        );
        return;
      }
      if (!supportsPartials || scenario == VoiceScenario.noSpeech) return;
      final words = result.split(' ');
      _text = words.take(tick * 3).join(' ');
      if (scenario == VoiceScenario.revised && tick == 2) {
        _text = 'Explain the failing river pod test';
      }
      emit(SpeechEvent(capture, _text));
    });
  }

  @override
  void stop() {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 600), () {
      _emit?.call(SpeechEvent(_capture, result, finalized: true));
    });
  }

  @override
  void cancel() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() => cancel();
}
