import 'package:flutter/painting.dart';
import 'package:ghostty_vte/ghostty_vte.dart';

import 'xterm_palette_math.dart';

/// Converts a Flutter [Color] to the engine's [VtRgbColor] (8-bit channels).
VtRgbColor colorToVtRgb(Color color) => VtRgbColor(
  (color.r * 255.0).round() & 0xFF,
  (color.g * 255.0).round() & 0xFF,
  (color.b * 255.0).round() & 0xFF,
);

/// Expands a 16-entry ANSI palette into the 256-entry list the Ghostty engine
/// requires for `defaultPalette`. Indices 0-15 are the supplied ANSI colors;
/// 16-231 are the standard xterm 6x6x6 cube; 232-255 are the grayscale ramp.
List<VtRgbColor> expandAnsiToEnginePalette(List<Color> ansi) {
  if (ansi.length != 16) {
    throw ArgumentError.value(
      ansi.length, 'ansi', 'ANSI palette must contain exactly 16 colors',
    );
  }
  return List<VtRgbColor>.generate(256, (index) {
    if (index < 16) {
      return colorToVtRgb(ansi[index]);
    }
    final (r, g, b) = xtermIndexedRgb(index);
    return VtRgbColor(r, g, b);
  });
}
