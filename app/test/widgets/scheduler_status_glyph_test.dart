import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/widgets/scheduler/scheduler_format.dart';
import 'package:antgrid/widgets/scheduler/scheduler_status_glyph.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(WidgetTester tester, Widget glyph) => tester.pumpWidget(
  MaterialApp(
    theme: buildAbTheme(),
    home: Scaffold(
      body: AbCarbonScope(child: Center(child: glyph)),
    ),
  ),
);

CarbonThemeData _theme(WidgetTester tester) =>
    CarbonTheme.of(tester.element(find.byType(SchedulerStatusGlyph)));

BoxDecoration _dot(WidgetTester tester) {
  final box = tester.widget<DecoratedBox>(
    find.descendant(
      of: find.byType(SchedulerStatusGlyph),
      matching: find.byType(DecoratedBox),
    ),
  );
  return box.decoration as BoxDecoration;
}

void main() {
  test('waiting text is support yellow only where it can be read', () {
    for (final scheme in CarbonThemeScheme.values) {
      final t = CarbonThemeData(scheme: scheme);
      expect(
        schedulerAttentionTextColor(t),
        scheme.brightness == Brightness.dark
            ? t.colors.supportWarning
            : t.colors.textPrimary,
        reason: scheme.name,
      );
    }
  });

  testWidgets('tone colours map to Carbon support colours', (tester) async {
    await _pump(tester, const SchedulerStatusGlyph.run(SchedulerRunTone.muted));
    final t = _theme(tester);
    expect(
      schedulerCarbonToneColor(t, SchedulerRunTone.active),
      t.colors.supportInfo,
    );
    expect(
      schedulerCarbonToneColor(t, SchedulerRunTone.attention),
      t.colors.supportWarning,
    );
    expect(
      schedulerCarbonToneColor(t, SchedulerRunTone.warning),
      t.colors.supportWarning,
    );
    expect(
      schedulerCarbonToneColor(t, SchedulerRunTone.success),
      t.colors.supportSuccess,
    );
    expect(
      schedulerCarbonToneColor(t, SchedulerRunTone.error),
      t.colors.supportError,
    );
    expect(
      schedulerCarbonToneColor(t, SchedulerRunTone.muted),
      t.colors.iconSecondary,
    );
  });

  testWidgets('attention and error use Carbon status icons', (tester) async {
    await _pump(
      tester,
      const SchedulerStatusGlyph.run(SchedulerRunTone.attention),
    );
    expect(
      tester.widget<CarbonStatusIcon>(find.byType(CarbonStatusIcon)).kind,
      CarbonStatusKind.warning,
    );
    await _pump(tester, const SchedulerStatusGlyph.run(SchedulerRunTone.error));
    expect(
      tester.widget<CarbonStatusIcon>(find.byType(CarbonStatusIcon)).kind,
      CarbonStatusKind.error,
    );
  });

  testWidgets('active, success and muted runs are filled dots', (tester) async {
    for (final tone in [
      SchedulerRunTone.active,
      SchedulerRunTone.success,
      SchedulerRunTone.muted,
    ]) {
      await _pump(tester, SchedulerStatusGlyph.run(tone));
      expect(find.byType(CarbonStatusIcon), findsNothing);
      expect(_dot(tester).color, schedulerCarbonToneColor(_theme(tester), tone));
    }
  });

  testWidgets('warning run is an outlined warning dot', (tester) async {
    await _pump(
      tester,
      const SchedulerStatusGlyph.run(SchedulerRunTone.warning),
    );
    expect(_dot(tester).color, isNull);
    expect(
      (_dot(tester).border! as Border).top.color,
      _theme(tester).colors.supportWarning,
    );
  });

  testWidgets('resting schedule is an outlined disabled circle', (
    tester,
  ) async {
    await _pump(
      tester,
      SchedulerStatusGlyph.schedule(active: null, resting: true),
    );
    expect(_dot(tester).color, isNull);
    expect(
      (_dot(tester).border! as Border).top.color,
      _theme(tester).colors.iconDisabled,
    );
  });

  testWidgets('idle schedule is a filled secondary dot', (tester) async {
    await _pump(
      tester,
      SchedulerStatusGlyph.schedule(active: null, resting: false),
    );
    expect(_dot(tester).color, _theme(tester).colors.iconSecondary);
  });

  testWidgets('footprint is constant across glyphs', (tester) async {
    final sizes = <Size>{};
    for (final g in <Widget>[
      const SchedulerStatusGlyph.run(SchedulerRunTone.attention),
      const SchedulerStatusGlyph.run(SchedulerRunTone.error),
      const SchedulerStatusGlyph.run(SchedulerRunTone.active),
      const SchedulerStatusGlyph.run(SchedulerRunTone.warning),
      SchedulerStatusGlyph.schedule(active: null, resting: true),
    ]) {
      await _pump(tester, g);
      sizes.add(tester.getSize(find.byType(SchedulerStatusGlyph)));
    }
    expect(sizes, {const Size(16, 16)});
  });

  testWidgets('semantics label is exposed when given, absent otherwise', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    for (final tone in [SchedulerRunTone.active, SchedulerRunTone.error]) {
      await _pump(
        tester,
        SchedulerStatusGlyph.run(tone, semanticLabel: 'State'),
      );
      expect(find.bySemanticsLabel('State'), findsOneWidget);
      await _pump(tester, SchedulerStatusGlyph.run(tone));
      expect(find.bySemanticsLabel('State'), findsNothing);
    }
    handle.dispose();
  });
}
