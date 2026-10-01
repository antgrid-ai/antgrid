import 'dart:async';

import 'package:flutter/services.dart';
import 'package:record/record.dart';

import '../util/ab_log.dart';
import 'speech_engine.dart';

/// The OS on-device recognizer (android/.../NativeSpeech.kt) on phones that
/// have one, and [fallback] on phones that do not.
///
/// The OS path never uses a server recognizer, so both paths are on-device
/// and the choice needs no consent. Which one applies is settled by the first
/// [availability] call; until then every call goes to the OS path.
class AndroidSpeechEngine implements SpeechEngine {
  AndroidSpeechEngine(
    this.fallback, {
    this.language = 'en-US',
    MethodChannel methods = const MethodChannel('ai.radhaai.antgrid/speech'),
    EventChannel events = const EventChannel(
      'ai.radhaai.antgrid/speech/events',
    ),
    AudioRecorder Function()? recorder,
  }) : _methods = methods,
       _eventChannel = events,
       _newRecorder = recorder ?? AudioRecorder.new;
  final SpeechEngine fallback;
  final String language;
  final MethodChannel _methods;
  final EventChannel _eventChannel;
  final AudioRecorder Function() _newRecorder;

  bool? _native;

  /// The installed variant the OS reported, e.g. en-GB for an en-US request.
  String? _tag;
  AudioRecorder? _recorder;
  StreamSubscription<dynamic>? _events;
  StreamSubscription<Map<Object?, Object?>>? _captureEvents;
  final _bus = StreamController<Map<Object?, Object?>>.broadcast();
  void Function(SpeechEvent)? _emit;

  /// True once the phone is known to lack a usable OS recognizer.
  bool get usesFallback => _native == false;

  @override
  bool get onDevice => true;

  @override
  bool get supportsPartials => usesFallback ? fallback.supportsPartials : true;

  void _listen() {
    _events ??= _eventChannel.receiveBroadcastStream().listen(
      (event) {
        if (event is Map) _bus.add(event);
      },
      onError: (Object error) {
        AbLog.error('Voice', 'speech events', fields: {'error': '$error'});
      },
    );
  }

  Future<Map<Object?, Object?>> _status() async =>
      await _methods.invokeMapMethod<Object?, Object?>('status', {
        'language': language,
      }) ??
      const {};

  @override
  Future<SpeechAvailability> availability() async {
    if (_native == false) return fallback.availability();
    final Map<Object?, Object?> status;
    try {
      status = await _status();
    } on PlatformException catch (error) {
      AbLog.error('Voice', 'speech status', fields: {'error': '$error'});
      _native = false;
      return fallback.availability();
    }
    if (status['onDevice'] != true || status['state'] == 'unsupported') {
      _native = false;
      return fallback.availability();
    }
    _native = true;
    _tag = status['language'] as String? ?? language;
    return switch (status['state']) {
      'downloadable' ||
      'pending' => const SpeechAvailability(SpeechReadiness.needsModel),
      _ => await _permission(),
    };
  }

  Future<SpeechAvailability> _permission() async {
    final granted = await (_recorder ??= _newRecorder()).hasPermission(
      request: false,
    );
    return granted
        ? SpeechAvailability.ready
        : const SpeechAvailability(SpeechReadiness.needsPermission);
  }

