import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

/// Terminal-native design tokens for Antgrid.
///
/// **Color constants below are deprecated** — they bake in the dark-Zinc
/// defaults at compile time and bypass the active [ThemeExtension] palette.
/// Read live colors via `context.antgrid.<name>` instead. The constants remain
/// only to keep `theme_presets.dart` / `ab_colors.dart` literal palettes
/// terse; widget code must never reach for them directly.
abstract final class AbTokens {
  // ── Background layers (darkest → lightest) ──
  @Deprecated(
    'Use context.antgrid.bgDeepest — AbTokens colors bypass the active theme.',
  )
  static const bgDeepest = Color(0xFF09090B);
  @Deprecated(
    'Use context.antgrid.bgDeep — AbTokens colors bypass the active theme.',
  )
  static const bgDeep = Color(0xFF0C0C0F);
  @Deprecated(
    'Use context.antgrid.bgSurface — AbTokens colors bypass the active theme.',
  )
  static const bgSurface = Color(0xFF18181B);
  @Deprecated(
    'Use context.antgrid.bgElevated — AbTokens colors bypass the active theme.',
  )
  static const bgElevated = Color(0xFF27272A);

  // ── Borders ──
  @Deprecated(
    'Use context.antgrid.borderSubtle — AbTokens colors bypass the active theme.',
  )
  static const borderSubtle = Color(0xFF1A1A1F);
  @Deprecated(
    'Use context.antgrid.borderDefault — AbTokens colors bypass the active theme.',
  )
  static const borderDefault = Color(0xFF27272A);
  @Deprecated(
    'Use context.antgrid.borderStrong — AbTokens colors bypass the active theme.',
  )
  static const borderStrong = Color(0xFF3F3F46);

  // ── Text ──
  @Deprecated(
    'Use context.antgrid.textPrimary — AbTokens colors bypass the active theme.',
  )
  static const textPrimary = Color(0xFFE4E4E7);
  @Deprecated(
    'Use context.antgrid.textSecondary — AbTokens colors bypass the active theme.',
  )
  static const textSecondary = Color(0xFFA1A1AA);
  @Deprecated(
    'Use context.antgrid.textMuted — AbTokens colors bypass the active theme.',
  )
  static const textMuted = Color(0xFF71717A);
  @Deprecated(
    'Use context.antgrid.textDisabled — AbTokens colors bypass the active theme.',
  )
  static const textDisabled = Color(0xFF52525B);

  // ── Accent (indigo/purple) ──
  @Deprecated(
    'Use context.antgrid.accent — AbTokens colors bypass the active theme.',
  )
  static const accent = Color(0xFF818CF8);
  @Deprecated(
    'Use context.antgrid.accentHighlight — AbTokens colors bypass the active theme.',
  )
  static const accentHighlight = Color(0xFFA78BFA);
  @Deprecated(
    'Use context.antgrid.accentMuted — AbTokens colors bypass the active theme.',
  )
  static const accentMuted = Color(0xFF4F46E5);

  // ── Semantic ──
  @Deprecated(
    'Use context.antgrid.success — AbTokens colors bypass the active theme.',
  )
  static const success = Color(0xFF22C55E);
  @Deprecated(
    'Use context.antgrid.error — AbTokens colors bypass the active theme.',
  )
  static const error = Color(0xFFF87171);
  @Deprecated(
    'Use context.antgrid.warning — AbTokens colors bypass the active theme.',
  )
  static const warning = Color(0xFFFACC15);
  @Deprecated(
    'Use context.antgrid.signalMut — AbTokens colors bypass the active theme.',
  )
  static const signalMut = Color(0xFFC084FC); // agent action / mutation

  // ── Spacing ──
  static const space2 = 2.0;
  static const space4 = 4.0;
  static const space6 = 6.0;
  static const space8 = 8.0;
  static const space10 = 10.0;
  static const space12 = 12.0;
  static const space14 = 14.0;
  static const space16 = 16.0;
  static const space24 = 24.0;

  // ── Drawer layout ──
  /// Shared horizontal inset for every [ProjectsDrawer] section. Single
  /// source of truth: ad-hoc values are bugs.
  static const drawerGutter = space12;

  /// Leading-icon slot width for drawer rows. Governs the *slot*, not the
  /// glyph size inside it.
  static const drawerLeadingSlot = 12.0;

