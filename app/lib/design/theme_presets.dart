import 'package:flutter/material.dart';

import 'ab_colors.dart';

enum AbThemePreset { antgrid, light, zinc, slate, onyx, midnight, custom }

/// Antgrid — refined dark IDE palette (Vercel/Linear class).
/// Six-step surface ramp, off-white accent, muted agent-state palette.
///
/// The ramp floor sits at #16181A, not near-black, and textPrimary lands at
/// ~13:1 rather than the ~18:1 a near-white-on-near-black pairing gives. Both
/// clear AA comfortably; the ceiling is the point. Past roughly 15:1 on a dark
/// background, high-luminance glyphs bloom into the surround and long reading
/// sessions fatigue — the palette is tuned for the 10-13:1 band that terminal
/// UIs converge on, not for the top of the range. Raising textPrimary or
/// dropping the ramp floor back toward black will pass every test and still
/// undo this. Surface steps preserve the original per-channel deltas, so the
/// layer separation is unchanged.
const _antgrid = AbColors(
  bgDeepest: Color(0xFF16181A),
  bgDeep: Color(0xFF1C1E21),
  bgSurface: Color(0xFF212427),
  bgElevated: Color(0xFF26292D),
  // Antgrid aliases bg-3 (raised) to bgElevated — they're the same surface.
  bgRaised: Color(0xFF26292D),
  bgHover: Color(0xFF2D3136),
  bgPressed: Color(0xFF35393F),
  bgSelected: Color(0xFF32363B),
  borderSubtle: Color(0x12FFFFFF),
  borderDefault: Color(0x16FFFFFF),
  borderStrong: Color(0x29FFFFFF),
  // accent stays at the old textPrimary (#F5F6F7); now that body text sits
  // below it, the off-white accent has headroom to read as emphasis.
  textPrimary: Color(0xFFDEDFE1),
  textSecondary: Color(0xFFB6B8BC),
  textMuted: Color(0xFF8B8F96),
  // 3:1 non-text tier (SC 1.4.11) for icons/glyphs — see AbColors.iconMuted.
  iconMuted: Color(0xFF6F737B),
  textDisabled: Color(0xFF6A6E76),
  accent: Color(0xFFF5F6F7),
  accentHighlight: Color(0xFFFFFFFF),
  accentMuted: Color(0xFFD7D9DC),
  accentForeground: Color(0xFF0A0B0C),
  statusIdle: Color(0xFF61656D),
  statusThinking: Color(0xFFE2C792),
  statusRunning: Color(0xFF8FCFAE),
  statusAttention: Color(0xFFE5A055),
  success: Color(0xFF8FCFAE),
  error: Color(0xFFE5746A),
  warning: Color(0xFFE5A055),
  signalMut: Color(0xFFE2C792),
  gitUntracked: Color(0xFF6FC2B0),
  gitConflict: Color(0xFFE56A96),
);

/// Default: neutral grayscale terminal palette.
/// bg #1b1b1b, text #cfcfcf, primary/accent #c6c6c6.
///
/// Same contrast-ceiling reasoning as [_antgrid]: body text lands at ~10:1,
/// the band VS Code and other terminal UIs sit in, rather than the top of the
/// AA range. Surface steps preserve the original per-channel deltas.
const _zinc = AbColors(
  bgDeepest: Color(0xFF1B1B1B),
  bgDeep: Color(0xFF1B1B1B),
  bgSurface: Color(0xFF212121),
  bgElevated: Color(0xFF2B2B2B),
  bgRaised: Color(0xFF2B2B2B),
  bgHover: Color(0xFF313131),
  bgPressed: Color(0xFF3A3A3A),
  bgSelected: Color(0xFF363636),
  borderSubtle: Color(0xFF272727),
  borderDefault: Color(0xFF2B2B2B),
  borderStrong: Color(0xFF3F3F3F),
  textPrimary: Color(0xFFCFCFCF),
  textSecondary: Color(0xFFA6A6A6),
  // Floor for WCAG AA (>= 4.5:1) on bgSurface — see palette_contrast_test.
  // Tracks bgSurface: the old #858585 was the floor against #1A1A1A and falls
  // under AA now that the surface is lighter.
  textMuted: Color(0xFF8B8B8B),
  // 3:1 non-text tier (SC 1.4.11) for icons/glyphs — see AbColors.iconMuted.
  iconMuted: Color(0xFF717171),
  textDisabled: Color(0xFF545454),
  accent: Color(0xFFC6C6C6),
  accentHighlight: Color(0xFFE0E0E0),
  accentMuted: Color(0xFF8F8F8F),
  accentForeground: Color(0xFF09090B),
  statusIdle: Color(0xFF61656D),
  statusThinking: Color(0xFFE2C792),
  statusRunning: Color(0xFF8FCFAE),
  statusAttention: Color(0xFFE5A055),
  success: Color(0xFF22C55E),
  error: Color(0xFFF87171),
  warning: Color(0xFFFACC15),
  signalMut: Color(0xFFC6C6C6),
  gitUntracked: Color(0xFF2DD4BF),
  gitConflict: Color(0xFFFB7185),
);

