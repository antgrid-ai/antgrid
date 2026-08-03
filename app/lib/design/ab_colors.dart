import 'package:flutter/material.dart';

/// Runtime-swappable color palette. Attached to [ThemeData] as a
/// [ThemeExtension] so widgets read via `context.antgrid.<name>` and rebuild
/// granularly when the theme changes — no MaterialApp key bump, no tree
/// remount, navigator/scroll state preserved.
///
/// Default-Zinc literal values still live as `static const` in
/// [AbTokens] for backwards compat with non-migrated reads; new code
/// should always go through `context.antgrid`.
@immutable
class AbColors extends ThemeExtension<AbColors> {
  const AbColors({
    required this.bgDeepest,
    required this.bgDeep,
    required this.bgSurface,
    required this.bgElevated,
    required this.bgRaised,
    required this.bgHover,
    required this.bgPressed,
    required this.bgSelected,
    required this.borderSubtle,
    required this.borderDefault,
    required this.borderStrong,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.iconMuted,
    required this.textDisabled,
    required this.accent,
    required this.accentHighlight,
    required this.accentMuted,
    required this.accentForeground,
    required this.statusIdle,
    required this.statusThinking,
    required this.statusRunning,
    required this.statusAttention,
    required this.success,
    required this.error,
    required this.warning,
    required this.signalMut,
  });

  final Color bgDeepest;
  final Color bgDeep;
  final Color bgSurface;
  final Color bgElevated;
  final Color bgRaised;
  final Color bgHover;
  final Color bgPressed;

  /// Background fill for selected rows/items. Must read as at least as
  /// prominent as [bgHover] so an unselected-hovered row never out-emphasizes
  /// the actually-selected row.
  final Color bgSelected;

  final Color borderSubtle;
  final Color borderDefault;
  final Color borderStrong;

  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;

  /// Non-text tier for icons/glyphs that carry state (unstaged-file marker,
  /// collapse triangle, status dot) but aren't body text — held to SC 1.4.11's
  /// 3:1 floor rather than 1.4.3's 4.5:1, since 4.5:1 has no headroom left
  /// between it and [textMuted] on any preset (see palette_contrast_test.dart).
  /// [textDisabled] looks adjacent but is the wrong token: it's WCAG-exempt,
  /// reserved for genuinely inactive controls.
  final Color iconMuted;

  final Color textDisabled;

  final Color accent;
  final Color accentHighlight;
  final Color accentMuted;
  final Color accentForeground;

  final Color statusIdle;
  final Color statusThinking;
  final Color statusRunning;
  final Color statusAttention;

  final Color success;
  final Color error;
  final Color warning;
  final Color signalMut;

  @override
  AbColors copyWith({
    Color? bgDeepest,
    Color? bgDeep,
    Color? bgSurface,
    Color? bgElevated,
    Color? bgRaised,
    Color? bgHover,
    Color? bgPressed,
    Color? bgSelected,
    Color? borderSubtle,
    Color? borderDefault,
    Color? borderStrong,
    Color? textPrimary,
    Color? textSecondary,
    Color? textMuted,
    Color? iconMuted,
    Color? textDisabled,
    Color? accent,
    Color? accentHighlight,
    Color? accentMuted,
    Color? accentForeground,
    Color? statusIdle,
    Color? statusThinking,
    Color? statusRunning,
    Color? statusAttention,
    Color? success,
    Color? error,
    Color? warning,
    Color? signalMut,
  }) {
    return AbColors(
      bgDeepest: bgDeepest ?? this.bgDeepest,
      bgDeep: bgDeep ?? this.bgDeep,
      bgSurface: bgSurface ?? this.bgSurface,
      bgElevated: bgElevated ?? this.bgElevated,
      bgRaised: bgRaised ?? this.bgRaised,
      bgHover: bgHover ?? this.bgHover,
      bgPressed: bgPressed ?? this.bgPressed,
      bgSelected: bgSelected ?? this.bgSelected,
      borderSubtle: borderSubtle ?? this.borderSubtle,
      borderDefault: borderDefault ?? this.borderDefault,
      borderStrong: borderStrong ?? this.borderStrong,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textMuted: textMuted ?? this.textMuted,
      iconMuted: iconMuted ?? this.iconMuted,
      textDisabled: textDisabled ?? this.textDisabled,
      accent: accent ?? this.accent,
      accentHighlight: accentHighlight ?? this.accentHighlight,
      accentMuted: accentMuted ?? this.accentMuted,
      accentForeground: accentForeground ?? this.accentForeground,
      statusIdle: statusIdle ?? this.statusIdle,
      statusThinking: statusThinking ?? this.statusThinking,
      statusRunning: statusRunning ?? this.statusRunning,
      statusAttention: statusAttention ?? this.statusAttention,
      success: success ?? this.success,
      error: error ?? this.error,
      warning: warning ?? this.warning,
      signalMut: signalMut ?? this.signalMut,
    );
  }

