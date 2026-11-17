import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('contrast math', () {
    test('black on white is 21:1 and the ratio is symmetric', () {
      const black = Color(0xFF000000);
      const white = Color(0xFFFFFFFF);
      expect(CarbonContrast.contrastRatio(black, white), closeTo(21, 1e-6));
      expect(CarbonContrast.contrastRatio(white, black), closeTo(21, 1e-6));
      expect(CarbonContrast.contrastRatio(white, white), closeTo(1, 1e-9));
    });

    test('matches the published WCAG value for #767676 on white', () {
      expect(
        CarbonContrast.contrastRatio(
          const Color(0xFF767676),
          const Color(0xFFFFFFFF),
        ),
        closeTo(4.54, 0.01),
      );
    });

    test('a translucent foreground is composited over the background', () {
      const half = Color(0x80000000);
      const white = Color(0xFFFFFFFF);
      final composited = CarbonContrast.contrastRatio(half, white);
      expect(composited, lessThan(21));
      expect(
        composited,
        closeTo(
          CarbonContrast.contrastRatio(Color.alphaBlend(half, white), white),
          1e-9,
        ),
      );
    });
  });

  group('validate', () {
    final palettes = <String, CarbonColors>{
      'white': CarbonColors.white,
      'gray10': CarbonColors.gray10,
      'gray90': CarbonColors.gray90,
      'gray100': CarbonColors.gray100,
    };

    for (final entry in palettes.entries) {
      test('${entry.key} passes the documented pair list', () {
        expect(CarbonContrast.validate(entry.value), isEmpty);
      });
    }

    test('Carbon dark themes fall short only on third-layer secondary text', () {
      String key(CarbonContrastIssue i) => '${i.foreground}/${i.background}';
      final failures = {
        for (final entry in palettes.entries)
          entry.key: CarbonContrast.validate(
            entry.value,
            pairs: CarbonContrast.extendedPairs,
          ).map(key).toSet(),
      };
      expect(failures['white'], isEmpty);
      expect(failures['gray10'], isEmpty);
      const thirdLayer = {'layer03', 'field03'};
      for (final scheme in ['gray90', 'gray100']) {
        expect(failures[scheme], isNotEmpty);
        for (final failure in failures[scheme]!) {
          final parts = failure.split('/');
          expect(thirdLayer, contains(parts[1]), reason: '$scheme $failure');
          expect(parts[0], isNot('textPrimary'));
        }
      }
    });

    test('reports a low-contrast custom role with names and thresholds', () {
      final broken = CarbonColors.white.copyWith(
        textPrimary: const Color(0xFFE0E0E0),
        focus: const Color(0xFFF4F4F4),
      );
      final issues = CarbonContrast.validate(broken);
      final text = issues.firstWhere((i) => i.foreground == 'textPrimary');
      expect(text.required, 4.5);
      expect(text.ratio, lessThan(4.5));
      final focus = issues.firstWhere((i) => i.foreground == 'focus');
      expect(focus.required, 3.0);
      expect(focus.background, 'background');
    });

    test('thresholds are 4.5 for text and 3.0 for marks; exempt roles absent',
        () {
      for (final pair in CarbonContrast.pairs) {
        final isText = pair.foreground.startsWith('text');
        expect(pair.required, isText ? 4.5 : 3.0, reason: pair.foreground);
      }
      final names = CarbonContrast.pairs.map((p) => p.foreground).toSet();
      expect(names, isNot(contains('textPlaceholder')));
      expect(names, isNot(contains('textDisabled')));
      expect(names, isNot(contains('iconDisabled')));
    });
  });
}
