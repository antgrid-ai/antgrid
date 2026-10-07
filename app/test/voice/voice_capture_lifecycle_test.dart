import 'dart:async';

import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/voice/simulated_speech_engine.dart';
import 'package:antgrid/voice/speech_engine.dart';
import 'package:antgrid/voice/voice_input.dart';
import 'package:antgrid/voice/voice_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const a = (project: 'p', session: 'a', surface: 'terminal');
const b = (project: 'p', session: 'b', surface: 'terminal');

class _PendingSpeechEngine implements SpeechEngine {
  final permission = Completer<bool>();
  Completer<SpeechAvailability>? readiness;
  final captures = <int>[];
  @override
  bool get onDevice => true;
  @override
  bool get supportsPartials => true;
  @override
  Future<SpeechAvailability> availability() =>
      readiness?.future ?? Future.value(SpeechAvailability.ready);
  @override
  Future<bool> requestPermission() => permission.future;
  @override
  Stream<SpeechSetupProgress> prepare() => const Stream.empty();
  @override
  void warmUp() {}
  @override
  void start(int capture, void Function(SpeechEvent) emit) =>
      captures.add(capture);
  @override
  void stop() {}
  @override
  void cancel() {}
  @override
  void dispose() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final duringReadiness in [false, true]) {
    testWidgets('cancel pending start during readiness=$duringReadiness', (
      tester,
    ) async {
      final engine = _PendingSpeechEngine();
      final c = VoiceInputController(engine)
        ..availability = const SpeechAvailability(
          SpeechReadiness.needsPermission,
        );
      addTearDown(c.dispose);
      c.draft(a).phase = VoicePhase.permission;
      final granting = c.grant(a);
      if (duringReadiness) {
        engine.readiness = Completer<SpeechAvailability>();
        engine.permission.complete(true);
        await tester.pump();
      }
      c.cancelSetup(a);
      if (duringReadiness) {
        engine.readiness!.complete(SpeechAvailability.ready);
      } else {
        engine.permission.complete(true);
      }
      await granting;
      expect(engine.captures, isEmpty);
      expect(c.active, isNull);
      expect(c.draft(a).phase, VoicePhase.idle);
      expect(c.availability.readiness, SpeechReadiness.needsPermission);
    });
  }

  testWidgets('late permission cannot retarget a newer capture', (
    tester,
  ) async {
    final engine = _PendingSpeechEngine()
      ..readiness = Completer<SpeechAvailability>();
    final c = VoiceInputController(engine)
      ..availability = SpeechAvailability.ready;
    addTearDown(c.dispose);
    final granting = c.grant(a);
    engine.permission.complete(true);
    await tester.pump();
    c.start(b);
    engine.readiness!.complete(SpeechAvailability.ready);
    await granting;
    expect(c.active, b);
    expect(engine.captures, hasLength(1));
    c.cancel(b);
  });

  test('unmounting a target invalidates its pending permission', () async {
    final engine = _PendingSpeechEngine();
    final c = VoiceInputController(engine);
    addTearDown(c.dispose);
    final granting = c.grant(a);
    c.preserve(a);
    engine.permission.complete(true);
    await granting;
    expect(engine.captures, isEmpty);
    expect(c.active, isNull);
  });

  test('backgrounding invalidates a pending permission request', () async {
    final engine = _PendingSpeechEngine();
    final c = VoiceInputController(engine);
    addTearDown(c.dispose);
    final granting = c.grant(a);
    c.didChangeAppLifecycleState(AppLifecycleState.paused);
    engine.permission.complete(true);
    await granting;
    expect(engine.captures, isEmpty);
    expect(c.active, isNull);
  });

  test(
    'navigation invalidates a start before capture becomes active',
    () async {
      final engine = _PendingSpeechEngine();
      final c = VoiceInputController(engine);
      addTearDown(c.dispose);
      final granting = c.grant(a);
      c.preserveCurrent(deferNotification: true);
      engine.permission.complete(true);
      await granting;
      expect(engine.captures, isEmpty);
      expect(c.active, isNull);
    },
  );

  test(
    'cancelling another target does not invalidate the pending start',
    () async {
      final engine = _PendingSpeechEngine();
      final c = VoiceInputController(engine);
      addTearDown(c.dispose);
      final granting = c.grant(b);
      c.cancelSetup(a);
      engine.permission.complete(true);
      await granting;
      expect(engine.captures, hasLength(1));
      expect(c.active, b);
    },
  );

  testWidgets('dismissing setup cancels the pending start', (tester) async {
    final engine = _PendingSpeechEngine();
    final c = VoiceInputController(engine)
      ..availability = SpeechAvailability.ready;
    addTearDown(c.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [voiceInputProvider.overrideWithValue(c)],
        child: MaterialApp(
          theme: buildAbTheme(),
          home: Scaffold(
            body: VoiceSetup(controller: c, target: a),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Start'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    engine.permission.complete(true);
    await tester.pump();
    expect(engine.captures, isEmpty);
    expect(c.active, isNull);
    expect(tester.takeException(), isNull);
  });

  test(
    'inactive permission prompt still allows the requested capture',
    () async {
      final engine = _PendingSpeechEngine();
      final c = VoiceInputController(engine);
      addTearDown(c.dispose);
      final granting = c.grant(a);
      c.didChangeAppLifecycleState(AppLifecycleState.inactive);
      c.didChangeAppLifecycleState(AppLifecycleState.resumed);
      engine.permission.complete(true);
      await granting;
      expect(engine.captures, hasLength(1));
      expect(c.active, a);
    },
  );

  test('changing engines invalidates a pending permission request', () async {
    final engine = _PendingSpeechEngine();
    final c = VoiceInputController(engine);
    addTearDown(c.dispose);
    final granting = c.grant(a);
    c.configure(VoiceScenario.streaming);
    final phase = c.draft(a).phase;
    engine.permission.complete(true);
    await granting;
    expect(c.draft(a).phase, phase);
    expect(c.active, isNull);
  });

  for (final replacement in ['', 'corrected hypothesis']) {
    test(
      'recognition failure preserves or replaces the partial: $replacement',
      () {
        final engine = _PendingSpeechEngine();
        final c = VoiceInputController(engine)
          ..availability = SpeechAvailability.ready;
        addTearDown(c.dispose);
        c.start(a);
        final capture = engine.captures.single;
        c.accept(SpeechEvent(capture, 'keep this recognized text'));
        c.accept(
          SpeechEvent(capture, replacement, error: 'microphone disconnected'),
        );
        expect(
          c.draft(a).text,
          replacement.isEmpty ? 'keep this recognized text' : replacement,
        );
        expect(c.draft(a).phase, VoicePhase.error);
        expect(c.draft(a).message, 'microphone disconnected');
        expect(c.active, isNull);
        c.accept(SpeechEvent(capture, 'late result'));
        expect(c.draft(a).text, isNot('late result'));
      },
    );
  }
}
