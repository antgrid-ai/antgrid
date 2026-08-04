import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/design/ab_tokens.dart';

double _advanceOf(TextStyle style) {
  final painter = TextPainter(
    text: TextSpan(text: 'W', style: style),
    textDirection: TextDirection.ltr,
  )..layout();
  return painter.width;
}

void main() {
  // The asset-bundle reads below need a binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  // activeWeightOffset is a mutable global that AbTextDensity drives from the
  // ambient DPR. Tests set it directly, so restore it or the bumped weight
  // leaks into every later test in the same shard.
  tearDown(() => AbTokens.activeWeightOffset = 0);

  // These drive activeWeightOffset directly, so they cover the machinery, not
  // whether it currently fires: AbTokens.lowDprThreshold is 0, which means no
  // display turns the bump on. They exist so re-enabling it stays a one-constant
  // change rather than a rediscovery of why 0.45 rounded away to nothing.
  group('low-DPI weight bump', () {
    test('bumps a full master step, not a fraction that rounds away', () {
      AbTokens.activeWeightOffset = 1;
      // The regression this guards: bumpStrength was 0.45, and _bump rounds
      // (offset * strength) to whole FontWeight steps — so it resolved to 0
      // and the bump silently did nothing on every platform. Any strength
      // below 0.5 reintroduces that, which is only safe on a variable face.
      expect(
        AbTokens.monoStyle(fontSize: AbTokens.fontBody).fontWeight,
        FontWeight.w500,
      );
      expect(
        AbTokens.sansStyle(fontSize: AbTokens.fontBody).fontWeight,
        FontWeight.w500,
      );
    });

    test('leaves hi-DPI text at its designed weight', () {
      AbTokens.activeWeightOffset = 0;
      expect(
        AbTokens.monoStyle(fontSize: AbTokens.fontBody).fontWeight,
        FontWeight.w400,
      );
      expect(
        AbTokens.monoStyle(fontSize: AbTokens.fontBody).fontVariations,
        isNull,
      );
    });

    test('never bumps micro text, where heavier strokes merge', () {
      AbTokens.activeWeightOffset = 1;
      expect(
        AbTokens.monoStyle(fontSize: AbTokens.minBumpFontSize).fontWeight,
        FontWeight.w400,
      );
    });

    test('bumpedWeight matches what monoStyle resolves to', () {
      // The terminal paints through its own TextPainters and takes weights via
      // this helper instead of monoStyle. If the two ever diverge, chrome and
      // the terminal drift apart on low-DPI displays — which is the exact bug
      // this helper was added to fix.
      for (final offset in [0, 1]) {
        AbTokens.activeWeightOffset = offset;
        for (final w in [FontWeight.w400, FontWeight.w700]) {
          expect(
            AbTokens.bumpedWeight(w, AbTokens.fontBody),
            AbTokens.monoStyle(
              fontSize: AbTokens.fontBody,
              fontWeight: w,
            ).fontWeight,
            reason: 'offset $offset, weight $w',
          );
        }
      }
    });

    test('bumpedWeight keeps bold distinguishable from normal', () {
      AbTokens.activeWeightOffset = 1;
      final normal = AbTokens.bumpedWeight(FontWeight.w400, AbTokens.fontBody);
      final bold = AbTokens.bumpedWeight(FontWeight.w700, AbTokens.fontBody);
      // SGR bold has to stay visibly heavier than a bumped normal cell, or
      // raising the base weight silently erases the bold/normal distinction.
      expect(bold.value, greaterThan(normal.value));
    });

    test('the rounded weight and the wght axis ask for the same thing', () {
      // A static face takes _bump's weight and ignores fontVariations; a
      // variable fallback takes the axis. They must not disagree.
      AbTokens.activeWeightOffset = 1;
      final style = AbTokens.sansStyle(fontSize: AbTokens.fontBody);
      final wght = style.fontVariations!.firstWhere((v) => v.axis == 'wght');
      expect(wght.value, style.fontWeight!.value.toDouble());
    });
  });

  // flutter_test paints every family with its own test font and never
  // registers the pubspec ones, so these can't prove the engine resolves
  // AbTokens.fontMono at runtime — only a real build shows that. What they do
  // cover is the failure that actually happens: a pubspec path drifting from
  // the files on disk, which would fall back silently everywhere, including
  // the terminal cell grid (it measures 'W' to size its cells).
  group('bundled mono assets', () {
    const declared = [
      'assets/fonts/JetBrainsMonoNL-Regular.ttf',
      'assets/fonts/JetBrainsMonoNL-Italic.ttf',
      'assets/fonts/JetBrainsMonoNL-Medium.ttf',
      'assets/fonts/JetBrainsMonoNL-MediumItalic.ttf',
      'assets/fonts/JetBrainsMonoNL-Bold.ttf',
      'assets/fonts/JetBrainsMonoNL-BoldItalic.ttf',
    ];

    for (final path in declared) {
      test('$path is bundled and is TrueType', () async {
        final data = await rootBundle.load(path);
        // 0x00010000 is the TrueType sfnt version; catches a placeholder or
        // an LFS pointer checked in where the font should be.
        expect(data.getUint32(0), 0x00010000, reason: '$path is not a TTF');
      });
    }

    test('the declared regular face is monospaced at JetBrains Mono metrics', () async {
      const family = 'JetBrainsMonoNLUnderTest';
      await (FontLoader(family)
            ..addFont(rootBundle.load(declared.first)))
          .load();

      const size = 40.0;
      const style = TextStyle(fontFamily: family, fontSize: size);
      final advance = _advanceOf(style);
      // JetBrains Mono advances 600/1000 em. A full em would mean the loader
      // silently fell through to the test font.
      expect(advance, closeTo(size * 0.6, 1.0));

      for (final glyph in ['i', 'M', '.', '0', '@']) {
        final painter = TextPainter(
          text: TextSpan(text: glyph, style: style),
          textDirection: TextDirection.ltr,
        )..layout();
        expect(painter.width, closeTo(advance, 0.01), reason: 'glyph "$glyph"');
      }
    });

    test('the OFL licence ships with the faces', () async {
      final licence = await rootBundle.loadString('assets/fonts/OFL.txt');
      expect(licence, contains('SIL OPEN FONT LICENSE'));
    });
  });
}