  @override
  AbColors lerp(ThemeExtension<AbColors>? other, double t) {
    if (other is! AbColors) return this;
    return AbColors(
      bgDeepest: Color.lerp(bgDeepest, other.bgDeepest, t)!,
      bgDeep: Color.lerp(bgDeep, other.bgDeep, t)!,
      bgSurface: Color.lerp(bgSurface, other.bgSurface, t)!,
      bgElevated: Color.lerp(bgElevated, other.bgElevated, t)!,
      bgRaised: Color.lerp(bgRaised, other.bgRaised, t)!,
      bgHover: Color.lerp(bgHover, other.bgHover, t)!,
      bgPressed: Color.lerp(bgPressed, other.bgPressed, t)!,
      bgSelected: Color.lerp(bgSelected, other.bgSelected, t)!,
      borderSubtle: Color.lerp(borderSubtle, other.borderSubtle, t)!,
      borderDefault: Color.lerp(borderDefault, other.borderDefault, t)!,
      borderStrong: Color.lerp(borderStrong, other.borderStrong, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      iconMuted: Color.lerp(iconMuted, other.iconMuted, t)!,
      textDisabled: Color.lerp(textDisabled, other.textDisabled, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentHighlight: Color.lerp(accentHighlight, other.accentHighlight, t)!,
      accentMuted: Color.lerp(accentMuted, other.accentMuted, t)!,
      accentForeground: Color.lerp(
        accentForeground,
        other.accentForeground,
        t,
      )!,
      statusIdle: Color.lerp(statusIdle, other.statusIdle, t)!,
      statusThinking: Color.lerp(statusThinking, other.statusThinking, t)!,
      statusRunning: Color.lerp(statusRunning, other.statusRunning, t)!,
      statusAttention: Color.lerp(statusAttention, other.statusAttention, t)!,
      success: Color.lerp(success, other.success, t)!,
      error: Color.lerp(error, other.error, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      signalMut: Color.lerp(signalMut, other.signalMut, t)!,
    );
  }
}

extension AbThemeX on BuildContext {
  /// Live color palette from the current [Theme]. Falls back to the
  /// default-Zinc palette when no [AbColors] extension is attached —
  /// typical in tests that pump bare `MaterialApp()` widgets.
  AbColors get antgrid =>
      Theme.of(this).extension<AbColors>() ?? _zincFallback;
}

const _zincFallback = AbColors(
  bgDeepest: Color(0xFF09090B),
  bgDeep: Color(0xFF0C0C0F),
  bgSurface: Color(0xFF18181B),
  bgElevated: Color(0xFF27272A),
  bgRaised: Color(0xFF1F1F23),
  bgHover: Color(0xFF2A2A2F),
  bgPressed: Color(0xFF35353B),
  bgSelected: Color(0xFF2F2F35),
  borderSubtle: Color(0xFF1A1A1F),
  borderDefault: Color(0xFF27272A),
  borderStrong: Color(0xFF3F3F46),
  textPrimary: Color(0xFFE4E4E7),
  textSecondary: Color(0xFFA1A1AA),
  textMuted: Color(0xFF71717A),
  iconMuted: Color(0xFF696972),
  textDisabled: Color(0xFF52525B),
  accent: Color(0xFF818CF8),
  accentHighlight: Color(0xFFA78BFA),
  accentMuted: Color(0xFF4F46E5),
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
