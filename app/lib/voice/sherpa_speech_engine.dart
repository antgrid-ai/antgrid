import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as so;

import '../util/ab_log.dart';
import 'speech_engine.dart';
import 'voice_model_catalog.dart';
import 'voice_model_store.dart';

/// On-device dictation with sherpa-onnx: a streaming [live] model drives the
/// partials, and on stop an [offline] model re-transcribes the buffered audio
/// and its text replaces them. Either may be null, never both.
///
/// Audio exists only in memory, in the worker isolate, for one utterance.
class SherpaSpeechEngine implements SpeechEngine {
  SherpaSpeechEngine(
    this._store, {
    this.live = krokoEn,
    this.offline = parakeetV2,
    AudioRecorder Function()? recorder,
    this.idleUnload = const Duration(minutes: 2),
  }) : assert(live != null || offline != null),
       _newRecorder = recorder ?? AudioRecorder.new;
  final VoiceModelStore _store;
  final VoiceModel? live;
  final VoiceModel? offline;
  final AudioRecorder Function() _newRecorder;

  /// Both models loaded hold about 1 GB, so the worker exits after this much
  /// idle time and the next capture pays the ~5 s load again.
  final Duration idleUnload;

  List<VoiceModel> get models => [?live, ?offline];

  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _audio;
  Completer<void>? _audioDone;
  _Worker? _worker;
  Timer? _idle;
  int _capture = 0;

  /// The capture the microphone is feeding. Keyed by id rather than a flag
  /// because the worker answers in order: a final for a capture the user
  /// already abandoned can land after the next one opened.
  int? _opened;
  void Function(SpeechEvent)? _emit;

  /// start/stop/cancel arrive from synchronous UI callbacks but each needs
  /// several awaits; chaining them keeps a quick tap-tap from interleaving a
  /// stop into a start that has not opened the microphone yet.
  Future<void> _queue = Future.value();

  @override
  bool get onDevice => true;

  @override
  bool get supportsPartials => live != null;

  Future<List<VoiceModel>> _missing() async => [
    for (final m in models)
      if (!await _store.installed(m)) m,
  ];

  @override
  Future<SpeechAvailability> availability() async {
    final missing = await _missing();
    if (missing.isNotEmpty) {
      return SpeechAvailability(
        SpeechReadiness.needsModel,
        downloadBytes: missing.fold(0, (sum, m) => sum + m.bytes),
      );
    }
    final granted = await (_recorder ??= _newRecorder()).hasPermission(
      request: false,
    );
    return granted
        ? SpeechAvailability.ready
        : const SpeechAvailability(SpeechReadiness.needsPermission);
  }

  @override
  Stream<SpeechSetupProgress> prepare() async* {
    final missing = await _missing();
    final total = missing.fold(0, (sum, m) => sum + m.bytes);
    var before = 0;
    for (final m in missing) {
      await for (final done in _store.install(m)) {
        yield SpeechSetupProgress((before + done) / total, downloading: true);
      }
      before += m.bytes;
    }
  }

  @override
  Future<bool> requestPermission() =>
      (_recorder ??= _newRecorder()).hasPermission();

  Future<void> removeModels() async {
    await _stopWorker();
    for (final m in models) {
      await _store.remove(m);
    }
  }

  @override
  void warmUp() {
    if (_opened != null) return;
    _enqueue(() async {
      if (_opened != null) return;
      if (_worker == null) {
        if ((await _missing()).isNotEmpty) return;
        _worker = _Worker.spawn(_onWorker, _onWorkerExit)..send(await _load());
      }
      _armIdle();
    });
  }

  @override
  void start(int capture, void Function(SpeechEvent) emit) {
    _idle?.cancel();
    _capture = capture;
    _emit = emit;
    _enqueue(() => _begin(capture));
  }

  @override
  void stop() {
    final capture = _capture;
    _enqueue(() => _finish(capture));
  }

  @override
  void cancel() => _enqueue(_abort);

