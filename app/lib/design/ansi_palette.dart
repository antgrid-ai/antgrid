/// ANSI palettes tuned for Antgrid's terminal backgrounds.
///
/// The renderer enforces a 4.5:1 minimum contrast floor per cell, which alone
/// makes stock Campbell readable — but the floor sees one color at a time and
/// only moves lightness, so any two colors that both fail get pushed into the
/// same lightness band. On Campbell that collapsed normal/bright pairs: black
/// and bright-black rendered as the *identical* value on every dark preset,
/// and blue/bright-blue landed 2.2 apart in Lab (below the ~2.3 just-noticeable
/// threshold). TUIs use that distinction as a semantic channel, so losing it
/// costs real information.
///
/// A palette can satisfy the joint constraint the floor structurally cannot:
/// pick 16 colors that already clear the floor *and* stay separated. These are
/// derived by holding each Campbell color's hue and saturation and solving for
/// lightness against three bounds simultaneously:
///
///  - >= 4.5:1 on the lightest background it must serve, which implies every
///    darker one (contrast against a light-on-dark pairing only grows as the
///    background darkens);
///  - <= 15:1 on the darkest — past roughly that, high-luminance glyphs bloom
///    into the surround on a dark background, the same ceiling the chrome
///    palette is held to in theme_presets.dart;
///  - >= 12 Lab distance between each normal/bright pair.
///
/// The floor stays on regardless. TUIs paint their own cell backgrounds, and no
/// static palette can guarantee contrast against an arbitrary one; a tuned
/// palette only means the floor rarely fires against the *default* background,
/// which is exactly the case where it fired uniformly and did the damage above.
library;

import 'package:flutter/painting.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';

/// Dark-background ANSI colors. Solved against zinc (#1B1B1B, the lightest dark
/// preset) for the floor and slate (#0B0F1A, the darkest non-exempt one) for the
/// ceiling. Onyx is excluded from the ceiling solve on purpose: it is the
/// deliberate maximum-contrast escape hatch, the same exemption the chrome
/// palette test grants it.
const List<Color> kAnsiDark = <Color>[
  // Index 0 keeps Campbell's near-black and is exempt from the floor solve: it
  // is the canonical *background* color (status bars, reverse video), and
  // lifting it to a readable gray would wreck every TUI that fills a bar with
  // it. Black-as-foreground stays the renderer floor's job — which means it
  // still converges on bright-black. That collision is inherent to a 16-color
  // palette serving both roles, not something a different value here fixes.
  Color(0xFF0C0C0C), // black
  Color(0xFFF03E4D), // red
  Color(0xFF13A10E), // green
  Color(0xFFC19C00), // yellow
  Color(0xFF4C7AFF), // blue
  Color(0xFFCE42E2), // magenta
  Color(0xFF3A96DD), // cyan
  Color(0xFFCCCCCC), // white
  Color(0xFF838383), // bright black
  Color(0xFFE8525F), // bright red
  Color(0xFF16C60C), // bright green
  Color(0xFFF4E661), // bright yellow
  Color(0xFF568BFF), // bright blue
  Color(0xFFED00D0), // bright magenta
  Color(0xFF61D6D6), // bright cyan
  // The ceiling binds here: Campbell's #F2F2F2 reads 18.8:1 on onyx and 16.5:1
  // on slate. Pulling it under 15:1 leaves only ~8 Lab from white above, short
  // of the 12 the other pairs hold. White cannot follow it down without
  // diverging from the default foreground, which Campbell defines as the same
  // color. Squeezed on purpose; bright-white vs white is subtle in most schemes.
  Color(0xFFE3E3E3), // bright white
];

/// Default foreground for [kAnsiDark] — Campbell's own, which is also index 7.
/// Keep the two in lockstep: unstyled text and SGR 37 rendering at different
/// brightnesses reads as a bug.
const Color kAnsiForegroundDark = Color(0xFFCCCCCC);

/// Light-background ANSI colors, solved against the light preset (#FAFAFA).
///
/// Roles invert. On a light background indices 7 and 15 are the canonical
/// backgrounds, so they keep Campbell's values and are exempt from the floor
/// the way index 0 is on dark; everything else darkens to meet it. Bright
/// variants sit *lighter* than their normal counterparts here — lower contrast
/// against a pale background is what "bright" has to mean — which is why the
/// bright yellows and cyans read as olive and teal rather than as tints.
///
/// No ceiling applies: halation is a light-on-dark effect.
const List<Color> kAnsiLight = <Color>[
  Color(0xFF0C0C0C), // black
  Color(0xFFB90E1D), // red
  Color(0xFF0D6F0A), // green
  Color(0xFF725C00), // yellow
  Color(0xFF0037DA), // blue
  Color(0xFF881798), // magenta
  Color(0xFF2078BB), // cyan
  Color(0xFFCCCCCC), // white
  Color(0xFF737373), // bright black
  Color(0xFFE21E30), // bright red
  Color(0xFF0F8608), // bright green
  Color(0xFF807509), // bright yellow
  Color(0xFF2367FF), // bright blue
  Color(0xFFB4009E), // bright magenta
  Color(0xFF218080), // bright cyan
  Color(0xFFF2F2F2), // bright white
];

/// Default foreground for [kAnsiLight]. Not index 7 — on a light background the
/// white-as-background exemption above means index 7 is unreadable as text.
const Color kAnsiForegroundLight = Color(0xFF1F2124);

const GhosttyTerminalPalette kAnsiPaletteDark = GhosttyTerminalPalette(
  ansi: kAnsiDark,
);
const GhosttyTerminalPalette kAnsiPaletteLight = GhosttyTerminalPalette(
  ansi: kAnsiLight,
);

/// Threshold on background luminance for picking between the two palettes.
///
/// Every shipped dark preset sits below 0.012 and the light preset above 0.95,
/// so the exact value only matters for a custom palette with a mid-tone
/// background. 0.18 is sRGB middle gray: above it, dark-on-light serves better.
/// Mid-tone backgrounds are where neither palette is a good fit and the
/// renderer floor does the work.
const double _lightBackgroundThreshold = 0.18;

/// The ANSI palette to render against [background].
GhosttyTerminalPalette ansiPaletteFor(Color background) =>
    background.computeLuminance() > _lightBackgroundThreshold
    ? kAnsiPaletteLight
    : kAnsiPaletteDark;

/// The default terminal foreground to pair with [ansiPaletteFor]'s result.
Color ansiForegroundFor(Color background) =>
    background.computeLuminance() > _lightBackgroundThreshold
    ? kAnsiForegroundLight
    : kAnsiForegroundDark;
