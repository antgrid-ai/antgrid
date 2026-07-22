import 'package:flutter/material.dart';

import 'ab_colors.dart';

enum AbThemePreset { antgrid, light, zinc, slate, onyx, midnight, custom }

/// Antgrid — refined dark IDE palette (Vercel/Linear class).
/// Six-step surface ramp, off-white accent, muted agent-state palette.
const _antgrid = AbColors(
  bgDeepest: Color(0xFF08090A),
  bgDeep: Color(0xFF0E0F11),
  bgSurface: Color(0xFF131517),
  bgElevated: Color(0xFF181A1D),
  // Antgrid aliases bg-3 (raised) to bgElevated — they're the same surface.
  bgRaised: Color(0xFF181A1D),
  bgHover: Color(0xFF1F2226),
  bgPressed: Color(0xFF272A2F),
  bgSelected: Color(0xFF24272B),
  borderSubtle: Color(0x12FFFFFF),
  borderDefault: Color(0x16FFFFFF),
  borderStrong: Color(0x29FFFFFF),
  textPrimary: Color(0xFFF5F6F7),
  textSecondary: Color(0xFFD7D9DC),
  textMuted: Color(0xFF9498A0),
  textDisabled: Color(0xFF61656D),
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
);

/// Default: neutral grayscale terminal palette.
/// bg #141414, text #d8d8d8, primary/accent #c6c6c6.
const _zinc = AbColors(
  bgDeepest: Color(0xFF141414),
  bgDeep: Color(0xFF141414),
  bgSurface: Color(0xFF1A1A1A),
  bgElevated: Color(0xFF242424),
  bgRaised: Color(0xFF242424),
  bgHover: Color(0xFF2A2A2A),
  bgPressed: Color(0xFF333333),
  bgSelected: Color(0xFF2F2F2F),
  borderSubtle: Color(0xFF202020),
  borderDefault: Color(0xFF242424),
  borderStrong: Color(0xFF383838),
  textPrimary: Color(0xFFD8D8D8),
  textSecondary: Color(0xFFA6A6A6),
  textMuted: Color(0xFF737373),
  textDisabled: Color(0xFF4D4D4D),
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
  textMuted: Color(0xFF64748B),
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
  textDisabled: Color(0xFFA1A1AA),
  accent: Color(0xFF6366F1),
  accentHighlight: Color(0xFF818CF8),
  accentMuted: Color(0xFF4F46E5),
  accentForeground: Color(0xFFFFFFFF),
  statusIdle: Color(0xFF61656D),
  statusThinking: Color(0xFFE2C792),
  statusRunning: Color(0xFF8FCFAE),
  statusAttention: Color(0xFFE5A055),
  success: Color(0xFF16A34A),
  error: Color(0xFFDC2626),
  warning: Color(0xFFCA8A04),
  signalMut: Color(0xFF9333EA),
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
  );
}

/// Anchor textPrimary at the far end of the HSL lightness axis from [bg]
/// (>= 0.95 for dark bg, <= 0.10 for light bg), then step secondary/muted/
/// disabled toward bg. Tinted toward [bg]'s hue at low saturation so text
/// reads as monochromatic against colored backgrounds rather than pure
/// gray-on-tint.
({Color primary, Color secondary, Color muted, Color disabled})
_deriveTextShades(Color bg, {required bool isLightBg}) {
  final bgHsl = HSLColor.fromColor(bg);
  // Anchor away from bg, then step 4 stops toward bg.
  final primaryL = isLightBg ? 0.10 : 0.95;
  final stepSign = isLightBg ? 1.0 : -1.0;
  // 4 evenly-spaced shades pulling toward bg lightness.
  HSLColor shade(double l) =>
      HSLColor.fromAHSL(1.0, bgHsl.hue, 0.05, l.clamp(0.0, 1.0));
  return (
    primary: shade(primaryL).toColor(),
    secondary: shade(primaryL + 0.20 * stepSign).toColor(),
    muted: shade(primaryL + 0.35 * stepSign).toColor(),
    disabled: shade(primaryL + 0.50 * stepSign).toColor(),
  );
}

/// Shift HSL lightness by [amount] in [-1, 1]. Clamps to [0, 1].
Color _shiftLightness(Color c, double amount) {
  final hsl = HSLColor.fromColor(c);
  final l = (hsl.lightness + amount).clamp(0.0, 1.0);
  return hsl.withLightness(l).toColor();
}