/// Cooler blue-tinted grays.
const _slate = AbColors(
  bgDeepest: Color(0xFF0B0F1A),
  bgDeep: Color(0xFF0E1320),
  bgSurface: Color(0xFF161D2E),
  bgElevated: Color(0xFF1F2A3E),
  bgRaised: Color(0xFF1F2A3E),
  bgHover: Color(0xFF26334D),
  bgPressed: Color(0xFF2F3D5C),
  bgSelected: Color(0xFF2A3754),
  borderSubtle: Color(0xFF202A3D),
  borderDefault: Color(0xFF263247),
  borderStrong: Color(0xFF3B4A66),
  textPrimary: Color(0xFFE2E8F0),
  textSecondary: Color(0xFF94A3B8),
  // Between slate-400/500 — slate-500 lands 3.5:1 on bgSurface, below AA.
  textMuted: Color(0xFF7C8CA2),
  // 3:1 non-text tier (SC 1.4.11) for icons/glyphs — see AbColors.iconMuted.
  iconMuted: Color(0xFF5F6F86),
  textDisabled: Color(0xFF475569),
  accent: Color(0xFF38BDF8),
  accentHighlight: Color(0xFF7DD3FC),
  accentMuted: Color(0xFF0EA5E9),
  accentForeground: Color(0xFF09090B),
  statusIdle: Color(0xFF61656D),
  statusThinking: Color(0xFFE2C792),
  statusRunning: Color(0xFF8FCFAE),
  statusAttention: Color(0xFFE5A055),
  success: Color(0xFF22C55E),
  error: Color(0xFFF87171),
  warning: Color(0xFFFACC15),
  signalMut: Color(0xFFC084FC),
  gitUntracked: Color(0xFF2DD4BF),
  gitConflict: Color(0xFFFB7185),
);

/// Near-black, high-contrast.
const _onyx = AbColors(
  bgDeepest: Color(0xFF000000),
  bgDeep: Color(0xFF050505),
  bgSurface: Color(0xFF0F0F0F),
  bgElevated: Color(0xFF1A1A1A),
  bgRaised: Color(0xFF1A1A1A),
  bgHover: Color(0xFF202020),
  bgPressed: Color(0xFF262626),
  bgSelected: Color(0xFF232323),
  borderSubtle: Color(0xFF1F1F1F),
  borderDefault: Color(0xFF2A2A2A),
  borderStrong: Color(0xFF3D3D3D),
  textPrimary: Color(0xFFF5F5F5),
  textSecondary: Color(0xFFB3B3B3),
  textMuted: Color(0xFF808080),
  // 3:1 non-text tier (SC 1.4.11) for icons/glyphs — see AbColors.iconMuted.
  iconMuted: Color(0xFF656565),
  textDisabled: Color(0xFF595959),
  accent: Color(0xFF34D399),
  accentHighlight: Color(0xFF6EE7B7),
  accentMuted: Color(0xFF059669),
  accentForeground: Color(0xFF09090B),
  statusIdle: Color(0xFF61656D),
  statusThinking: Color(0xFFE2C792),
  statusRunning: Color(0xFF8FCFAE),
  statusAttention: Color(0xFFE5A055),
  success: Color(0xFF22C55E),
  error: Color(0xFFF87171),
  warning: Color(0xFFFACC15),
  signalMut: Color(0xFFC084FC),
  gitUntracked: Color(0xFF2DD4BF),
  gitConflict: Color(0xFFFB7185),
);

/// Deep blue night.
const _midnight = AbColors(
  bgDeepest: Color(0xFF0A0E27),
  bgDeep: Color(0xFF0D122E),
  bgSurface: Color(0xFF151B3D),
  bgElevated: Color(0xFF1F2755),
  bgRaised: Color(0xFF1F2755),
  bgHover: Color(0xFF2A3268),
  bgPressed: Color(0xFF333D7A),
  bgSelected: Color(0xFF2E376F),
  borderSubtle: Color(0xFF222950),
  borderDefault: Color(0xFF2A3360),
  borderStrong: Color(0xFF3D497F),
  textPrimary: Color(0xFFE0E7FF),
  textSecondary: Color(0xFFA5B4FC),
  textMuted: Color(0xFF818CF8),
  // 3:1 non-text tier (SC 1.4.11) for icons/glyphs — see AbColors.iconMuted.
  iconMuted: Color(0xFF4C5BF5),
  textDisabled: Color(0xFF4F46E5),
  accent: Color(0xFFC084FC),
  accentHighlight: Color(0xFFD8B4FE),
  accentMuted: Color(0xFFA855F7),
  accentForeground: Color(0xFF09090B),
  statusIdle: Color(0xFF61656D),
  statusThinking: Color(0xFFE2C792),
  statusRunning: Color(0xFF8FCFAE),
  statusAttention: Color(0xFFE5A055),
  success: Color(0xFF22C55E),
  error: Color(0xFFF87171),
  warning: Color(0xFFFACC15),
  signalMut: Color(0xFFC084FC),
  gitUntracked: Color(0xFF2DD4BF),
  gitConflict: Color(0xFFFB7185),
);

