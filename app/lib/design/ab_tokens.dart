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

  // ── Accent (Signal) ──
  @Deprecated(
    'Use context.antgrid.accent — AbTokens colors bypass the active theme.',
  )
  static const accent = Color(0xFFDB6F4B);
  @Deprecated(
    'Use context.antgrid.accentHighlight — AbTokens colors bypass the active theme.',
  )
  static const accentHighlight = Color(0xFFEA997F);
  @Deprecated(
    'Use context.antgrid.accentMuted — AbTokens colors bypass the active theme.',
  )
  static const accentMuted = Color(0xFFD2542A);

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
  /// Bundled monospace family — the same face on every platform.
  ///
  /// This used to resolve to the OS default per platform, on the stated
  /// rationale that the app should inherit "the user's terminal font". It
  /// never did: nothing here reads the user's terminal config, so that only
  /// bought four uncontrolled render targets (Menlo, Cascadia Mono, and
  /// whatever fontconfig or the browser picks for generic `monospace`).
  ///
  /// Bundling matters most on low-DPI Windows and Linux. Flutter rasterizes
  /// text with grayscale AA and no stem darkening — unlike DirectWrite's
  /// ClearType, which native apps get — so at DPR 1 the stems come out thin.
  /// [bumpStrength] compensates by stepping to a heavier master, which only
  /// works if a heavier master is guaranteed to exist. A system `monospace`
  /// gave no such guarantee.
  ///
  /// "NL" is the no-ligature build, and that is load-bearing: the terminal
  /// painter has a single-run fast path whose only width guard compares total
  /// advance, and JetBrains Mono's coding ligatures are width-preserving — so
  /// the ligature build would silently fuse `=>`/`!=`/`->` across cells.
  static const fontMono = 'JetBrains Mono NL';

  /// Coverage fallbacks only — the bundled face is Latin/Greek/Cyrillic, so
  /// CJK, emoji and powerline glyphs in agent output still resolve here.
  /// Box-drawing does NOT rely on this: the terminal renders those itself as
  /// sprite glyphs (`_terminalBoxDrawingSpec` in ghostty_vte_flutter).
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
  /// Max content width for the agent transcript (body + composer). ~66ch at
  /// [fontMd] — the readability sweet spot; wider degrades line-scanning. On
  /// narrower panels the centering constraint is a no-op. Code/diff cards opt
  /// out by scrolling internally rather than widening this measure.
  static const transcriptMaxWidth = 680.0;

  static const sidebarWidth = 48.0;
  static const commandTrayHeight = 44.0;
  static const bottomNavHeight = 56.0;
  static const collapsedStripWidth = 36.0;

  /// Width of a slide-in projects pane, matching the width a `Scaffold.drawer`
  /// gives the same content. Shared by every hand-rolled docked pane that
  /// stands in for one (`workspace_shell.dart`, `new_session_screen.dart`) so
  /// the drawer reads the same size wherever it shows.
  static const drawerPaneWidth = 304.0;

  /// Ceiling for the centred session-search field AND the result popup hung
  /// under it. The field shrinks below this on a narrow window; the cap stops a
  /// wide one turning a search box into the widest thing in the title bar. The
  /// popup measures its own width off the field, so this bounds them together.
  static const sessionSearchWidth = 560.0;

  /// Height at which the search popup stops growing and starts scrolling.
  static const sessionSearchPopupMaxHeight = 420.0;

  /// Floors for a popup measured off its field. The panel takes the field's
  /// width and whatever height is free beneath it, so a squeezed title bar or a
  /// raised keyboard would otherwise shrink it to a sliver; below these it
  /// overhangs instead, which at least keeps rows reachable.
  static const sessionSearchPopupMinWidth = 280.0;
  static const sessionSearchPopupMinHeight = 160.0;

  // Standard row heights — all toolbars/headers must use one of these.
  static const rowHeightXs =
      28.0; // compact filter fields (floor: 24px clear btn)
  static const rowHeightSm = 32.0; // dense action bars, tab strips
  static const rowHeightMd =
      38.0; // panel headers (formerly statusHeaderHeight)
  static const rowHeightLg = 44.0; // mobile-friendly hit-target rows
  static const rowHeightXl = 52.0; // roomy touch bars (mobile terminal quick-actions)

  /// Deprecated: use [rowHeightMd]. Retained for migration only.
  static const statusHeaderHeight = rowHeightMd;

  /// One cell of a swipe-action tray ([AbSwipeActions]). Wider than
  /// [tapTargetMin] because the cell carries an icon AND its label — the label
  /// is what keeps a revealed action nameable, and a swipe reveals the tray
  /// from the trailing edge, so a wide cell is also the easier target coming
  /// out of the drag.
  static const swipeActionWidth = 84.0;

  // Icon button — one canonical visual box (chrome default).
  static const iconButtonBox = 24.0;
  static const iconButtonGlyph = 14.0;
  // Larger glyph for touch affordances (e.g. the mobile terminal
  // quick-actions bar), where a 14px glyph reads small in a tall touch row.
  static const iconButtonGlyphXl = 26.0; // keyboard-key-sized (the IME toggle)

  // Windows caption buttons (minimize/maximize/close). They mimic the OS
  // control block, so they ignore the icon-button sizing above: 46px wide,
  // full bar height, square, and butted together with no gap — the metrics
  // WinUI and VS Code both use.
  static const captionButtonWidth = 46.0;

  /// Edge of the square the caption glyph is drawn into. Not comparable to
  /// [iconButtonGlyph]: these glyphs are painted edge to edge, where an icon
  /// from the set spends about a third of its box on internal padding. Matched
  /// against a real Windows caption block, not chosen from the scale.
  static const captionButtonGlyph = 10.0;

  /// Close-button hover fill. Deliberately NOT a theme color: every Windows
  /// app shows the same red here, so following the palette would break the
  /// one caption affordance users recognise without reading it.
  static const captionCloseHover = Color(0xFFC42B1C);
  static const captionClosePressed = Color(0xFF9B2117);

  /// Glyph on the filled close button — white in every theme, because the
  /// fill behind it is fixed.
  static const captionCloseForeground = Color(0xFFFFFFFF);

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

  /// A docked side pane sliding in or out. Longer than [motionDefault]: the
  /// travel is a whole pane width, not a state change in place.
  ///
  /// Shared rather than per-call so a pane's own [AnimatedSlide] and the
  /// [AnimatedPadding] reserving space for it beside the agent cannot fall out
  /// of step — they animate different properties of the same movement, and
  /// they only read as one movement while both run on this.
  static const motionPane = Duration(milliseconds: 220);

  // ── Helpers ──
  /// Logical weight offset applied to helper-built text styles. Set once per
  /// frame by `AbTextDensity` from the ambient devicePixelRatio: 1 on low-DPI
  /// displays (grayscale AA leaves stems thin), 0 on hi-DPI (render as designed).
  static int activeWeightOffset = 0;

  /// Below this DPR, bump one weight step. `0` disables the bump entirely,
  /// since no display reports a DPR below it.
  ///
  /// Currently disabled. The bump was compensating for how thin mono read on
  /// Windows, but most of that was the bare `monospace` fallback the platform
  /// resolved before JetBrains Mono NL was bundled. Against a face drawn for
  /// screens a whole extra master overshoots and reads heavy, and a static
  /// family offers no smaller step to take (see [bumpStrength]).
  ///
  /// Re-enabling means picking a threshold, and DPR is a poor proxy for the
  /// thing we care about: on Windows it reports the display *scale factor*,
  /// not physical density, so a 4K panel at 150% (genuinely dense) and a 1080p
  /// panel at 150% (not) both arrive as 1.5. 1.5 was the previous cut. Retune
  /// on a real low-density monitor, not from first principles.
  static const double lowDprThreshold = 0.0;

  /// Text at or below this size is never bumped — heavier strokes merge at
  /// micro sizes. Default protects only fontXxs (10px).
  static const double minBumpFontSize = fontXxs;

  /// Fraction of a full 100-unit weight step applied when the low-DPI bump is
  /// active. 1.0 = full step (w400→w500); lower softens it.
  ///
  /// Must stay at 1.0 while the mono family is a set of static masters. A
  /// fractional value only means anything on a variable font, where
  /// [_bumpVariations] can ask for `wght: 445`; against static faces [_bump]
  /// rounds it, and anything under 0.5 rounds to zero — which is what the
  /// previous 0.45 did on every platform, bumping nothing at all. Softening
  /// the step again requires shipping a variable face, not lowering this.
  static const double bumpStrength = 1.0;

  /// [_bump] for callers that build their own [TextStyle] instead of going
  /// through [monoStyle]/[sansStyle].
  ///
  /// The terminal is the reason this is public: it paints through its own
  /// TextPainters inside ghostty_vte_flutter, so the ambient offset cannot
  /// reach it the way it reaches chrome. Without this the primary surface is
  /// the one place the low-DPI compensation silently does not apply.
  static FontWeight bumpedWeight(FontWeight w, double size) => _bump(w, size);

  static FontWeight _bump(FontWeight w, double size) {
    if (activeWeightOffset == 0 || size <= minBumpFontSize) return w;
    final base = FontWeight.values.indexOf(w);
    if (base < 0) return w; // non-canonical (e.g. lerped) weight — leave as-is
    final steps = (activeWeightOffset * bumpStrength).round();
    final i = (base + steps).clamp(0, 8);
    return FontWeight.values[i];
  }

  /// Continuous `wght` variation mirroring [_bump]. A static face ignores it
  /// and takes [_bump]'s rounded weight instead, so the two must agree — they
  /// do only while [bumpStrength] is a whole step. This still earns its place
  /// for [sansStyle], which resolves to system faces that may be variable.
  /// Returns null when no bump applies, leaving the font at its own default.
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
