import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/agent_transport.dart';
import '../providers/demo_mode.dart';
import '../providers/sessions.dart';
import '../util/detached.dart';
import 'android_speech_engine.dart';
import 'sherpa_speech_engine.dart';
import 'simulated_speech_engine.dart';
import 'speech_engine.dart';
import 'voice_model_catalog.dart';
import 'voice_model_store.dart';

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

class VoiceInputController extends ChangeNotifier with WidgetsBindingObserver {
  VoiceInputController(this._default) : _engine = _default {
    WidgetsBinding.instance.addObserver(this);
  }

  /// The platform's engine, owned by [speechEngineProvider]; [_engine] differs
  /// only while the debug harness has swapped in a scenario.
  final SpeechEngine _default;
  SpeechEngine _engine;
  bool get hasRealEngine => _default is! SimulatedSpeechEngine;
  SpeechEngine get engine => _engine;
  final Map<VoiceTarget, VoiceDraft> _drafts = {};
  VoiceDraft draft(VoiceTarget target) =>
      _drafts.putIfAbsent(target, VoiceDraft.new);
  VoiceTarget? active;

  /// The engine's last answer. [start] reads it synchronously, so it is
  /// refreshed after each setup step rather than queried per keystroke.
  SpeechAvailability availability = const SpeechAvailability(
    SpeechReadiness.needsModel,
  );
  bool get canCapture => availability.readiness == SpeechReadiness.ready;
  bool holdToTalk = false;
  LogicalKeyboardKey? shortcut;
  bool _capturing = false;
  Timer? _clock;
  StreamSubscription<SpeechSetupProgress>? _prepare;
  int _capture = 0;
  bool _disposed = false;

  VoiceScenario? get scenario => switch (_engine) {
    final SimulatedSpeechEngine e => e.scenario,
    _ => null,
  };

  Future<void> refresh() async {
    final next = await _engine.availability();
    if (_disposed) return;
    availability = next;
    notifyListeners();
  }

  /// Debug harness only: swaps in a fresh simulated engine for [value].
  void configure(VoiceScenario value) {
    if (active != null) return;
    _swap(SimulatedSpeechEngine(value));
    availability = SimulatedSpeechEngine.initial(value);
    notifyListeners();
  }

  /// Leaves the debug harness for the platform's engine.
  Future<void> useDefaultEngine() async {
    if (active != null) return;
    _swap(_default);
    await refresh();
  }

  void _swap(SpeechEngine next) {
    _prepare?.cancel();
    if (!identical(_engine, _default)) _engine.dispose();
    _engine = next;
  }

  /// Called on signs that dictation is imminent, never at launch: loaded
  /// models hold about 1 GB, which someone who never dictates should not pay.
  void warmUp() {
    if (canCapture && active == null) _engine.warmUp();
  }

  void start(VoiceTarget target) {
    if (draft(target).text.isNotEmpty) return;
    if (active != null) preserve(active!);
    final d = draft(target);
    d.message = null;
    switch (availability.readiness) {
      case SpeechReadiness.unavailable:
        d.phase = VoicePhase.error;
        d.message =
            availability.reason ?? 'Voice input is unavailable on this device.';
        notifyListeners();
        return;
      case SpeechReadiness.needsModel:
        d.phase = VoicePhase.setup;
        notifyListeners();
        return;
      case SpeechReadiness.needsPermission:
        d.phase = VoicePhase.permission;
        notifyListeners();
        return;
      case SpeechReadiness.ready:
    }
    d.text = '';
    d.seconds = 0;
    d.phase = VoicePhase.listening;
    active = target;
    final capture = ++_capture;
    _capturing = true;
    _engine.start(capture, accept);
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      d.seconds++;
      notifyListeners();
    });
    notifyListeners();
  }

  void prepare(VoiceTarget target) {
    _prepare?.cancel();
    final d = draft(target)
      ..phase = availability.downloadBytes > 0
          ? VoicePhase.downloading
          : VoicePhase.preparing
      ..message = null
      ..progress = 0;
    _prepare = _engine.prepare().listen(
      (step) {
        d
          ..phase = step.downloading
              ? VoicePhase.downloading
              : VoicePhase.preparing
          ..progress = step.fraction.clamp(0, 1);
        notifyListeners();
      },
      onError: (Object error) {
        _prepare = null;
        d
          ..phase = VoicePhase.error
          ..message = error is SpeechEngineException
              ? error.message
              : 'Voice setup failed. Retry setup.';
        notifyListeners();
      },
      onDone: () async {
        _prepare = null;
        final next = await _engine.availability();
        if (_disposed ||
            (d.phase != VoicePhase.preparing &&
                d.phase != VoicePhase.downloading)) {
          return;
        }
        availability = next;
        switch (next.readiness) {
          case SpeechReadiness.needsPermission:
            d.phase = VoicePhase.permission;
          case SpeechReadiness.ready:
            d.phase = VoicePhase.idle;
            // Someone who just finished setup is about to try it.
            warmUp();
          case SpeechReadiness.needsModel || SpeechReadiness.unavailable:
            d
              ..phase = VoicePhase.error
              ..message =
                  next.reason ?? 'Voice setup did not finish. Retry setup.';
        }
        notifyListeners();
      },
      cancelOnError: true,
    );
    notifyListeners();
  }

  Future<void> grant(VoiceTarget target) async {
    final d = draft(target);
    final bool granted;
    try {
      granted = await _engine.requestPermission();
    } on SpeechEngineException catch (error) {
      if (_disposed || d.busy) return;
      d
        ..phase = VoicePhase.error
        ..message = error.message;
      notifyListeners();
      return;
    }
    if (_disposed || d.busy) return;
    if (!granted) {
      d.phase = VoicePhase.denied;
      notifyListeners();
      return;
    }
    availability = await _engine.availability();
    if (_disposed) return;
    start(target);
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
    _engine.stop();
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
    if (_capturing) _engine.cancel();
    _capturing = false;
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
    if (!identical(_engine, _default)) _engine.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

String terminalDictationText(String text) => text
    .replaceAll(RegExp(r'[\r\n\t\u2028\u2029]+'), ' ')
    .replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f]'), '');

/// Platforms without a real engine yet run the simulator. So do the demo,
/// which must never write to disk, and the test suite, which has no
/// path_provider or microphone plugin.
final speechEngineProvider = Provider<SpeechEngine>((ref) {
  final real =
      !ref.watch(demoModeProvider) &&
      !Platform.environment.containsKey('FLUTTER_TEST');
  final SpeechEngine engine;
  if (real && (Platform.isWindows || Platform.isLinux)) {
    engine = SherpaSpeechEngine(VoiceModelStore(voiceModelsRoot));
  } else if (real && Platform.isAndroid) {
    // A phone is the low-end tier: the small final model, never the 0.6B.
    engine = AndroidSpeechEngine(
      SherpaSpeechEngine(
        VoiceModelStore(voiceModelsRoot),
        offline: parakeet110m,
      ),
    );
  } else {
    engine = SimulatedSpeechEngine();
  }
  ref.onDispose(engine.dispose);
  return engine;
});

final voiceInputProvider = Provider<VoiceInputController>((ref) {
  final controller = VoiceInputController(ref.watch(speechEngineProvider));
  detached('Voice', 'read speech availability', controller.refresh);
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
