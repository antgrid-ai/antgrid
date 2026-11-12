import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/models/scheduler.dart';
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
    await _pump(tester, SchedulerStatusGlyph.run('completed'));
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

  testWidgets('each run status maps to its Carbon icon indicator', (
    tester,
  ) async {
    final expected = <(String, String?), CarbonIconIndicatorKind>{
      ('preparing', null): CarbonIconIndicatorKind.inProgress,
      ('running', null): CarbonIconIndicatorKind.inProgress,
      ('needs-input', null): CarbonIconIndicatorKind.cautionMinor,
      ('completed', null): CarbonIconIndicatorKind.succeeded,
      ('failed', null): CarbonIconIndicatorKind.failed,
      ('interrupted', null): CarbonIconIndicatorKind.incomplete,
      ('skipped', null): CarbonIconIndicatorKind.notStarted,
      ('completed', 'missed'): CarbonIconIndicatorKind.notStarted,
      ('mystery', null): CarbonIconIndicatorKind.unknown,
    };
    for (final MapEntry(key: (status, trigger), value: kind)
        in expected.entries) {
      expect(
        schedulerRunIndicator(status, trigger: trigger),
        kind,
        reason: '$status/$trigger',
      );
      await _pump(tester, SchedulerStatusGlyph.run(status, trigger: trigger));
      expect(
        tester.widget<CarbonIconIndicator>(find.byType(CarbonIconIndicator)),
        isA<CarbonIconIndicator>()
            .having((i) => i.kind, 'kind', kind)
            .having((i) => i.compact, 'compact', isTrue)
            .having(
              (i) => i.label,
              'label',
              schedulerRunStatusWord(status, trigger: trigger),
            ),
      );
    }
  });

  testWidgets('schedule glyph: resting outranks a run, idle is pending', (
    tester,
  ) async {
    ScheduleRun run(String status) => ScheduleRun(
      id: 'r',
      scheduleId: 's',
      projectId: 'p',
      status: status,
      trigger: 'scheduled',
      occurrenceAt: DateTime.utc(2026),
    );
    final cases = <(ScheduleRun?, bool), CarbonIconIndicatorKind>{
      (null, false): CarbonIconIndicatorKind.pending,
      (null, true): CarbonIconIndicatorKind.notStarted,
      (run('needs-input'), true): CarbonIconIndicatorKind.notStarted,
      (run('needs-input'), false): CarbonIconIndicatorKind.cautionMinor,
      (run('running'), false): CarbonIconIndicatorKind.inProgress,
    };
    for (final MapEntry(key: (active, resting), value: kind) in cases.entries) {
      await _pump(
        tester,
        SchedulerStatusGlyph.schedule(active: active, resting: resting),
      );
      expect(
        tester
            .widget<CarbonIconIndicator>(find.byType(CarbonIconIndicator))
            .kind,
        kind,
        reason: '${active?.status} resting=$resting',
      );
    }
  });

  testWidgets('every glyph is the same size', (tester) async {
    final sizes = <Size>{};
    for (final g in <Widget>[
      SchedulerStatusGlyph.run('needs-input'),
      SchedulerStatusGlyph.run('failed'),
      SchedulerStatusGlyph.run('completed'),
      SchedulerStatusGlyph.run('running'),
      SchedulerStatusGlyph.run('skipped', trigger: 'missed'),
      SchedulerStatusGlyph.schedule(active: null, resting: true),
      SchedulerStatusGlyph.schedule(active: null, resting: false),
    ]) {
      await _pump(tester, g);
      sizes.add(tester.getSize(find.byType(SchedulerStatusGlyph)));
    }
    final side = _theme(tester).iconSize;
    expect(sizes, {Size.square(side)});
  });

  testWidgets('semantics label is exposed when given, absent otherwise', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    for (final status in ['running', 'failed']) {
      await _pump(
        tester,
        SchedulerStatusGlyph.run(status, semanticLabel: 'State'),
      );
      expect(find.bySemanticsLabel('State'), findsOneWidget);
      await _pump(tester, SchedulerStatusGlyph.run(status));
      expect(find.bySemanticsLabel('State'), findsNothing);
      expect(
        find.bySemanticsLabel(schedulerRunStatusWord(status)),
        findsNothing,
      );
    }
    handle.dispose();
  });
}
