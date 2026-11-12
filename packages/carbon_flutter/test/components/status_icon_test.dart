import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

CarbonIcon _glyph(WidgetTester tester) =>
    tester.widget<CarbonIcon>(find.byType(CarbonIcon));

void main() {
  final theme = CarbonThemeData();

  testWidgets('each kind draws its filled glyph in its support colour', (
    tester,
  ) async {
    final expected = <CarbonStatusKind, (CarbonIcons, Color)>{
      CarbonStatusKind.error: (
        CarbonIcons.errorFilled,
        theme.colors.supportError,
      ),
      CarbonStatusKind.warning: (
        CarbonIcons.warningAltFilled,
        theme.colors.supportWarning,
      ),
      CarbonStatusKind.success: (
        CarbonIcons.checkmarkFilled,
        theme.colors.supportSuccess,
      ),
      CarbonStatusKind.info: (
        CarbonIcons.informationFilled,
        theme.colors.supportInfo,
      ),
    };
    for (final entry in expected.entries) {
      await pumpCarbon(tester, CarbonStatusIcon(entry.key), theme: theme);
      final icon = _glyph(tester);
      expect(icon.icon, entry.value.$1, reason: '${entry.key}');
      expect(icon.color, entry.value.$2, reason: '${entry.key}');
    }
  });

  testWidgets('the warning mark is a fixed dark, the others transparent', (
    tester,
  ) async {
    await pumpCarbon(
      tester,
      const CarbonStatusIcon(CarbonStatusKind.warning),
      theme: theme,
    );
    expect(_glyph(tester).innerColor, const Color(0xFF161616));
    for (final kind in [
      CarbonStatusKind.error,
      CarbonStatusKind.success,
      CarbonStatusKind.info,
    ]) {
      await pumpCarbon(tester, CarbonStatusIcon(kind), theme: theme);
      expect(_glyph(tester).innerColor, isNull, reason: '$kind');
    }
  });

  testWidgets('overrides replace the accent and inner mark', (tester) async {
    await pumpCarbon(
      tester,
      const CarbonStatusIcon(
        CarbonStatusKind.error,
        color: Color(0xFF123456),
        innerColor: Color(0xFF654321),
      ),
      theme: theme,
    );
    expect(_glyph(tester).color, const Color(0xFF123456));
    expect(_glyph(tester).innerColor, const Color(0xFF654321));
  });

  testWidgets('size defaults to 16 and is honoured', (tester) async {
    await pumpCarbon(
      tester,
      const Align(
        alignment: AlignmentDirectional.topStart,
        child: CarbonStatusIcon(CarbonStatusKind.info),
      ),
      theme: theme,
    );
    expect(tester.getSize(find.byType(CarbonIcon)), const Size(16, 16));
    await pumpCarbon(
      tester,
      const Align(
        alignment: AlignmentDirectional.topStart,
        child: CarbonStatusIcon(CarbonStatusKind.info, size: 24),
      ),
      theme: theme,
    );
    expect(tester.getSize(find.byType(CarbonIcon)), const Size(24, 24));
  });

  testWidgets('no label leaves it out of semantics; a label makes an image', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpCarbon(
      tester,
      const CarbonStatusIcon(CarbonStatusKind.error),
      theme: theme,
    );
    expect(find.bySemanticsLabel('Failed'), findsNothing);
    expect(
      find.descendant(
        of: find.byType(CarbonStatusIcon),
        matching: find.byType(ExcludeSemantics),
      ),
      findsWidgets,
    );
    await pumpCarbon(
      tester,
      const CarbonStatusIcon(CarbonStatusKind.error, semanticLabel: 'Failed'),
      theme: theme,
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('Failed')),
      matchesSemantics(label: 'Failed', isImage: true),
    );
    handle.dispose();
  });
}
