import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

CarbonIcon _glyph(WidgetTester tester) =>
    tester.widget<CarbonIcon>(find.byType(CarbonIcon));

void main() {
  testWidgets('each kind draws its Carbon glyph in its status colour', (
    tester,
  ) async {
    final expected = <CarbonIconIndicatorKind, (CarbonIcons, Color, Color)>{
      CarbonIconIndicatorKind.failed: (
        CarbonIcons.errorFilled,
        const Color(0xFFDA1E28),
        const Color(0xFFFA4D56),
      ),
      CarbonIconIndicatorKind.cautionMajor: (
        CarbonIcons.warningAltInvertedFilled,
        const Color(0xFFFF832B),
        const Color(0xFFFF832B),
      ),
      CarbonIconIndicatorKind.cautionMinor: (
        CarbonIcons.warningAltFilled,
        const Color(0xFFF1C21B),
        const Color(0xFFF1C21B),
      ),
      CarbonIconIndicatorKind.undefined: (
        CarbonIcons.undefinedFilled,
        const Color(0xFF8A3FFC),
        const Color(0xFFA56EFF),
      ),
      CarbonIconIndicatorKind.succeeded: (
        CarbonIcons.checkmarkFilled,
        const Color(0xFF24A148),
        const Color(0xFF42BE65),
      ),
      CarbonIconIndicatorKind.normal: (
        CarbonIcons.checkmarkOutline,
        const Color(0xFF0043CE),
        const Color(0xFF4589FF),
      ),
      CarbonIconIndicatorKind.inProgress: (
        CarbonIcons.inProgress,
        const Color(0xFF0043CE),
        const Color(0xFF4589FF),
      ),
      CarbonIconIndicatorKind.incomplete: (
        CarbonIcons.incomplete,
        const Color(0xFF0043CE),
        const Color(0xFF4589FF),
      ),
      CarbonIconIndicatorKind.notStarted: (
        CarbonIcons.circleDash,
        const Color(0xFF6F6F6F),
        const Color(0xFF8D8D8D),
      ),
      CarbonIconIndicatorKind.pending: (
        CarbonIcons.pendingFilled,
        const Color(0xFF6F6F6F),
        const Color(0xFF8D8D8D),
      ),
      CarbonIconIndicatorKind.unknown: (
        CarbonIcons.unknownFilled,
        const Color(0xFF6F6F6F),
        const Color(0xFF8D8D8D),
      ),
      CarbonIconIndicatorKind.informative: (
        CarbonIcons.warningSquareFilled,
        const Color(0xFF0043CE),
        const Color(0xFF4589FF),
      ),
    };
    expect(expected.keys.toSet(), CarbonIconIndicatorKind.values.toSet());
    for (final (theme, dark) in [
      (CarbonThemeData(), false),
      (CarbonThemeData(scheme: CarbonThemeScheme.gray100), true),
    ]) {
      for (final entry in expected.entries) {
        await pumpCarbon(
          tester,
          CarbonIconIndicator(kind: entry.key, label: 'Status'),
          theme: theme,
        );
        final icon = _glyph(tester);
        expect(icon.icon, entry.value.$1, reason: '${entry.key}');
        expect(
          icon.color,
          dark ? entry.value.$3 : entry.value.$2,
          reason: '${entry.key} dark=$dark',
        );
      }
    }
  });

  testWidgets('caution marks are black; other inner marks stay clear', (
    tester,
  ) async {
    for (final kind in CarbonIconIndicatorKind.values) {
      await pumpCarbon(tester, CarbonIconIndicator(kind: kind, label: 'S'));
      final caution =
          kind == CarbonIconIndicatorKind.cautionMajor ||
          kind == CarbonIconIndicatorKind.cautionMinor;
      expect(
        _glyph(tester).innerColor,
        caution ? const Color(0xFF000000) : isNull,
        reason: '$kind',
      );
    }
  });

  testWidgets('every kind is the same size, 16 compact and 20 touch', (
    tester,
  ) async {
    for (final (density, side) in [
      (CarbonDensity.compact, 16.0),
      (CarbonDensity.touch, 20.0),
    ]) {
      for (final kind in CarbonIconIndicatorKind.values) {
        await pumpCarbon(
          tester,
          CarbonIconIndicator(kind: kind, label: 'S'),
          theme: CarbonThemeData(density: density),
        );
        expect(
          tester.getSize(find.byType(CarbonIcon)),
          Size.square(side),
          reason: '$kind $density',
        );
      }
    }
  });

  testWidgets('the label is secondary text beside the glyph', (tester) async {
    await pumpCarbon(
      tester,
      const CarbonIconIndicator(
        kind: CarbonIconIndicatorKind.succeeded,
        label: 'Completed',
      ),
    );
    final theme = CarbonTheme.of(tester.element(find.text('Completed')));
    final text = tester.widget<Text>(find.text('Completed'));
    expect(text.style!.color, theme.colors.textSecondary);
    expect(text.style!.fontSize, theme.typography.control.fontSize);
    expect(
      tester.getRect(find.byType(CarbonIcon)).right +
          CarbonSpacing.spacing03,
      moreOrLessEquals(tester.getRect(find.text('Completed')).left),
    );
  });

  testWidgets('the label names it; compact moves the label to a tooltip', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpCarbon(
      tester,
      const CarbonIconIndicator(
        kind: CarbonIconIndicatorKind.failed,
        label: 'Failed',
      ),
    );
    expect(find.bySemanticsLabel('Failed'), findsOneWidget);

    await pumpCarbon(
      tester,
      const CarbonIconIndicator(
        kind: CarbonIconIndicatorKind.failed,
        label: 'Failed',
        compact: true,
      ),
    );
    expect(find.text('Failed'), findsNothing);
    expect(find.byType(CarbonTooltip), findsOneWidget);
    expect(
      tester.getSemantics(find.byType(CarbonIcon)),
      isSemantics(label: 'Failed', isImage: true),
    );
    handle.dispose();
  });
}