  @override
  Stream<SpeechSetupProgress> prepare() async* {
    if (_native == false) {
      yield* fallback.prepare();
      return;
    }
    _listen();
    // Buffered, and subscribed before the download starts, so no progress
    // event can land between the call returning and the loop reading.
    final updates = StreamController<Map<Object?, Object?>>();
    final sub = _bus.stream
        .where((e) => e['type'] == 'download')
        .listen(updates.add);
    final it = StreamIterator(updates.stream);
    try {
      final mode = await _methods.invokeMethod<String>('download', {
        'language': _tag ?? language,
      });
      if (mode == 'listening') {
        while (await it.moveNext().timeout(const Duration(minutes: 10))) {
          final e = it.current;
          if (e['progress'] case final int percent) {
            yield SpeechSetupProgress(percent / 100, downloading: true);
          } else if (e['done'] == true) {
            return;
          } else if (e['error'] case final int code) {
            throw SpeechEngineException(
              'The English speech pack failed to download (error $code). '
              'Retry setup.',
            );
          } else if (e['scheduled'] == true) {
            break;
          }
        }
      } else if (mode != 'scheduled') {
        throw const SpeechEngineException(
          'This Android version cannot download speech packs. '
          'Retry setup to use a downloaded model instead.',
        );
      }
      // Android 13 reports nothing, and a scheduled download may wait for
      // Wi-Fi, so the only signal left is the pack showing up as installed.
      yield const SpeechSetupProgress(0, downloading: true);
      final deadline = DateTime.now().add(const Duration(minutes: 10));
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(seconds: 3));
        if ((await _status())['state'] == 'installed') return;
      }
      throw const SpeechEngineException(
        'The English speech pack has not finished downloading. Android may be '
        'waiting for Wi-Fi; retry setup later.',
      );
    } on TimeoutException {
      throw const SpeechEngineException(
        'The English speech pack download stalled. Retry setup.',
      );
    } on PlatformException catch (error) {
      throw SpeechEngineException(
        'Could not download the English speech pack: ${error.message}. '
        'Retry setup.',
      );
    } finally {
      await it.cancel();
      await sub.cancel();
      await updates.close();
    }
  }

  @override
  Future<bool> requestPermission() {
    if (_native == false) return fallback.requestPermission();
    return (_recorder ??= _newRecorder()).hasPermission();
  }

  @override
  void warmUp() {
    if (_native == false) fallback.warmUp();
  }

  @override
  void start(int capture, void Function(SpeechEvent) emit) {
    if (_native == false) return fallback.start(capture, emit);
    _emit = emit;
    _listen();
    _captureEvents ??= _bus.stream.listen(_onEvent);
    _call(capture, 'start', {'capture': capture, 'language': _tag ?? language});
  }

  @override
  void stop() {
    if (_native == false) return fallback.stop();
    _call(null, 'stop');
  }

  @override
  void cancel() {
    if (_native == false) return fallback.cancel();
    _call(null, 'cancel');
  }

  @override
  void dispose() {
    _emit = null;
    fallback.dispose();
    unawaited(_captureEvents?.cancel());
    unawaited(_events?.cancel());
    unawaited(_bus.close());
    unawaited(_recorder?.dispose());
    _call(null, 'dispose');
  }

  void _call(int? capture, String method, [Map<String, Object?>? args]) {
    unawaited(
      _methods.invokeMethod<void>(method, args).catchError((Object error) {
        AbLog.error('Voice', 'speech $method', fields: {'error': '$error'});
        if (capture != null) {
          _emit?.call(
            SpeechEvent(capture, '', error: 'Dictation could not start.'),
          );
        }
      }),
    );
  }

  void _onEvent(Map<Object?, Object?> e) {
    final capture = e['capture'];
    if (capture is! int) return;
    final text = e['text'] as String? ?? '';
    switch (e['type']) {
      case 'partial':
        _emit?.call(SpeechEvent(capture, text));
      case 'final':
        _emit?.call(SpeechEvent(capture, text, finalized: true));
      case 'error':
        _emit?.call(
          SpeechEvent(capture, text, error: _message(e['code'] as int? ?? 0)),
        );
    }
  }

  /// Codes are SpeechRecognizer.ERROR_*.
  static String _message(int code) => switch (code) {
    3 => 'The microphone could not be read. Try again.',
    5 || 8 => 'The speech recognizer is busy. Try again.',
    9 => 'Microphone access is blocked. Allow it in Android settings.',
    10 || 11 => 'The speech recognizer disconnected. Try again.',
    12 || 13 => 'English speech recognition is not installed on this phone.',
    _ => 'Dictation stopped (recognizer error $code). Try again.',
  };
}