  @override
  void dispose() {
    _idle?.cancel();
    _emit = null;
    _enqueue(() async {
      await _abort();
      await _stopWorker();
      await _recorder?.dispose();
      _recorder = null;
    });
  }

  void _enqueue(Future<void> Function() op) {
    _queue = _queue.then((_) => op()).catchError((Object error) {
      AbLog.error('Voice', 'speech engine', fields: {'error': '$error'});
      _fail(_capture, 'Dictation failed: $error');
    });
  }

  void _fail(int capture, String message) {
    if (_opened == capture) _opened = null;
    _emit?.call(SpeechEvent(capture, '', error: message));
  }

  Future<_Load> _load() async => _Load(
    live == null ? null : await _paths(live!),
    offline == null ? null : await _paths(offline!),
    math.max(1, math.min(4, Platform.numberOfProcessors ~/ 2)),
  );

  Future<void> _begin(int capture) async {
    if (capture != _capture) return;
    _idle?.cancel();
    final load = await _load();
    // The microphone takes about a second to deliver its first chunk, so it
    // opens while the worker spawns and loads rather than after.
    final worker = _worker ??= _Worker.spawn(_onWorker, _onWorkerExit);
    final recorder = _recorder ??= _newRecorder();
    final Stream<Uint8List> audio;
    try {
      audio = await recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: _sampleRate,
          numChannels: 1,
        ),
      );
    } on Object catch (error) {
      _fail(capture, 'Could not open the microphone: $error');
      return;
    }
    worker.send(_Start(capture, load));
    _opened = capture;
    final done = _audioDone = Completer<void>();
    _audio = audio.listen(
      (chunk) => worker.send(TransferableTypedData.fromList([chunk])),
      onError: (Object error) {
        if (!done.isCompleted) done.complete();
        _fail(capture, 'Microphone stopped: $error');
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
    );
  }

  Future<void> _closeMicrophone() async {
    final audio = _audio;
    if (audio == null) return;
    await _recorder?.stop();
    // The recorder flushes its last chunks before closing the stream; waiting
    // for that keeps the end of the utterance out of the bin.
    await _audioDone?.future.timeout(
      const Duration(seconds: 1),
      onTimeout: () {},
    );
    await audio.cancel();
    _audio = null;
  }

  Future<void> _finish(int capture) async {
    if (_opened != capture) return;
    await _closeMicrophone();
    _worker?.send(const _Stop());
  }

  Future<void> _abort() async {
    _opened = null;
    await _closeMicrophone();
    _worker?.send(const _Cancel());
    _armIdle();
  }

  void _armIdle() {
    _idle?.cancel();
    // Re-checked when it fires: a warm-up queued just ahead of a start arms
    // this timer after start() has already cancelled the previous one.
    _idle = Timer(idleUnload, () {
      _enqueue(() async {
        if (_opened == null) await _stopWorker();
      });
    });
  }

  Future<void> _stopWorker() async {
    final worker = _worker;
    _worker = null;
    if (worker == null) return;
    worker.send(const _Exit());
    await worker.exited;
  }

  void _onWorker(Object? message) {
    switch (message) {
      case _Partial(:final capture, :final text):
        if (_opened == capture) _emit?.call(SpeechEvent(capture, text));
      case _Final(:final capture, :final text):
        if (_opened == capture) _opened = null;
        _emit?.call(SpeechEvent(capture, text, finalized: true));
        _armIdle();
      case _Failed(:final capture, :final message):
        // A warm-up failure carries no capture anyone is waiting on, so this
        // line is the only trace of it; the next start retries the load.
        AbLog.error('Voice', 'speech worker', fields: {'error': message});
        _enqueue(() async {
          if (_opened == capture) await _closeMicrophone();
          _fail(capture, message);
          _armIdle();
        });
      case _Full(:final capture):
        _enqueue(() => _finish(capture));
    }
  }

  void _onWorkerExit(_Worker worker) {
    if (!identical(_worker, worker)) return;
    _worker = null;
    final capture = _opened;
    if (capture == null) return;
    _enqueue(() async {
      await _closeMicrophone();
      _fail(capture, 'Speech recognition stopped unexpectedly. Try again.');
    });
  }

  Future<_ModelPaths> _paths(VoiceModel m) async {
    final dir = (await _store.dir(m)).path;
    return _ModelPaths(
      p.join(dir, m.encoder.name),
      p.join(dir, m.decoder.name),
      p.join(dir, m.joiner.name),
      p.join(dir, m.tokens.name),
    );
  }
}