/// Light theme — bright background, dark text. Single light preset for v1.
const _light = AbColors(
  bgDeepest: Color(0xFFFAFAFA),
  bgDeep: Color(0xFFF5F5F5),
  bgSurface: Color(0xFFFFFFFF),
  bgElevated: Color(0xFFFFFFFF),
  bgRaised: Color(0xFFFFFFFF),
  bgHover: Color(0xFFF0F0F0),
  bgPressed: Color(0xFFE0E0E0),
  bgSelected: Color(0xFFE8E8E8),
  borderSubtle: Color(0xFFE8E8E8),
  borderDefault: Color(0xFFE0E0E0),
  borderStrong: Color(0xFFBDBDBD),
  textPrimary: Color(0xFF18181B),
  textSecondary: Color(0xFF3F3F46),
  textMuted: Color(0xFF71717A),
  // 3:1 non-text tier (SC 1.4.11) for icons/glyphs — see AbColors.iconMuted.
  iconMuted: Color(0xFF8A8A92),
  textDisabled: Color(0xFFA1A1AA),
  // Accent + semantics sit one shade darker than the dark presets' hues so
  // they clear WCAG AA (>= 4.5:1) as text on white — see palette_contrast_test.
  accent: Color(0xFFBD4B25),
  accentHighlight: Color(0xFFD2542A),
  accentMuted: Color(0xFFA03E1F),
  accentForeground: Color(0xFFFFFFFF),
  statusIdle: Color(0xFF61656D),
  statusThinking: Color(0xFFE2C792),
  statusRunning: Color(0xFF8FCFAE),
  statusAttention: Color(0xFFE5A055),
  success: Color(0xFF15803D),
  error: Color(0xFFDC2626),
  warning: Color(0xFFA16207),
  signalMut: Color(0xFF9333EA),
  gitUntracked: Color(0xFF0F766E),
  gitConflict: Color(0xFFBE123C),
);

const Map<AbThemePreset, AbColors> kPresets = {
  AbThemePreset.antgrid: _antgrid,
  AbThemePreset.zinc: _zinc,
  AbThemePreset.slate: _slate,
  AbThemePreset.onyx: _onyx,
  AbThemePreset.midnight: _midnight,
  AbThemePreset.light: _light,
};

/// Default palette used when no preference is set yet.
const AbColors kDefaultPalette = _zinc;

/// Build a palette from three user-picked colors. All other tokens are
/// derived: background layers + borders lighten HSL of [bg]; text colors
/// flip based on [bg] luminance; accent variants lighten/darken [accent].
AbColors derivePalette({
  required Color bg,
  required Color primary,
  required Color accent,
}) {
  final isLightBg = bg.computeLuminance() > 0.5;

  Color lightenBg(double amount) => _shiftLightness(bg, amount);
  // For light backgrounds, "deeper" layers go darker; for dark backgrounds
  // they go lighter. That keeps the layering metaphor consistent.
  final bgSign = isLightBg ? -1.0 : 1.0;

  // Compute text shades against the *actual* picked bg so mid-luminance
  // backgrounds (e.g. user picks #7F7F7F) still hit a legible contrast
  // ratio. We anchor textPrimary at the far end of the HSL lightness axis
  // from bg and step the other shades toward bg.
  final text = _deriveTextShades(bg, isLightBg: isLightBg);

  return AbColors(
    bgDeepest: bg,
    bgDeep: lightenBg(0.02 * bgSign),
    bgSurface: lightenBg(0.06 * bgSign),
    bgElevated: lightenBg(0.12 * bgSign),
    bgRaised: lightenBg(0.12 * bgSign), // alias for bgElevated (Antgrid bg-3)
    bgHover: lightenBg(0.16 * bgSign), // Antgrid bg-4
    bgPressed: lightenBg(0.22 * bgSign), // Antgrid bg-5
    bgSelected: lightenBg(0.19 * bgSign), // between hover and pressed

    borderSubtle: lightenBg(0.04 * bgSign),
    borderDefault: lightenBg(0.09 * bgSign),
    borderStrong: lightenBg(0.17 * bgSign),
    textPrimary: text.primary,
    textSecondary: text.secondary,
    textMuted: text.muted,
    iconMuted: text.icon,
    textDisabled: text.disabled,
    accent: accent,
    accentHighlight: _shiftLightness(accent, 0.08),
    accentMuted: _shiftLightness(accent, -0.10),
    accentForeground: isLightBg
        ? const Color(0xFFFFFFFF)
        : const Color(0xFF09090B),
    statusIdle: const Color(0xFF61656D),
    statusThinking: const Color(0xFFE2C792),
    statusRunning: const Color(0xFF8FCFAE),
    statusAttention: const Color(0xFFE5A055),
    // `primary` semantically blends accent + brand. We surface it as
    // `signalMut` so chips/agent-mutation glyphs follow it.
    success: const Color(0xFF22C55E),
    error: const Color(0xFFF87171),
    warning: const Color(0xFFFACC15),
    signalMut: primary,
    // Semantic, not brand-derived — same reasoning as the other status
    // colors above: a fixed default rather than something HSL-derived from
    // bg/primary/accent.
    gitUntracked: const Color(0xFF2DD4BF),
    gitConflict: const Color(0xFFFB7185),
  );
}