  // ── Focus ring (keyboard navigation) ──
  // Color reuses `accent` — no separate token.
  static const double focusRingWidth = 1.0;
  static const double focusRingOffset = 2.0;

  // ── Radius ──
  static const radius = 2.0;
  static const radiusLg = 4.0;
  static final borderRadius = BorderRadius.circular(radius);
  static final borderRadiusLg = BorderRadius.circular(radiusLg);

  // ── Antgrid radii ──
  static const radius3 = 3.0; // chips, kbd
  static const radius5 = 5.0; // buttons, inputs (default)
  static const radius8 = 8.0; // cards, panels
  static const radius12 = 12.0; // large surfaces
  static const radiusFull = 999.0; // pill (CTA, status pill)

  static final borderRadius3 = BorderRadius.circular(radius3);
  static final borderRadius5 = BorderRadius.circular(radius5);
  static final borderRadius8 = BorderRadius.circular(radius8);
  static final borderRadius12 = BorderRadius.circular(radius12);
  static final borderRadiusFull = BorderRadius.circular(radiusFull);

  // ── Typography ──
  /// System monospace family per platform. Resolves to the OS default
  /// (Menlo on Apple, Consolas on Windows, generic 'monospace' elsewhere)
  /// so the app inherits the user's terminal font rather than a bundled one.
  static String get fontMono {
    if (kIsWeb) return 'monospace';
    if (Platform.isMacOS || Platform.isIOS) return 'Menlo';
    if (Platform.isWindows) return 'Cascadia Mono';
    return 'monospace';
  }

  static const fontMonoFallbacks = [
    'Cascadia Mono',
    'Cascadia Code',
    'Consolas',
    'Menlo',
    'SF Mono',
    'Liberation Mono',
    'monospace',
  ];

  /// System UI font family per platform — inherits the OS default sans
  /// (SF on Apple, Segoe UI on Windows, Roboto on Android, generic
  /// 'sans-serif' elsewhere) instead of a bundled face.
  static String get fontSans {
    if (kIsWeb) return 'system-ui';
    if (Platform.isMacOS || Platform.isIOS) return '.AppleSystemUIFont';
    if (Platform.isWindows) return 'Segoe UI';
    if (Platform.isAndroid) return 'Roboto';
    return 'sans-serif';
  }

  static const fontSansFallbacks = [
    'Segoe UI',
    'Roboto',
    'SF Pro Text',
    'sans-serif',
  ];

  // ── Typography scale ──
  // VS Code body baseline (14px). All `fontSize:` values in app/lib/**
  // must reference one of these tokens; raw literals are CI-enforced
  // (see scripts/check_font_tokens.sh). The constants below are the
  // ONLY exception.
  static const double fontXxs = 10.0;
  static const double fontXs = 11.0;
  static const double fontSm = 12.0;
  static const double fontMd = 13.0;
  static const double fontBody = 14.0;
  static const double fontLg = 16.0;
  static const double fontXl = 18.0;
  static const double fontDisplaySm = 24.0;
  static const double fontDisplayMd = 32.0;
  static const double fontDisplayLg = 40.0;

  // ── Sizes ──
  static const sidebarWidth = 48.0;
  static const commandTrayHeight = 44.0;
  static const bottomNavHeight = 56.0;
  static const collapsedStripWidth = 36.0;

  // Standard row heights — all toolbars/headers must use one of these.
  static const rowHeightXs = 28.0; // compact filter fields (floor: 24px clear btn)
  static const rowHeightSm = 32.0; // dense action bars, tab strips
  static const rowHeightMd =
      38.0; // panel headers (formerly statusHeaderHeight)
  static const rowHeightLg = 44.0; // mobile-friendly hit-target rows
  static const rowHeightXl = 52.0; // roomy touch bars (mobile terminal quick-actions)

  /// Deprecated: use [rowHeightMd]. Retained for migration only.
  static const statusHeaderHeight = rowHeightMd;

  // Icon button — one canonical visual box (chrome default).
  static const iconButtonBox = 24.0;
  static const iconButtonGlyph = 14.0;
  // Larger glyph for touch affordances (e.g. the mobile terminal
  // quick-actions bar), where a 14px glyph reads small in a tall touch row.
  static const iconButtonGlyphXl = 26.0; // keyboard-key-sized (the IME toggle)

  // Minimum interactive-target edge: 44 splits Apple HIG's 44pt and Android's
  // 48dp guidance. Enforced on mobile only, via AbTapTarget — desktop pointers
  // are precise and dense toolbars must stay compact.
  static const tapTargetMin = 44.0;

