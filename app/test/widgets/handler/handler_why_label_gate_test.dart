// The bridge's judge prompt makes the user a promise about where its
// reasoning goes — see the sentence containing `"Why" disclosure` in
// decision.ts — and the app's disclosure toggle is what has to keep it. The
// two are separate hand copies in separate languages: a rename on either side
// alone makes the prompt lie to the judge about where its words go, silently,
// because nothing else couples them. Pattern borrowed from
// `handler_escalation_title_test.dart`, which reads the bridge's own literals
// back out of its source the same way.
import 'dart:io';

import 'package:antgrid/widgets/handler/handler_why.dart'
    show handlerFallbackQuestion, handlerWhyLabel;
import 'package:flutter_test/flutter_test.dart';

/// Where the bridge promises the judge its `reason` is shown behind a "Why"
/// disclosure, relative to the app package root that `flutter test` runs
/// from.
final _decision = File('../bridge/src/handler/decision.ts');

/// Where the bridge mints the fallback question a card's `escalate()` uses
/// when the judge's `notify.body` was empty.
final _engine = File('../bridge/src/handler/engine.ts');

/// The bridge's THIRD hand copy of that same fallback: the push body a
/// backgrounded phone sees. Nothing type-checks it against the engine's.
final _compose = File('../bridge/src/push/compose.ts');

void main() {
  // An app-only checkout has no bridge tree. Skipping loudly beats failing:
  // this gate is about drift between two trees and only one of them is here.
  final missing =
          _decision.existsSync() && _engine.existsSync() && _compose.existsSync()
      ? null
      : 'No bridge tree at ${_decision.absolute.path} — the "Why" label gate '
            'needs both halves of the boundary it couples.';

  group('the "Why" disclosure label', skip: missing, () {
    test('matches the word the bridge promises the judge', () {
      final source = _decision.readAsStringSync();
      // The source is a TS double-quoted string literal, so the inner quotes
      // around the word are escaped as `\"`.
      final match = RegExp(r'\\"([^\\"]+)\\" disclosure').firstMatch(source);
      if (match == null) {
        fail(
          'Could not find a \\"...\\" disclosure literal in '
          '${_decision.absolute.path} — the prompt wording this gate scrapes '
          'moved, or was reworded, and the gate needs updating with it.',
        );
      }
      final bridgeWord = match.group(1)!;
      expect(
        handlerWhyLabel,
        bridgeWord,
        reason:
            'decision.ts promises the judge its reasoning is shown behind a '
            '"$bridgeWord" disclosure, but handlerWhyLabel is '
            '"$handlerWhyLabel" — the prompt is telling the judge one word '
            'and the card shows another.',
      );
    });
  });

  // `_defaultWhyExpanded` opens the disclosure by default only when the
  // question on screen IS this fallback — the one signal that `reason` is the
  // sole informative text the card has. Nothing type-checks the two copies
  // against each other, so a rename on the bridge side silently leaves a card
  // collapsed over its only sentence.
  group('the escalate fallback question', skip: missing, () {
    test('matches the literal handlerFallbackQuestion compares against', () {
      final source = _engine.readAsStringSync();
      final match = RegExp(
        r'\?\?\s*"([^"]+)"\s*,\s*MAX_ROW_QUESTION_CHARS',
      ).firstMatch(source);
      if (match == null) {
        fail(
          'Could not find the `?? "..."` fallback question literal in '
          '${_engine.absolute.path} — the escalate mint moved, or was '
          'reworded, and this gate needs updating with it.',
        );
      }
      final bridgeFallback = match.group(1)!;
      expect(
        handlerFallbackQuestion,
        bridgeFallback,
        reason:
            'engine.ts mints "$bridgeFallback" as the question when '
            'notify.body is empty, but handlerFallbackQuestion is '
            '"$handlerFallbackQuestion" — a card with no question text would '
            'default its "Why" disclosure closed.',
      );
    });
  });

  // The push body a backgrounded phone reads is a third hand copy of the same
  // fallback. It is not compared against the Dart const — the two are allowed
  // to be different sentences in principle — but it IS compared against the
  // engine's, because a phone whose notification says one thing and whose card
  // says another is reporting two different questions for one escalation.
  group('the push fallback body', skip: missing, () {
    test("matches the engine's own escalate fallback", () {
      final engineMatch = RegExp(
        r'\?\?\s*"([^"]+)"\s*,\s*MAX_ROW_QUESTION_CHARS',
      ).firstMatch(_engine.readAsStringSync());
      final composeMatch = RegExp(
        r'msg\.question\.length\s*>\s*0\s*\?\s*msg\.question\s*:\s*"([^"]+)"',
      ).firstMatch(_compose.readAsStringSync());
      if (engineMatch == null || composeMatch == null) {
        fail(
          'Could not read both fallback literals — engine match: '
          '${engineMatch?.group(1)}, compose match: ${composeMatch?.group(1)}. '
          'One of the two mints moved and this gate needs updating with it.',
        );
      }
      expect(
        composeMatch.group(1),
        engineMatch.group(1),
        reason:
            'push/compose.ts sends "${composeMatch.group(1)}" as the '
            'notification body where engine.ts puts "${engineMatch.group(1)}" '
            'on the card — one escalation, two different questions.',
      );
    });
  });
}
