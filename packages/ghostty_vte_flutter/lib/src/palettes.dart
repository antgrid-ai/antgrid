import 'package:flutter/painting.dart';

import 'terminal_snapshot.dart';

/// The 16 ANSI colors (indices 0-15) of Windows Terminal's default **Campbell**
/// scheme, in order: black, red, green, yellow, blue, magenta, cyan, white,
/// then the eight bright variants. Shared single source of truth so the app and
/// the color-parity test resolve against an identical palette.
const List<Color> campbellAnsi = <Color>[
  Color(0xFF0C0C0C), // black
  Color(0xFFC50F1F), // red
  Color(0xFF13A10E), // green
  Color(0xFFC19C00), // yellow
  Color(0xFF0037DA), // blue
  Color(0xFF881798), // magenta
  Color(0xFF3A96DD), // cyan
  Color(0xFFCCCCCC), // white
  Color(0xFF767676), // bright black
  Color(0xFFE74856), // bright red
  Color(0xFF16C60C), // bright green
  Color(0xFFF9F1A5), // bright yellow
  Color(0xFF3B78FF), // bright blue
  Color(0xFFB4009E), // bright magenta
  Color(0xFF61D6D6), // bright cyan
  Color(0xFFF2F2F2), // bright white
];

/// Campbell's default foreground (#CCCCCC).
const Color campbellForeground = Color(0xFFCCCCCC);

/// Campbell ANSI colors wrapped as a [GhosttyTerminalPalette].
const GhosttyTerminalPalette campbellPalette =
    GhosttyTerminalPalette(ansi: campbellAnsi);
