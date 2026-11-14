import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/widgets/carbon_code_style.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/carbon_guard.dart';

Future<CarbonCodeStyle> _pumpStyle(
  WidgetTester tester, {
  Brightness brightness = Brightness.light,
  CarbonDensity density = CarbonDensity.compact,
  double textScale = 1.0,
  String? paintLine,
}) async {
  late CarbonCodeStyle style;
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      // A re-pump with a new brightness would otherwise lerp the theme and
      // still read the old one after a single frame.
      themeAnimationDuration: Duration.zero,
      builder: (context, app) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: app!,
      ),
      home: AbCarbonScope(
        density: density,
        child: Scaffold(
          body: Builder(
            builder: (context) {
              style = CarbonCodeStyle.of(context);
              return paintLine == null
                  ? const SizedBox()
                  : Text.rich(
                      CarbonLineHighlighter.forPath('a.dart')!.span(
                        paintLine,
                        style,
                      ),
                    );
            },
          ),
        ),
      ),
    ),
  );
  return style;
}

void main() {
  testWidgets('text is IBM Plex Mono at the app code size per density', (
    tester,
  ) async {
    for (final density in CarbonDensity.values) {
      final style = await _pumpStyle(tester, density: density);
      expect(style.text.fontFamily, contains('IBM Plex Mono'));
      expect(
        style.text.fontSize,
        density == CarbonDensity.touch ? 13.0 : 12.0,
      );
      expect(style.text.height, 1.4);
    }
    expect(abWidgetsInScope(tester), isEmpty);
  });

  for (final brightness in Brightness.values) {
    testWidgets('palette follows the scope, ${brightness.name}', (
      tester,
    ) async {
      final style = await _pumpStyle(tester, brightness: brightness);
      final colors = CarbonThemeData.forBrightness(brightness).colors;

      expect(style.text.color, colors.textPrimary);
      expect(style.highlightTheme['keyword']!.color, colors.linkPrimary);
      expect(style.highlightTheme['string']!.color, colors.supportError);
      final light = brightness == Brightness.light;
      expect(
        style.highlightTheme['number']!.color,
        light ? colors.supportInfo : colors.supportSuccess,
      );
      expect(
        style.highlightTheme['selector-tag']!.color,
        light ? colors.supportCautionUndefined : colors.supportCautionMajor,
      );
      expect(style.highlightTheme['comment']!.color, colors.textSecondary);
      expect(style.highlightTheme['comment']!.fontStyle, FontStyle.italic);
      for (final entry in style.highlightTheme.entries) {
        expect(
          entry.value.backgroundColor,
          isNull,
          reason: '${entry.key} must not paint over the diff row tint',
        );
      }
      expect(abWidgetsInScope(tester), isEmpty);
    });
  }

  testWidgets('light and dark palettes differ', (tester) async {
    final light = await _pumpStyle(tester);
    final dark = await _pumpStyle(tester, brightness: Brightness.dark);

    expect(light, isNot(dark));
    expect(
      light.highlightTheme['keyword']!.color,
      isNot(dark.highlightTheme['keyword']!.color),
    );
  });

  testWidgets('equal inputs give equal styles', (tester) async {
    final a = await _pumpStyle(tester);
    final b = await _pumpStyle(tester);

    expect(a, b);
    expect(a.hashCode, b.hashCode);
  });

  testWidgets('line height scales with the text scaler like a laid-out line', (
    tester,
  ) async {
    for (final scale in [1.0, 1.5, 2.0]) {
      final style = await _pumpStyle(tester, textScale: scale);
      final scaler = TextScaler.linear(scale);
      final painter = TextPainter(
        text: TextSpan(text: 'x', style: style.text),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout();
      addTearDown(painter.dispose);

      expect(
        style.lineHeight(scaler),
        closeTo(painter.preferredLineHeight, 0.5),
      );
    }
  });

  testWidgets('highlighter colours code and renders at 2.0 text scale', (
    tester,
  ) async {
    final style = await _pumpStyle(
      tester,
      textScale: 2.0,
      paintLine: 'final x = 42; // note',
    );

    expect(tester.takeException(), isNull);
    final span = CarbonLineHighlighter.forPath('a.dart')!.span(
      'final x = 42; // note',
      style,
    );
    final colours = <Color?>{};
    span.visitChildren((s) {
      if (s is TextSpan) colours.add(s.style?.color);
      return true;
    });
    expect(colours, contains(style.highlightTheme['keyword']!.color));
    expect(colours, contains(style.highlightTheme['comment']!.color));
    expect(abWidgetsInScope(tester), isEmpty);
  });

  testWidgets('highlighter is null for an unknown extension and caches spans', (
    tester,
  ) async {
    final style = await _pumpStyle(tester);

    expect(CarbonLineHighlighter.forPath('notes.unknownext'), isNull);
    expect(CarbonLineHighlighter.forPath(null), isNull);

    final highlighter = CarbonLineHighlighter.forPath('main.dart')!;
    final first = highlighter.span('int a = 1;', style);
    expect(identical(highlighter.span('int a = 1;', style), first), isTrue);

    final dark = await _pumpStyle(tester, brightness: Brightness.dark);
    expect(identical(highlighter.span('int a = 1;', dark), first), isFalse);

    final darkAgain = await _pumpStyle(tester, brightness: Brightness.dark);
    final repinned = highlighter.span('int a = 1;', darkAgain);
    expect(identical(highlighter.span('int a = 1;', darkAgain), repinned), isTrue);
  });
}
