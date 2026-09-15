// The escalation notification title, and the one coupling it has to the
// bridge's copy of the same three strings.
//
// `handlerEscalationTitle` titles an escalation for an ATTACHED app; the
// bridge's `composePush` titles the same escalation for a phone that is asleep
// or detached. They are separate hand copies in separate languages with
// separate runners, so a string changed on one side alone tells the user two
// different things about one event depending only on whether their device
// happened to be awake — the failure nobody notices, because each surface is
// self-consistent.
//
// The first group pins the branch itself. The second reads the bridge's own
// literals back out of `compose.ts` and asserts they are the ones this function
// produces, which is the only thing that actually couples the two. It is a
// STRING gate: it says the words agree, not that the two branches pick between
// them the same way — the precedence assertions live on each side separately
// (`push-dispatcher.test.ts` for the bridge). A shared golden fixture the
// bridge test writes and this one reads is the real fix and is out of scope
// here; until then these three strings live in four places.
import 'dart:convert';
import 'dart:io';

import 'package:antgrid/models/handler_state.dart' show HandlerEscalation;
import 'package:antgrid/screens/workspace_shell.dart'
    show handlerEscalationTitle;
import 'package:flutter_test/flutter_test.dart';

/// Where the bridge composes the pushed copy, relative to the app package root
/// that `flutter test` runs from.
final _compose = File('../bridge/src/push/compose.ts');

HandlerEscalation _escalation({
  String urgency = 'normal',
  bool nonBlocking = false,
}) => HandlerEscalation(
  escalationId: 'e1',
  terminalId: 't1',
  question: 'Which schema should the migration target?',
  reasoning: 'r',
  draftReply: '',
  urgency: urgency,
  at: 1,
  nonBlocking: nonBlocking,
);

/// Every string literal in `composePush`'s `handler:escalation` title
/// expression, comments stripped so a title named only in prose cannot satisfy
/// the gate.
///
/// Throws rather than using `expect` so it is safe to call from `setUpAll`.
Set<String> _bridgeTitleLiterals(String source) {
  const branch = 'if (msg.type === "handler:escalation") {';
  const assign = 'const title =';
  final branchAt = source.indexOf(branch);
  if (branchAt < 0) {
    throw StateError(
      'Could not find "$branch" in ${_compose.absolute.path} — composePush was '
      'restructured and this gate is scraping nothing.',
    );
  }
  final titleAt = source.indexOf(assign, branchAt);
  final end = titleAt < 0 ? -1 : source.indexOf(';', titleAt);
  if (titleAt < 0 || end < 0) {
    throw StateError(
      'Found the handler:escalation branch but no "$assign …;" under it — the '
      'scrape markers in this test have drifted from the source.',
    );
  }
  final expr = [
    for (final raw in const LineSplitter().convert(
      source.substring(titleAt + assign.length, end),
    ))
      raw.contains('//') ? raw.substring(0, raw.indexOf('//')) : raw,
  ].join('\n');
  return RegExp(r'"([^"]*)"').allMatches(expr).map((m) => m.group(1)!).toSet();
}

void main() {
  group('the escalation notification title', () {
    test('an urgent escalation outranks everything else', () {
      expect(
        handlerEscalationTitle(_escalation(urgency: 'high')),
        'Handler — urgent',
      );
      // Unreachable through the engine, which mints `normal` for every ask, but
      // pinned so the precedence is a decision rather than an artifact of which
      // branch was written first.
      expect(
        handlerEscalationTitle(_escalation(urgency: 'high', nonBlocking: true)),
        'Handler — urgent',
      );
    });

    test('an ask is titled as a question, not as a stop', () {
      expect(
        handlerEscalationTitle(_escalation(nonBlocking: true)),
        'Handler has a question',
      );
    });

    test('an ordinary escalation still says the session is waiting', () {
      // The default is what every row predating the ask feature looks like, and
      // what the capability gate leaves behind for a bridge that can re-emit
      // `nonBlocking` but cannot be told the answer — so this branch is the one
      // that must never accidentally soften.
      expect(handlerEscalationTitle(_escalation()), 'Handler needs you');
    });
  });

  // An app-only checkout has no bridge tree. Skipping loudly beats failing:
  // this gate is about drift between two trees and only one of them is here.
  final missing = _compose.existsSync()
      ? null
      : 'No bridge tree at ${_compose.absolute.path} — the notification-copy '
            'gate needs both halves of the boundary it couples.';

  group('the bridge composes the same words', skip: missing, () {
    late final Set<String> literals;

    setUpAll(() => literals = _bridgeTitleLiterals(_compose.readAsStringSync()));

    test('every title this app raises is one the bridge also pushes', () {
      for (final esc in [
        _escalation(urgency: 'high'),
        _escalation(nonBlocking: true),
        _escalation(),
      ]) {
        expect(
          literals,
          contains(handlerEscalationTitle(esc)),
          reason:
              'composePush no longer writes "${handlerEscalationTitle(esc)}" — '
              'the same escalation would be described one way in the app and '
              'another way on the lock screen.',
        );
      }
    });

    test('the bridge has no title this app never raises', () {
      // Catches the other direction, which the loop above cannot: a fourth
      // branch added bridge-side would push a word no app surface ever shows.
      expect(
        literals.where((s) => s.startsWith('Handler')).toSet(),
        {'Handler — urgent', 'Handler has a question', 'Handler needs you'},
      );
    });
  });
}