const _sampleRate = 16000;

/// The offline pass has only been measured on utterances under a minute, and
/// the whole buffer is transcribed at once, so capture ends itself here.
const _maxSamples = _sampleRate * 120;

class _Worker {
  _Worker._(this._inbox, this._exit);
  final ReceivePort _inbox;
  final ReceivePort _exit;
  SendPort? _port;

  /// Messages sent before the isolate handed over its port, in order.
  final _pending = <Object>[];
  final _exited = Completer<void>();
  Future<void> get exited => _exited.future;

  /// Dropped once the worker has exited; the exit is what reports the loss.
  void send(Object message) {
    if (_exited.isCompleted) return;
    final port = _port;
    port == null ? _pending.add(message) : port.send(message);
  }

  static _Worker spawn(
    void Function(Object?) onMessage,
    void Function(_Worker) onExit,
  ) {
    final worker = _Worker._(ReceivePort(), ReceivePort());
    void exited() {
      if (worker._exited.isCompleted) return;
      worker._inbox.close();
      worker._exit.close();
      worker._pending.clear();
      worker._exited.complete();
      onExit(worker);
    }

    worker._inbox.listen((message) {
      if (message is SendPort) {
        worker._port = message;
        worker._pending.forEach(message.send);
        worker._pending.clear();
      } else {
        onMessage(message);
      }
    });
    worker._exit.listen((_) => exited());
    unawaited(
      Isolate.spawn(
        _speechWorker,
        worker._inbox.sendPort,
        onExit: worker._exit.sendPort,
        onError: worker._exit.sendPort,
        debugName: 'speech',
      ).then<void>(
        (_) {},
        onError: (Object error) {
          AbLog.error(
            'Voice',
            'spawn speech worker',
            fields: {'error': '$error'},
          );
          exited();
        },
      ),
    );
    return worker;
  }
}

class _ModelPaths {
  const _ModelPaths(this.encoder, this.decoder, this.joiner, this.tokens);
  final String encoder;
  final String decoder;
  final String joiner;
  final String tokens;
}

class _Load {
  const _Load(this.live, this.offline, this.threads);
  final _ModelPaths? live;
  final _ModelPaths? offline;
  final int threads;
}

class _Start {
  const _Start(this.capture, this.load);
  final int capture;
  final _Load load;
}

class _Stop {
  const _Stop();
}

class _Cancel {
  const _Cancel();
}

class _Exit {
  const _Exit();
}

class _Partial {
  const _Partial(this.capture, this.text);
  final int capture;
  final String text;
}

class _Final {
  const _Final(this.capture, this.text);
  final int capture;
  final String text;
}

class _Failed {
  const _Failed(this.capture, this.message);
  final int capture;
  final String message;
}

class _Full {
  const _Full(this.capture);
  final int capture;
}

