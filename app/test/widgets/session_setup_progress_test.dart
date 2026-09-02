// The two readouts that make a provisioning wait legible: what is left to do,
// and how long it has been going. "2 of 5" answers neither on a real block —
// step 1 is a 10 ms `copy:` and the rest are the minutes.
import 'package:antgrid/design/ab_icons.dart';
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/design/widgets/ab_icon.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/widgets/session_setup_progress.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _names = ['Copy env files', 'Install dependencies', 'Generate client'];

SessionSetup _setup(
  String state, {
  int stepIndex = 1,
  List<String> stepNames = _names,
}) => SessionSetup(
  state: state,
  stepIndex: stepIndex,
  stepCount: 3,
  stepNames: stepNames,
  startedAt: 1700,
);

Future<void> _pumpLedger(WidgetTester tester, SessionSetup setup) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(extensions: const [kDefaultPalette]),
      home: Scaffold(body: SetupStepLedger(setup: setup)),
    ),
  );
}

/// The icon on the row carrying [name] — the row's state is only ever readable
/// from its glyph and its tone, so the test has to read it the same way.
({String icon, Color? color}) _marker(WidgetTester tester, String name) {
  final row = find.ancestor(of: find.text(name), matching: find.byType(Row)).first;
  final icon = tester.widget<AbIcon>(
    find.descendant(of: row, matching: find.byType(AbIcon)),
  );
  return (icon: icon.icon, color: icon.color);
}

Color _labelColor(WidgetTester tester, String name) =>
    tester.widget<Text>(find.text(name)).style!.color!;

void main() {
  group('SetupStepLedger', () {
    testWidgets('separates what is done from what is still to come', (
      tester,
    ) async {
      await _pumpLedger(tester, _setup('running'));

      expect(_marker(tester, 'Copy env files').icon, AbIcons.check);
      expect(_marker(tester, 'Copy env files').color, kDefaultPalette.success);

      expect(_marker(tester, 'Install dependencies').icon, AbIcons.chevronRight);
      expect(_marker(tester, 'Install dependencies').color, kDefaultPalette.accent);
      // The only row at full strength: it is the one the run is on.
      expect(_labelColor(tester, 'Install dependencies'), kDefaultPalette.textPrimary);

      expect(_marker(tester, 'Generate client').icon, AbIcons.circle);
      expect(_labelColor(tester, 'Generate client'), kDefaultPalette.textDisabled);
    });

    testWidgets('names the step a failed run died on', (tester) async {
      await _pumpLedger(tester, _setup('failed'));
      expect(_marker(tester, 'Install dependencies').icon, AbIcons.error);
      expect(_marker(tester, 'Install dependencies').color, kDefaultPalette.error);
      // Everything after it never ran, so nothing may report it as having.
      expect(_marker(tester, 'Generate client').icon, AbIcons.circle);
    });

    testWidgets('a finished run leaves no step looking in flight', (
      tester,
    ) async {
      await _pumpLedger(tester, _setup('done', stepIndex: 2));
      for (final name in _names) {
        expect(_marker(tester, name).icon, AbIcons.check, reason: name);
      }
    });

    testWidgets('renders nothing when the bridge sent no names', (
      tester,
    ) async {
      // A state recovered from disk, or a bridge predating the field: a ledger
      // of blanks answers less than the progress rule already above it.
      await _pumpLedger(tester, _setup('running', stepNames: const []));
      expect(find.byType(AbIcon), findsNothing);
    });
  });

  group('SetupElapsed', () {
    testWidgets('says nothing about a clock it cannot trust', (tester) async {
      // `startedAt` is the BRIDGE's clock, and for a remote machine that is not
      // ours. A negative reading is the one shape of skew we can detect.
      await tester.pumpWidget(
        MaterialApp(
          home: SetupElapsed(
            startedAt: DateTime.now().millisecondsSinceEpoch + 600000,
            color: kDefaultPalette.textMuted,
          ),
        ),
      );
      expect(find.byType(Text), findsNothing);
      // Unmounted by hand: the ticker is periodic, and a test that ends with
      // one pending fails the suite rather than this expectation.
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
