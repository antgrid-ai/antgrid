// The two readouts that make a provisioning wait legible: what is left to do,
// and how long it has been going. "2 of 5" answers neither on a real block —
// step 1 is a 10 ms `copy:` and the rest are the minutes.
import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/widgets/session_setup_progress.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/carbon_guard.dart';

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

/// The glyph on the row carrying [name], named by what it says: a status kind
/// or a plain icon. The row's state is only ever readable from its glyph and
/// its tone, so the test has to read it the same way.
({String glyph, Color? color}) _marker(WidgetTester tester, String name) {
  final row = find
      .ancestor(of: find.text(name), matching: find.byType(Row))
      .first;
  final status = find.descendant(
    of: row,
    matching: find.byType(CarbonStatusIcon),
  );
  if (status.evaluate().isNotEmpty) {
    final icon = tester.widget<CarbonStatusIcon>(status);
    return (glyph: 'status:${icon.kind.name}', color: icon.color);
  }
  final icon = tester.widget<CarbonIcon>(
    find.descendant(of: row, matching: find.byType(CarbonIcon)),
  );
  return (glyph: 'icon:${icon.icon.name}', color: icon.color);
}

Color _labelColor(WidgetTester tester, String name) =>
    tester.widget<Text>(find.text(name)).style!.color!;

CarbonColors _colors(WidgetTester tester, String name) =>
    CarbonTheme.of(tester.element(find.text(name))).colors;

void main() {
  group('SetupStepLedger', () {
    testWidgets('separates what is done from what is still to come', (
      tester,
    ) async {
      await _pumpLedger(tester, _setup('running'));
      final c = _colors(tester, 'Install dependencies');

      expect(_marker(tester, 'Copy env files').glyph, 'status:success');
      expect(_labelColor(tester, 'Copy env files'), c.textSecondary);

      expect(_marker(tester, 'Install dependencies').glyph, 'icon:inProgress');
      expect(_marker(tester, 'Install dependencies').color, c.interactive);
      // The only row at full strength: it is the one the run is on.
      expect(_labelColor(tester, 'Install dependencies'), c.textPrimary);

      expect(_marker(tester, 'Generate client').glyph, 'icon:circleDash');
      expect(_marker(tester, 'Generate client').color, c.iconDisabled);
      expect(_labelColor(tester, 'Generate client'), c.textDisabled);
    });

    testWidgets('names the step a failed run died on', (tester) async {
      await _pumpLedger(tester, _setup('failed'));
      expect(_marker(tester, 'Install dependencies').glyph, 'status:error');
      // Everything after it never ran, so nothing may report it as having.
      expect(_marker(tester, 'Generate client').glyph, 'icon:circleDash');
    });

    testWidgets('a finished run leaves no step looking in flight', (
      tester,
    ) async {
      await _pumpLedger(tester, _setup('done', stepIndex: 2));
      for (final name in _names) {
        expect(_marker(tester, name).glyph, 'status:success', reason: name);
      }
    });

    testWidgets('renders nothing when the bridge sent no names', (
      tester,
    ) async {
      // A state recovered from disk, or a bridge predating the field: a ledger
      // of blanks answers less than the progress rule already above it.
      await _pumpLedger(tester, _setup('running', stepNames: const []));
      expect(find.byType(CarbonStatusIcon), findsNothing);
      expect(find.byType(CarbonIcon), findsNothing);
    });

    // The terminal pane's provisioning column sits beside the unscoped live
    // terminal, so a scope above the ledger cannot be assumed: without its own,
    // CarbonTheme.of throws.
    testWidgets('carries its own Carbon scope and builds no Ab widget', (
      tester,
    ) async {
      await _pumpLedger(tester, _setup('running'));

      final scope = find.descendant(
        of: find.byType(SetupStepLedger),
        matching: find.byType(AbCarbonScope),
      );
      expect(scope, findsOneWidget);
      expect(abWidgetsInScope(tester, scope: scope), isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('sizes glyph and label from the Carbon theme', (tester) async {
      await _pumpLedger(tester, _setup('running'));
      final t = CarbonTheme.of(tester.element(find.text('Copy env files')));

      final glyph = tester.getSize(find.byType(CarbonStatusIcon));
      expect(glyph, Size.square(t.iconSize));
      expect(
        tester.widget<Text>(find.text('Copy env files')).style!.fontSize,
        t.typography.label.fontSize,
      );
      // One spacing03 gap between glyph and label.
      expect(
        tester.getTopLeft(find.text('Copy env files')).dx -
            tester.getTopRight(find.byType(CarbonStatusIcon)).dx,
        CarbonSpacing.spacing03,
      );
    });
  });

  group('SetupElapsed', () {
    testWidgets('says nothing about a clock it cannot trust', (tester) async {
      // `startedAt` is the BRIDGE's clock, and for a remote machine that is not
      // ours. A negative reading is the one shape of skew we can detect.
      await tester.pumpWidget(
        MaterialApp(
          home: AbCarbonScope(
            child: SetupElapsed(
              startedAt: DateTime.now().millisecondsSinceEpoch + 600000,
            ),
          ),
        ),
      );
      expect(find.byType(Text), findsNothing);
      // Unmounted by hand: the ticker is periodic, and a test that ends with
      // one pending fails the suite rather than this expectation.
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('reads in Carbon code type at the helper colour', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(extensions: const [kDefaultPalette]),
          home: AbCarbonScope(
            child: SetupElapsed(
              startedAt:
                  DateTime.now().millisecondsSinceEpoch -
                  const Duration(minutes: 2).inMilliseconds,
            ),
          ),
        ),
      );
      final t = CarbonTheme.of(tester.element(find.byType(SetupElapsed)));
      final style = tester.widget<Text>(find.byType(Text)).style!;
      expect(style.color, t.colors.textHelper);
      expect(style.fontFamily, t.typography.code.fontFamily);
      expect(style.fontSize, t.typography.code.fontSize);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