void _speechWorker(SendPort reply) {
  final inbox = ReceivePort();
  reply.send(inbox.sendPort);
  so.initBindings();

  so.OnlineRecognizer? live;
  _ModelPaths? livePaths;
  so.OfflineRecognizer? offline;
  _ModelPaths? offlinePaths;
  so.OnlineStream? stream;
  var capture = 0;
  var open = false;
  final chunks = <Float32List>[];
  var samples = 0;
  var shown = '';

  void reset() {
    stream?.free();
    stream = null;
    chunks.clear();
    samples = 0;
    shown = '';
    open = false;
  }

  // Paths are recorded only once a recognizer is built, so a load that throws
  // is retried by the next start instead of leaving that model silently absent.
  void load(_Load start) {
    if (start.live?.encoder != livePaths?.encoder) {
      live?.free();
      live = null;
      livePaths = null;
      final paths = start.live;
      if (paths != null) {
        live = so.OnlineRecognizer(
          so.OnlineRecognizerConfig(
            model: so.OnlineModelConfig(
              transducer: so.OnlineTransducerModelConfig(
                encoder: paths.encoder,
                decoder: paths.decoder,
                joiner: paths.joiner,
              ),
              tokens: paths.tokens,
              numThreads: start.threads,
              debug: false,
            ),
            enableEndpoint: false,
          ),
        );
        livePaths = paths;
      }
    }
    if (start.offline?.encoder != offlinePaths?.encoder) {
      offline?.free();
      offline = null;
      offlinePaths = null;
      final paths = start.offline;
      if (paths != null) {
        offline = so.OfflineRecognizer(
          so.OfflineRecognizerConfig(
            model: so.OfflineModelConfig(
              transducer: so.OfflineTransducerModelConfig(
                encoder: paths.encoder,
                decoder: paths.decoder,
                joiner: paths.joiner,
              ),
              tokens: paths.tokens,
              modelType: 'nemo_transducer',
              numThreads: start.threads,
              debug: false,
            ),
          ),
        );
        offlinePaths = paths;
      }
    }
  }

  void accept(Uint8List bytes) {
    if (!open || samples >= _maxSamples) return;
    final pcm = ByteData.sublistView(bytes);
    final chunk = Float32List(bytes.length ~/ 2);
    for (var i = 0; i < chunk.length; i++) {
      chunk[i] = pcm.getInt16(i * 2, Endian.little) / 32768;
    }
    chunks.add(chunk);
    samples += chunk.length;
    final recognizer = live;
    final s = stream;
    if (recognizer != null && s != null) {
      s.acceptWaveform(samples: chunk, sampleRate: _sampleRate);
      while (recognizer.isReady(s)) {
        recognizer.decode(s);
      }
      final text = recognizer.getResult(s).text.trim();
      if (text != shown) {
        shown = text;
        reply.send(_Partial(capture, text));
      }
    }
    if (samples >= _maxSamples) reply.send(_Full(capture));
  }

  String transcribe() {
    final recognizer = offline;
    if (recognizer != null) {
      final all = Float32List(samples);
      var offset = 0;
      for (final c in chunks) {
        all.setAll(offset, c);
        offset += c.length;
      }
      final s = recognizer.createStream();
      try {
        s.acceptWaveform(samples: all, sampleRate: _sampleRate);
        recognizer.decode(s);
        return recognizer.getResult(s).text.trim();
      } finally {
        s.free();
      }
    }
    final streaming = live!;
    final s = stream!;
    // Trailing silence lets the streaming model emit its last tokens.
    s.acceptWaveform(
      samples: Float32List(_sampleRate ~/ 2),
      sampleRate: _sampleRate,
    );
    s.inputFinished();
    while (streaming.isReady(s)) {
      streaming.decode(s);
    }
    return streaming.getResult(s).text.trim();
  }

  inbox.listen((message) {
    try {
      switch (message) {
        case _Load():
          load(message);
        case _Start():
          reset();
          capture = message.capture;
          load(message.load);
          stream = live?.createStream();
          open = true;
        case TransferableTypedData():
          accept(message.materialize().asUint8List());
        case _Stop():
          if (!open) return;
          final text = samples == 0 ? '' : transcribe();
          reply.send(_Final(capture, text));
          reset();
        case _Cancel():
          reset();
        case _Exit():
          reset();
          live?.free();
          offline?.free();
          inbox.close();
          Isolate.exit();
      }
    } on Object catch (error) {
      reset();
      reply.send(_Failed(capture, 'Speech recognition failed: $error'));
    }
  });
}
