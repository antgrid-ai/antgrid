import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/agent_transport.dart';
import '../providers/sessions.dart';

enum VoicePhase {
  idle,
  setup,
  downloading,
  preparing,
  permission,
  denied,
  listening,
  finalizing,
  review,
  error,
}

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

typedef VoiceTarget = ({String project, String session, String surface});

class VoiceDraft {
  VoicePhase phase = VoicePhase.idle;
  String text = '';
  String? message;
  int seconds = 0;
  double progress = 0;
  bool get busy =>
      phase == VoicePhase.listening || phase == VoicePhase.finalizing;
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

abstract interface class SpeechInputBackend {
  bool get supportsPartials;
  void start(int capture, void Function(SpeechEvent) emit);
  void stop();
  void cancel();
}

/// Scripted input never requests microphone access or leaves the UI process.
class SimulatedSpeechBackend implements SpeechInputBackend {
  SimulatedSpeechBackend(this.scenario);
  final VoiceScenario scenario;
  Timer? _timer;
  int _capture = 0;
  void Function(SpeechEvent)? _emit;
  String _text = '';
  static const sample =
      'Explain the failing Riverpod test in agent-core.ts and suggest a fix.';
  String get result => scenario == VoiceScenario.noSpeech
      ? ''
      : scenario == VoiceScenario.longPrompt
      ? List.filled(12, sample).join(' ')
      : sample;
  @override
  bool get supportsPartials => scenario != VoiceScenario.finalOnly;
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
}

class VoiceInputController extends ChangeNotifier with WidgetsBindingObserver {
  VoiceInputController() {
    WidgetsBinding.instance.addObserver(this);
  }
  final Map<VoiceTarget, VoiceDraft> _drafts = {};
  VoiceDraft draft(VoiceTarget target) =>
      _drafts.putIfAbsent(target, VoiceDraft.new);
  VoiceTarget? active;
  VoiceScenario scenario = VoiceScenario.streaming;
  bool ready = false;
  bool permission = false;
  bool holdToTalk = false;
  LogicalKeyboardKey? shortcut;
  SpeechInputBackend? _backend;
  Timer? _clock;
  Timer? _prepare;
  int _capture = 0;
  bool _disposed = false;

  void configure(VoiceScenario value) {
    if (active != null) return;
    scenario = value;
    _prepare?.cancel();
    ready = false;
    permission = false;
    notifyListeners();
  }

  void start(VoiceTarget target) {
    if (draft(target).text.isNotEmpty) return;
    if (active != null) preserve(active!);
    final d = draft(target);
    d.message = null;
    if (scenario == VoiceScenario.unavailable) {
      d.phase = VoicePhase.error;
      d.message =
          'On-device dictation is unavailable for this simulated device.';
      notifyListeners();
      return;
    }
    if (!ready) {
      d.phase = VoicePhase.setup;
      notifyListeners();
      return;
    }
    if (!permission) {
      d.phase = VoicePhase.permission;
      notifyListeners();
      return;
    }
    d.text = '';
    d.seconds = 0;
    d.phase = VoicePhase.listening;
    active = target;
    final capture = ++_capture;
    _backend = SimulatedSpeechBackend(scenario)..start(capture, accept);
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      d.seconds++;
      notifyListeners();
    });
    notifyListeners();
  }

  void prepare(VoiceTarget target) {
    _prepare?.cancel();
    final d = draft(target)
      ..phase = scenario == VoiceScenario.modelDownload
          ? VoicePhase.downloading
          : VoicePhase.preparing;
    d.message = null;
    d.progress = 0;
    _prepare = Timer.periodic(const Duration(milliseconds: 250), (timer) {
      d.progress = (d.progress + .25).clamp(0, 1);
      if (d.progress == 1) {
        timer.cancel();
        if (scenario == VoiceScenario.preparationFailure) {
          d.phase = VoicePhase.error;
          d.message = 'Model preparation failed (simulated). Retry setup.';
        } else {
          ready = true;
          d.phase = VoicePhase.permission;
        }
      }
      notifyListeners();
    });
    notifyListeners();
  }

  void grant(VoiceTarget target) {
    if (scenario == VoiceScenario.permissionDenied) {
      draft(target).phase = VoicePhase.denied;
      notifyListeners();
    } else {
      permission = true;
      start(target);
    }
  }

  void accept(SpeechEvent event) {
    if (_disposed || event.capture != _capture || active == null) return;
    final d = draft(active!);
    d.text = event.text;
    if (event.finalized || event.error != null) {
      d.phase = event.error != null ? VoicePhase.error : VoicePhase.review;
      d.message =
          event.error ?? (d.text.isEmpty ? 'No speech detected.' : null);
      _release();
    }
    notifyListeners();
  }

  void stop(VoiceTarget target) {
    if (active != target || draft(target).phase != VoicePhase.listening) return;
    draft(target).phase = VoicePhase.finalizing;
    _clock?.cancel();
    _backend?.stop();
    notifyListeners();
  }

  void preserve(VoiceTarget target, {bool deferNotification = false}) {
    if (active != target) return;
    draft(target).phase = VoicePhase.review;
    draft(target).message = 'Dictation stopped. Text kept in this session.';
    _release();
    if (deferNotification) {
      scheduleMicrotask(() {
        if (!_disposed) notifyListeners();
      });
    } else {
      notifyListeners();
    }
  }

  void cancel(VoiceTarget target) {
    if (active == target) _release();
    _prepare?.cancel();
    _drafts[target] = VoiceDraft();
    notifyListeners();
  }

  void cancelSetup(VoiceTarget target) {
    _prepare?.cancel();
    final d = draft(target);
    if (d.busy) return;
    d.phase = d.text.isEmpty ? VoicePhase.idle : VoicePhase.review;
    d.message = null;
    notifyListeners();
  }

  void edit(VoiceTarget target, String text) {
    draft(target).text = text;
  }

  bool insert(VoiceTarget target, bool Function(String) send) {
    final d = draft(target);
    if (d.busy) return false;
    final text = terminalDictationText(d.text);
    if (text.isEmpty) return false;
    if (!send(text)) {
      d.message =
          'Cannot insert into the original terminal. Retry or copy the text.';
      notifyListeners();
      return false;
    }
    cancel(target);
    return true;
  }

  void _release() {
    _capture++;
    _backend?.cancel();
    _backend = null;
    _clock?.cancel();
    active = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && active != null) preserve(active!);
  }

  @override
  void dispose() {
    _disposed = true;
    _release();
    _prepare?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

String terminalDictationText(String text) => text
    .replaceAll(RegExp(r'[\r\n\t\u2028\u2029]+'), ' ')
    .replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f]'), '');

final voiceInputProvider = Provider<VoiceInputController>((ref) {
  final controller = VoiceInputController();
  void stopForNavigation() {
    final target = controller.active;
    if (target != null) controller.preserve(target, deferNotification: true);
  }

  ref.listen(selectedRegistrationIdProvider, (_, _) => stopForNavigation());
  ref.listen(activeSessionIdProvider, (_, _) => stopForNavigation());
  ref.onDispose(controller.dispose);
  return controller;
});

// Debug builds only: the setup sheet is still the scenario harness, and the
// offline demo is reachable from the sign-in screen in every build.
final voicePreviewEnabledProvider = Provider<bool>((ref) => kDebugMode);
