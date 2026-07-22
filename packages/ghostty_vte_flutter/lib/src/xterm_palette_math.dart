/// Pure xterm 256-color cube + grayscale ramp math.
///
/// Shared single source of truth for the two color paths that must never
/// drift: the engine palette expander ([expandAnsiToEnginePalette], which
/// feeds the native `renderState` render path) and the formatter-path
/// resolver ([GhosttyTerminalPalette.resolve], used for scrollback).
library;

/// xterm 6x6x6 cube intensity levels for indices 16-231.
const List<int> xtermCubeLevels = <int>[0, 95, 135, 175, 215, 255];

/// Returns the 8-bit `(r, g, b)` for an xterm 256-color index in the range
/// 16-255: indices 16-231 form the 6x6x6 color cube, 232-255 the 24-step
/// grayscale ramp. Callers must guard `index` to that range (0-15 are the
/// ANSI palette, resolved elsewhere).
(int r, int g, int b) xtermIndexedRgb(int index) {
  if (index <= 231) {
    final cube = index - 16;
    return (
      xtermCubeLevels[(cube ~/ 36) % 6],
      xtermCubeLevels[(cube ~/ 6) % 6],
      xtermCubeLevels[cube % 6],
    );
  }
  final value = 8 + (index - 232) * 10;
  return (value, value, value);
}
