import 'package:flutter/material.dart';

import 'theme_presets.dart';
import 'ab_colors.dart';
import 'ab_tokens.dart';

/// Build a [ThemeData] from a [AbColors] palette. The palette is also
/// attached as a [ThemeExtension] so widgets can read live values via
/// `context.antgrid.<name>`.
ThemeData buildAbTheme([AbColors palette = kDefaultPalette]) {
  final isLight = palette.bgDeepest.computeLuminance() > 0.5;
  final colorScheme = ColorScheme(
    brightness: isLight ? Brightness.light : Brightness.dark,
    surface: palette.bgDeepest,
    onSurface: palette.textPrimary,
    primary: palette.accent,
    onPrimary: isLight ? Colors.white : palette.bgDeepest,
    primaryContainer: palette.accentMuted,
    onPrimaryContainer: palette.textPrimary,
    secondary: palette.textSecondary,
    onSecondary: palette.bgDeepest,
    error: palette.error,
    onError: palette.bgDeepest,
    outline: palette.borderDefault,
    outlineVariant: palette.borderSubtle,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: isLight ? Brightness.light : Brightness.dark,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: palette.bgDeepest,
    fontFamily: AbTokens.fontSans,
    fontFamilyFallback: AbTokens.fontSansFallbacks,
    extensions: [palette],

    appBarTheme: AppBarTheme(
      backgroundColor: palette.bgDeepest,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: AbTokens.sansStyle(
        fontSize: AbTokens.fontLg,
        fontWeight: FontWeight.w600,
        color: palette.textPrimary,
      ),
    ),

    dialogTheme: DialogThemeData(
      backgroundColor: palette.bgSurface,
      shape: RoundedRectangleBorder(
        borderRadius: AbTokens.borderRadius8,
        side: BorderSide(color: palette.borderDefault),
      ),
    ),

    dividerTheme: DividerThemeData(
      color: palette.borderSubtle,
      thickness: 1,
      space: 1,
    ),

    snackBarTheme: SnackBarThemeData(
      // Floating; the bounded width is injected per-MediaQuery in main.dart's
      // builder. Together they keep snackbars from spanning the full window.
      behavior: SnackBarBehavior.floating,
      backgroundColor: palette.bgElevated,
      contentTextStyle: AbTokens.sansStyle(color: palette.textPrimary),
      shape: RoundedRectangleBorder(
        borderRadius: AbTokens.borderRadius8,
        side: BorderSide(color: palette.borderDefault),
      ),
    ),

    textSelectionTheme: TextSelectionThemeData(
      cursorColor: palette.accent,
      selectionColor: palette.accent.withValues(alpha: 0.3),
      selectionHandleColor: palette.accent,
    ),

    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: palette.bgSurface,
      border: OutlineInputBorder(
        borderRadius: AbTokens.borderRadius5,
        borderSide: BorderSide(color: palette.borderDefault),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: AbTokens.borderRadius5,
        borderSide: BorderSide(color: palette.borderDefault),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: AbTokens.borderRadius5,
        borderSide: BorderSide(color: palette.accent),
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AbTokens.space10,
        vertical: AbTokens.space8,
      ),
      hintStyle: AbTokens.sansStyle(color: palette.textDisabled),
    ),
  );
}

/// Resolve a [AbColors] from the current settings — preset lookup, or
/// derived from custom colors (falling back to defaults for any unset
/// custom slot).
AbColors paletteFor({
  required AbThemePreset preset,
  Color? customBg,
  Color? customPrimary,
  Color? customAccent,
}) {
  if (preset == AbThemePreset.custom) {
    return derivePalette(
      bg: customBg ?? kDefaultPalette.bgDeepest,
      primary: customPrimary ?? kDefaultPalette.signalMut,
      accent: customAccent ?? kDefaultPalette.accent,
    );
  }
  return kPresets[preset] ?? kDefaultPalette;
}
