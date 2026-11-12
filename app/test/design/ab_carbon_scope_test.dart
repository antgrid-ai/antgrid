import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/design/ab_tokens.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(
  WidgetTester tester, {
  CarbonDensity? density,
  required void Function(CarbonThemeData) onTheme,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: AbCarbonScope(
            density: density,
            child: Builder(
              builder: (context) {
                onTheme(CarbonTheme.of(context));
                return SizedBox(
                  width: 300,
                  child: CarbonTextInput(
                    key: const ValueKey('field'),
                    placeholder: 'Name',
                  ),
                );
              },
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('mobile: a Carbon field is 44 high with 17px text', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      late CarbonThemeData theme;
      await _pump(tester, onTheme: (t) => theme = t);
      expect(theme.touchTarget, 44);
      expect(theme.typography.control.fontSize, AbTokens.appleBody);
      expect(theme.typography.control.fontSize, 17);
      final field = tester.getSize(find.byKey(const ValueKey('field')));
      final box = tester.getSize(find.byType(TextField));
      expect(box.height, lessThanOrEqualTo(44));
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText))
            .style
            .fontSize,
        17,
      );
      expect(field.height, greaterThanOrEqualTo(44));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('touch scale follows Apple text styles on any platform', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      late CarbonThemeData theme;
      await _pump(tester, density: CarbonDensity.touch, onTheme: (t) => theme = t);
      final t = theme.typography;
      expect((t.label.fontSize, t.label.height! * t.label.fontSize!), (15, 20));
      expect((t.helper.fontSize, t.helper.height! * t.helper.fontSize!), (13, 18));
      expect((t.body.fontSize, t.body.height! * t.body.fontSize!), (17, 22));
      expect(t.heading.fontWeight, FontWeight.w600);
      expect(t.headingLarge.fontSize, 20);
      expect(t.title.fontSize, 28);
      expect(t.code.fontSize, 15);
      expect(t.code.fontFamily, endsWith(CarbonTypography.monoFamily));
      expect(t.body.fontFamily, endsWith(CarbonTypography.sansFamily));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('desktop: compact density keeps Carbon defaults', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      late CarbonThemeData theme;
      await _pump(tester, onTheme: (t) => theme = t);
      expect(theme.density, CarbonDensity.compact);
      expect(theme.typography.control.fontSize, 14);
      expect(tester.getSize(find.byType(TextField)).height, lessThanOrEqualTo(32));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
