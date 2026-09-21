import 'package:antgrid/voice/voice_input.dart';
import 'package:antgrid/voice/voice_composer_binding.dart';
import 'package:antgrid/widgets/transcript/composer/composer_controller.dart';
import 'package:fleather/fleather.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:antgrid/voice/voice_widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const a = (project: 'machine.project', session: 'a', surface: 'terminal');
const b = (project: 'machine.project', session: 'b', surface: 'terminal');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final correction in [true, false]) {
    testWidgets('handoff preserves preview edits: correction=$correction', (
      tester,
    ) async {
      final c = ComposerController(
        document: ParchmentDocument.fromJson([
          {'insert': 'Before old after\n'},
        ]),
      );
      c.fleather.updateSelection(
        const TextSelection(baseOffset: 7, extentOffset: 10),
      );
      late VoiceComposerBinding binding;
      binding = VoiceComposerBinding(c, () => binding.finish(keep: true));
      binding.update('river pod');
      c.appendText('incoming handoff');
      if (correction) {
        binding.preview.fleather.replaceText(7, 9, 'Riverpod');
      } else {
        binding.preview.fleather.replaceText(0, 6, 'Updated');
      }
      expect(
        c.toMarkdown(),
        contains(
          correction ? 'Before Riverpod after' : 'Updated river pod after',
        ),
      );
      expect(c.toMarkdown(), contains('incoming handoff'));
      expect(c.toMarkdown(), isNot(contains('old')));
      expect(
        c.fleather.document.toDelta().toJson().toString(),
        isNot(contains('underline')),
      );
      binding.update('late result');
      expect(c.toMarkdown(), isNot(contains('late result')));
      await tester.pump(const Duration(milliseconds: 600));
      binding.dispose();
      c.dispose();
    });
  }
  testWidgets('settings and restart cannot erase a pending terminal draft', (
    tester,
  ) async {
    final c = VoiceInputController()
      ..ready = true
      ..permission = true;
    c.draft(a)
      ..text = 'keep this prompt'
      ..phase = VoicePhase.review;
    c.configure(VoiceScenario.revised);
    c.start(a);
    c.cancelSetup(a);
    expect(c.draft(a).text, 'keep this prompt');
    expect(c.draft(a).phase, VoicePhase.review);
    expect(c.active, isNull);
    c.dispose();
  });

  testWidgets('simulated download can be cancelled without late readiness', (
    tester,
  ) async {
    final c = VoiceInputController()..scenario = VoiceScenario.modelDownload;
    c.prepare(a);
    expect(c.draft(a).phase, VoicePhase.downloading);
    await tester.pump(const Duration(milliseconds: 300));
    expect(c.draft(a).progress, greaterThan(0));
    c.cancelSetup(a);
    await tester.pump(const Duration(seconds: 2));
    expect(c.ready, false);
    expect(c.draft(a).phase, VoicePhase.idle);
    c.dispose();
  });
  testWidgets('manual correction is kept and removes provisional styling', (
    tester,
  ) async {
    final c = ComposerController();
    late VoiceComposerBinding binding;
    var edits = 0;
    binding = VoiceComposerBinding(c, () {
      edits++;
      binding.finish(keep: true);
    });
    binding.update('river pod');
    binding.preview.fleather.replaceText(0, 9, 'Riverpod');
    expect(edits, 1);
    expect(c.toMarkdown(), 'Riverpod');
    expect(
      c.fleather.document.toDelta().toJson().toString(),
      isNot(contains('underline')),
    );
    binding.update('late update');
    expect(c.toMarkdown(), 'Riverpod');
    binding.dispose();
    c.dispose();
  });

  testWidgets(
    'hold release finalizes and Escape cancels without terminal keys',
    (tester) async {
      final c = VoiceInputController()
        ..ready = true
        ..permission = true
        ..holdToTalk = true
        ..shortcut = LogicalKeyboardKey.f8;
      expect(
        handleVoiceKey(
          c,
          a,
          const KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.f8,
            logicalKey: LogicalKeyboardKey.f8,
            timeStamp: Duration.zero,
          ),
        ),
        KeyEventResult.handled,
      );
      expect(c.active, a);
      handleVoiceKey(
        c,
        a,
        const KeyUpEvent(
          physicalKey: PhysicalKeyboardKey.f8,
          logicalKey: LogicalKeyboardKey.f8,
          timeStamp: Duration.zero,
        ),
      );
      expect(c.draft(a).phase, VoicePhase.finalizing);
      expect(
        handleVoiceKey(
          c,
          a,
          const KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.escape,
            logicalKey: LogicalKeyboardKey.escape,
            timeStamp: Duration.zero,
          ),
        ),
        KeyEventResult.handled,
      );
      await tester.pump(const Duration(seconds: 1));
      expect(c.draft(a).phase, VoicePhase.idle);
      expect(c.draft(a).text, isEmpty);
      c.dispose();
    },
  );
  VoiceInputController ready() => VoiceInputController()
    ..ready = true
    ..permission = true;

  testWidgets('partials stay local and insert only reviewed sanitized text', (
    tester,
  ) async {
    final c = ready();
    c.start(a);
    await tester.pump(const Duration(seconds: 2));
    expect(c.draft(a).text, isNotEmpty);
    var writes = 0;
    expect(
      c.insert(a, (_) {
        writes++;
        return true;
      }),
      false,
    );
    expect(writes, 0);
    c.stop(a);
    expect(c.draft(a).phase, VoicePhase.finalizing);
    await tester.pump(const Duration(seconds: 1));
    c.edit(a, 'hello\nworld\r\x1b\x03');
    expect(
      c.insert(a, (text) {
        expect(text, 'hello world ');
        writes++;
        return true;
      }),
      true,
    );
    expect(writes, 1);
    expect(c.draft(a).text, isEmpty);
    c.dispose();
  });

  testWidgets('switching targets retains draft and rejects old results', (
    tester,
  ) async {
    final c = ready();
    c.start(a);
    await tester.pump(const Duration(seconds: 1));
    final text = c.draft(a).text;
    c.start(b);
    c.accept(const SpeechEvent(1, 'stale', finalized: true));
    expect(c.draft(a).text, text);
    expect(c.draft(a).phase, VoicePhase.review);
    expect(c.active, b);
    expect(c.draft(b).text, isEmpty);
    c.dispose();
  });

  testWidgets('refusal retains text and never retries automatically', (
    tester,
  ) async {
    final c = ready();
    c.draft(a)
      ..text = 'explain the failure'
      ..phase = VoicePhase.review;
    var attempts = 0;
    expect(
      c.insert(a, (_) {
        attempts++;
        return false;
      }),
      false,
    );
    await tester.pump(const Duration(seconds: 3));
    expect(attempts, 1);
    expect(c.draft(a).text, 'explain the failure');
    expect(c.draft(a).message, contains('original terminal'));
    c.dispose();
  });

  for (final scenario in [VoiceScenario.finalOnly, VoiceScenario.noSpeech]) {
    testWidgets('${scenario.name} has no invented partials', (tester) async {
      final c = ready()..scenario = scenario;
      c.start(a);
      await tester.pump(const Duration(seconds: 2));
      expect(c.draft(a).text, isEmpty);
      c.stop(a);
      await tester.pump(const Duration(seconds: 1));
      expect(c.draft(a).text.isEmpty, scenario == VoiceScenario.noSpeech);
      c.dispose();
    });
  }

  testWidgets('backgrounding releases capture and preserves partial text', (
    tester,
  ) async {
    final c = ready();
    c.start(a);
    await tester.pump(const Duration(seconds: 1));
    c.didChangeAppLifecycleState(AppLifecycleState.paused);
    expect(c.active, isNull);
    expect(c.draft(a).phase, VoicePhase.review);
    expect(c.draft(a).text, isNotEmpty);
    c.dispose();
  });

  testWidgets('setup failure and permission denial are recoverable', (
    tester,
  ) async {
    final c = VoiceInputController()
      ..scenario = VoiceScenario.preparationFailure;
    c.start(a);
    c.prepare(a);
    await tester.pump(const Duration(seconds: 2));
    expect(c.draft(a).phase, VoicePhase.error);
    c.configure(VoiceScenario.permissionDenied);
    c.prepare(a);
    await tester.pump(const Duration(seconds: 2));
    c.grant(a);
    expect(c.draft(a).phase, VoicePhase.denied);
    expect(c.active, isNull);
    c.configure(VoiceScenario.streaming);
    c.prepare(a);
    await tester.pump(const Duration(seconds: 2));
    c.grant(a);
    expect(c.active, a);
    c.dispose();
  });

  testWidgets(
    'revised previews preserve original and commit one undoable edit',
    (tester) async {
      final c = ComposerController(
        document: ParchmentDocument.fromJson([
          {'insert': 'Before old after\n'},
        ]),
      );
      c.fleather.updateSelection(
        const TextSelection(baseOffset: 7, extentOffset: 10),
      );
      final binding = VoiceComposerBinding(c, () {});
      binding.update('river pod');
      binding.update('Riverpod');
      expect(c.toMarkdown(), 'Before old after');
      expect(
        binding.preview.fleather.document.toPlainText(),
        'Before Riverpod after\n',
      );
      binding.finish(keep: true);
      await tester.pump(const Duration(milliseconds: 600));
      expect(c.toMarkdown(), 'Before Riverpod after');
      c.fleather.undo();
      expect(c.toMarkdown(), 'Before old after');
      binding.dispose();
      c.dispose();
    },
  );

  testWidgets('cancel restores formatted draft and original selection', (
    tester,
  ) async {
    final c = ComposerController(
      document: ParchmentDocument.fromJson([
        {
          'insert': 'keep',
          'attributes': {'b': true},
        },
        {'insert': '\n'},
      ]),
    );
    const selection = TextSelection(baseOffset: 0, extentOffset: 4);
    c.fleather.updateSelection(selection);
    final before = c.fleather.document.toDelta();
    final binding = VoiceComposerBinding(c, () {});
    binding.update('discard');
    binding.finish(keep: false);
    expect(c.fleather.document.toDelta(), before);
    expect(c.fleather.selection, selection);
    binding.dispose();
    c.dispose();
  });
}