/// Anchor textPrimary at the far end of the HSL lightness axis from [bg]
/// (>= 0.95 for dark bg, <= 0.10 for light bg), then step secondary/muted/
/// disabled toward bg. Tinted toward [bg]'s hue at low saturation so text
/// reads as monochromatic against colored backgrounds rather than pure
/// gray-on-tint.
({Color primary, Color secondary, Color muted, Color icon, Color disabled})
_deriveTextShades(Color bg, {required bool isLightBg}) {
  final bgHsl = HSLColor.fromColor(bg);
  // Anchor away from bg, then step 4 stops toward bg.
  final primaryL = isLightBg ? 0.10 : 0.95;
  final stepSign = isLightBg ? 1.0 : -1.0;
  // 4 evenly-spaced shades pulling toward bg lightness.
  HSLColor shade(double l) =>
      HSLColor.fromAHSL(1.0, bgHsl.hue, 0.05, l.clamp(0.0, 1.0));
  // Muted is the dimmest shade still meant to be READ (disabled is WCAG-
  // exempt). The fixed 0.35 step can land below AA on some backgrounds
  // (e.g. pure white → ~4.2:1), so walk muted back toward secondary until it
  // clears 4.5:1 against the derived bgSurface — the layer text sits on.
  // The walk stops AT secondary, never past it: on mid-lightness backgrounds
  // (#7F7F7F) no shade reaches AA, and an unbounded walk would run muted all
  // the way to primary — rendering muted text brighter than the secondary
  // shade above it and inverting the emphasis ramp.
  final secondaryL = primaryL + 0.20 * stepSign;
  final surface = _shiftLightness(bg, 0.06 * (isLightBg ? -1.0 : 1.0));
  var mutedL = primaryL + 0.35 * stepSign;
  while ((mutedL - secondaryL) * stepSign > 0 &&
      _contrastRatio(shade(mutedL).toColor(), surface) < 4.5) {
    mutedL -= 0.01 * stepSign;
  }
  // Icon mirrors the muted walk at a lower target: start at bg's own
  // lightness (guaranteed to fail) and walk away from bg — same direction
  // muted walks — until first clearing SC 1.4.11's 3:1 non-text floor
  // against both bgSurface and bg itself. Bounded at muted so an icon color
  // can never out-prominent the text tier above it.
  var iconL = bgHsl.lightness;
  while ((iconL - mutedL) * stepSign > 0 &&
      (_contrastRatio(shade(iconL).toColor(), surface) < 3.0 ||
          _contrastRatio(shade(iconL).toColor(), bg) < 3.0)) {
    iconL -= 0.01 * stepSign;
  }
  return (
    primary: shade(primaryL).toColor(),
    secondary: shade(secondaryL).toColor(),
    muted: shade(mutedL).toColor(),
    icon: shade(iconL).toColor(),
    disabled: shade(primaryL + 0.50 * stepSign).toColor(),
  );
}

/// WCAG 2.x contrast ratio between two opaque colors.
double _contrastRatio(Color a, Color b) {
  final la = a.computeLuminance() + 0.05;
  final lb = b.computeLuminance() + 0.05;
  return la > lb ? la / lb : lb / la;
}

/// Shift HSL lightness by [amount] in [-1, 1]. Clamps to [0, 1].
Color _shiftLightness(Color c, double amount) {
  final hsl = HSLColor.fromColor(c);
  final l = (hsl.lightness + amount).clamp(0.0, 1.0);
  return hsl.withLightness(l).toColor();
}
