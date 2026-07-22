import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_vte_flutter/src/engine_palette.dart';

void main() {
  group('expandAnsiToEnginePalette', () {
    final ansi16 = <Color>[
      const Color(0xFF0C0C0C), const Color(0xFFC50F1F), const Color(0xFF13A10E),
      const Color(0xFFC19C00), const Color(0xFF0037DA), const Color(0xFF881798),
      const Color(0xFF3A96DD), const Color(0xFFCCCCCC), const Color(0xFF767676),
      const Color(0xFFE74856), const Color(0xFF16C60C), const Color(0xFFF9F1A5),
      const Color(0xFF3B78FF), const Color(0xFFB4009E), const Color(0xFF61D6D6),
      const Color(0xFFF2F2F2),
    ];

    test('returns exactly 256 entries', () {
      expect(expandAnsiToEnginePalette(ansi16).length, 256);
    });

    test('first 16 entries are the Campbell ANSI colors', () {
      final p = expandAnsiToEnginePalette(ansi16);
      expect(p[1].r, 0xC5); expect(p[1].g, 0x0F); expect(p[1].b, 0x1F); // red
      expect(p[15].r, 0xF2); expect(p[15].g, 0xF2); expect(p[15].b, 0xF2); // bright white
    });

    test('cube index 16 is pure black, 231 is pure white', () {
      final p = expandAnsiToEnginePalette(ansi16);
      expect((p[16].r, p[16].g, p[16].b), (0, 0, 0));
      expect((p[231].r, p[231].g, p[231].b), (255, 255, 255));
    });

    test('cube uses xterm levels [0,95,135,175,215,255]', () {
      final p = expandAnsiToEnginePalette(ansi16);
      // index 16 + 36*1 = 52 -> red level index 1 = 95, green 0, blue 0
      expect((p[52].r, p[52].g, p[52].b), (95, 0, 0));
    });

    test('cube maps all three channels (index 110 -> 135,175,215)', () {
      final p = expandAnsiToEnginePalette(ansi16);
      // 110 = 16 + 36*2 + 6*3 + 4 -> levels[2],levels[3],levels[4]
      expect((p[110].r, p[110].g, p[110].b), (135, 175, 215));
    });

    test('grayscale ramp 232..255 is 8 + (i-232)*10', () {
      final p = expandAnsiToEnginePalette(ansi16);
      expect((p[232].r, p[232].g, p[232].b), (8, 8, 8));
      expect((p[255].r, p[255].g, p[255].b), (238, 238, 238));
    });

    test('requires 16 ansi colors', () {
      expect(() => expandAnsiToEnginePalette(const <Color>[]), throwsArgumentError);
    });
  });

  test('colorToVtRgb extracts 8-bit channels', () {
    final c = colorToVtRgb(const Color(0xFF3A96DD));
    expect((c.r, c.g, c.b), (0x3A, 0x96, 0xDD));
  });
}
