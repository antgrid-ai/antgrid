import 'package:antgrid/voice/android_speech_engine.dart';
import 'package:antgrid/voice/simulated_speech_engine.dart';
import 'package:antgrid/voice/speech_engine.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';

class _Recorder implements AudioRecorder {
  bool granted = true;
  @override
  Future<bool> hasPermission({bool request = true}) async => granted;
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _methods = MethodChannel('test/speech');
const _events = EventChannel('test/speech/events');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Map<String, Object?> status;
  late List<MethodCall> calls;
  late String downloadMode;
  MockStreamHandlerEventSink? sink;
  late _Recorder recorder;

  setUp(() {
    status = {'onDevice': true, 'state': 'installed', 'language': 'en-US'};
    calls = [];
    downloadMode = 'listening';
    sink = null;
    recorder = _Recorder();
    messenger.setMockMethodCallHandler(_methods, (call) async {
      calls.add(call);
      return switch (call.method) {
        'status' => status,
        'download' => downloadMode,
        _ => null,
      };
    });
    messenger.setMockStreamHandler(
      _events,
      MockStreamHandler.inline(onListen: (_, events) => sink = events),
    );
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(_methods, null);
    messenger.setMockStreamHandler(_events, null);
  });

  AndroidSpeechEngine engine(SpeechEngine fallback) => AndroidSpeechEngine(
    fallback,
    methods: _methods,
    events: _events,
    recorder: () => recorder,
  );

  test('a phone without an on-device recognizer uses the fallback', () async {
    status = {'onDevice': false};
    final fallback = SimulatedSpeechEngine();
    final e = engine(fallback);
    expect(
      (await e.availability()).readiness,
      SpeechReadiness.needsModel,
      reason: "the fallback's answer, not the OS path's",
    );
    expect(e.usesFallback, isTrue);
    e.warmUp();
    expect(fallback.warmUps, 1);
    e.start(1, (_) {});
    expect(calls.where((c) => c.method == 'start'), isEmpty);
    e.dispose();
  });

  test('an unsupported language also falls back', () async {
    status = {'onDevice': true, 'state': 'unsupported'};
    final e = engine(SimulatedSpeechEngine());
    await e.availability();
    expect(e.usesFallback, isTrue);
  });

  test('pack state and permission map onto readiness', () async {
    final e = engine(SimulatedSpeechEngine());
    expect((await e.availability()).readiness, SpeechReadiness.ready);
    recorder.granted = false;
    expect((await e.availability()).readiness, SpeechReadiness.needsPermission);
    status = {'onDevice': true, 'state': 'downloadable'};
    expect((await e.availability()).readiness, SpeechReadiness.needsModel);
    expect(e.usesFallback, isFalse);
  });

  test('pack download reports progress and ends on success', () async {
    status = {'onDevice': true, 'state': 'downloadable', 'language': 'en-GB'};
    final e = engine(SimulatedSpeechEngine());
    await e.availability();
    final progress = <double>[];
    final done = e.prepare().forEach((p) => progress.add(p.fraction));
    await pumpEventQueue();
    sink!.success({'type': 'download', 'capture': 0, 'progress': 40});
    sink!.success({'type': 'download', 'capture': 0, 'done': true});
    await done;
    expect(progress, [0.4]);
    expect(
      calls.singleWhere((c) => c.method == 'download').arguments,
      containsPair('language', 'en-GB'),
    );
  });

  test('a failed pack download is a setup error', () async {
    status = {'onDevice': true, 'state': 'downloadable'};
    final e = engine(SimulatedSpeechEngine());
    await e.availability();
    final done = e.prepare().drain<void>();
    await pumpEventQueue();
    sink!.success({'type': 'download', 'capture': 0, 'error': 4});
    await expectLater(done, throwsA(isA<SpeechEngineException>()));
  });

  test('recognizer events become speech events for their capture', () async {
    final e = engine(SimulatedSpeechEngine());
    await e.availability();
    final got = <SpeechEvent>[];
    e.start(7, got.add);
    await pumpEventQueue();
    expect(
      calls.singleWhere((c) => c.method == 'start').arguments,
      containsPair('capture', 7),
    );
    sink!.success({'type': 'partial', 'capture': 7, 'text': 'open the'});
    sink!.success({'type': 'final', 'capture': 7, 'text': 'open the file'});
    sink!.success({'type': 'error', 'capture': 7, 'code': 13, 'text': 'x'});
    await pumpEventQueue();
    expect(got.map((s) => (s.capture, s.text, s.finalized)), [
      (7, 'open the', false),
      (7, 'open the file', true),
      (7, 'x', false),
    ]);
    expect(got.last.error, contains('not installed'));
    e.stop();
    e.cancel();
    await pumpEventQueue();
    expect(calls.map((c) => c.method), containsAll(['stop', 'cancel']));
  });
}