  // Status dots.
  static const double dotSizeSm = 6.0;
  static const double dotSizeMd = 8.0;

  // ── Motion ──
  static const motionSnap = Duration(milliseconds: 80);
  static const motionDefault = Duration(milliseconds: 160);
  static const motionSettle = Duration(milliseconds: 320);

  // ── Helpers ──
  /// Logical weight offset applied to helper-built text styles. Set once per
  /// frame by `AbTextDensity` from the ambient devicePixelRatio: 1 on low-DPI
  /// displays (grayscale AA leaves stems thin), 0 on hi-DPI (render as designed).
  static int activeWeightOffset = 0;

  /// Below this DPR, bump one weight step. Tune on a low-DPI external monitor.
  static const double lowDprThreshold = 1.5;

  /// Text at or below this size is never bumped — heavier strokes merge at
  /// micro sizes. Default protects only fontXxs (10px).
  static const double minBumpFontSize = fontXxs;

  /// Fraction of a full 100-unit weight step applied when the low-DPI bump is
  /// active. 1.0 = full step (w400→w500); lower softens it. Variable fonts
  /// (e.g. Cascadia Mono) honor the fractional weight via the `wght` axis;
  /// static fonts fall back to the rounded [FontWeight] in [_bump].
  static const double bumpStrength = 0.45;

  static FontWeight _bump(FontWeight w, double size) {
    if (activeWeightOffset == 0 || size <= minBumpFontSize) return w;
    final base = FontWeight.values.indexOf(w);
    if (base < 0) return w; // non-canonical (e.g. lerped) weight — leave as-is
    final steps = (activeWeightOffset * bumpStrength).round();
    final i = (base + steps).clamp(0, 8);
    return FontWeight.values[i];
  }

  /// Continuous `wght` variation mirroring [_bump], so the low-DPI bump can be
  /// a fraction of a full weight step on variable fonts. Returns null when no
  /// bump applies, leaving the font at its default weight.
  static List<FontVariation>? _bumpVariations(FontWeight w, double size) {
    if (activeWeightOffset == 0 || size <= minBumpFontSize) return null;
    if (!FontWeight.values.contains(w)) return null;
    final target = (w.value + activeWeightOffset * bumpStrength * 100).clamp(
      1.0,
      900.0,
    );
    return [FontVariation('wght', target)];
  }

  /// Mono-family [TextStyle] helper. `color` is intentionally nullable and
  /// defaults to null — when omitted, the rendered text inherits color from
  /// the ambient [DefaultTextStyle] (driven by `colorScheme.onSurface`,
  /// itself wired to the active palette's `textPrimary`). This keeps mono
  /// text legible under any theme preset. Pass an explicit `color` only
  /// when overriding (e.g. muted/secondary/accent tints).
  static TextStyle monoStyle({
    double fontSize = fontBody,
    Color? color,
    FontWeight fontWeight = FontWeight.normal,
    double? letterSpacing,
    double? height,
  }) => TextStyle(
    fontFamily: fontMono,
    fontFamilyFallback: fontMonoFallbacks,
    fontSize: fontSize,
    color: color,
    fontWeight: _bump(fontWeight, fontSize),
    fontVariations: _bumpVariations(fontWeight, fontSize),
    letterSpacing: letterSpacing,
    height: height,
  );

  /// Sans-family [TextStyle] helper — the Antgrid default for UI chrome
  /// (labels, headers, buttons, list-row titles, menus, breadcrumbs,
  /// dialog/empty-state copy). Reserve [monoStyle] for code, paths,
  /// identifiers, terminal/diff/file content, branch refs, kbd chips,
  /// and similar code-shaped data.
  ///
  /// `color` is nullable for the same reason as [monoStyle]: omit to
  /// inherit `colorScheme.onSurface` from the ambient [DefaultTextStyle].
  static TextStyle sansStyle({
    double fontSize = fontBody,
    Color? color,
    FontWeight fontWeight = FontWeight.normal,
    double? letterSpacing,
    double? height,
  }) => TextStyle(
    fontFamily: fontSans,
    fontFamilyFallback: fontSansFallbacks,
    fontSize: fontSize,
    color: color,
    fontWeight: _bump(fontWeight, fontSize),
    fontVariations: _bumpVariations(fontWeight, fontSize),
    letterSpacing: letterSpacing,
    height: height,
  );
}
