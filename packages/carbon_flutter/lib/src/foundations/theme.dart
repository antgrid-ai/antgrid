import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'colors.dart';
import 'localizations.dart';
import 'typography.dart';

/// Control sizing. Chosen explicitly by the host and never inferred from
/// viewport width, pointer kind or text scale: a wide tablet stays touch, and
/// a desktop host may choose touch for touch-first use.
enum CarbonDensity {
  /// Pointer and keyboard workflows: 32px controls, productive type.
  compact,

  /// Finger interaction: [CarbonThemeData.touchTarget] (48 by default)
  /// controls and targets, 16px control text.
  touch,
}

/// The four built-in Carbon themes.
enum CarbonThemeScheme {
  white(Brightness.light),
  gray10(Brightness.light),
  gray90(Brightness.dark),
  gray100(Brightness.dark);

  const CarbonThemeScheme(this.brightness);

  final Brightness brightness;

  CarbonColors get colors => switch (this) {
    CarbonThemeScheme.white => CarbonColors.white,
    CarbonThemeScheme.gray10 => CarbonColors.gray10,
    CarbonThemeScheme.gray90 => CarbonColors.gray90,
    CarbonThemeScheme.gray100 => CarbonColors.gray100,
  };
}

/// Font families the typography roles resolve against.
@immutable
class CarbonFonts {
  const CarbonFonts({
    this.sans = CarbonTypography.sansFamily,
    this.mono = CarbonTypography.monoFamily,
    this.package = CarbonTypography.package,
    this.fallback = const <String>[],
  });

  final String sans;
  final String mono;

  /// The asset package bundling [sans] and [mono]; null for families the
  /// application bundles itself.
  final String? package;

  final List<String> fallback;

  @override
  bool operator ==(Object other) =>
      other is CarbonFonts &&
      other.sans == sans &&
      other.mono == mono &&
      other.package == package &&
      listEquals(other.fallback, fallback);

  @override
  int get hashCode => Object.hash(sans, mono, package, Object.hashAll(fallback));
}

/// Immutable Carbon configuration for a subtree: colors, density and type.
///
/// Customize through a [CarbonColors] override that keeps each role's meaning
/// (see `doc/theming.md`), not through per-screen padding or color overrides.
@immutable
class CarbonThemeData {
  CarbonThemeData({
    this.scheme = CarbonThemeScheme.white,
    this.density = CarbonDensity.compact,
    CarbonColors? colors,
    Brightness? brightness,
    this.fonts = const CarbonFonts(),
    CarbonTypography? compactTypography,
    CarbonTypography? touchTypography,
    this.touchTarget = 48,
  }) : colors = colors ?? scheme.colors,
       brightness = brightness ?? scheme.brightness,
       _compactTypography = compactTypography,
       _touchTypography = touchTypography;

  /// White for a light appearance, Gray 100 for a dark one.
  factory CarbonThemeData.forBrightness(
    Brightness brightness, {
    CarbonDensity density = CarbonDensity.compact,
    double touchTarget = 48,
  }) => CarbonThemeData(
    scheme: brightness == Brightness.dark
        ? CarbonThemeScheme.gray100
        : CarbonThemeScheme.white,
    density: density,
    touchTarget: touchTarget,
  );

  final CarbonThemeScheme scheme;
  final CarbonDensity density;
  final CarbonColors colors;
  final Brightness brightness;
  final CarbonFonts fonts;

  /// The extent of a finger target under [CarbonDensity.touch]. Carbon's
  /// generic default is 48; a host following another platform guideline (44
  /// on Apple platforms) sets it once here instead of per component. Ignored
  /// under compact density, and [largeControlHeight] does not follow it.
  final double touchTarget;
  final CarbonTypography? _compactTypography;
  final CarbonTypography? _touchTypography;

  /// Type roles for the current [density]. Recomputed per density so a density
  /// switch can never leave the old metrics behind.
  CarbonTypography get typography => switch (density) {
    CarbonDensity.compact =>
      _compactTypography ?? _typographyFor(CarbonDensity.compact, fonts),
    CarbonDensity.touch =>
      _touchTypography ?? _typographyFor(CarbonDensity.touch, fonts),
  };

  bool get isTouch => density == CarbonDensity.touch;

  /// Default single-line control height: 32 compact, [touchTarget] touch. A minimum —
  /// enlarged text and multi-line content grow past it.
  double get controlHeight => isTouch ? touchTarget : 32;

  /// The documented small variant for constrained chrome. Touch keeps its
  /// [touchTarget] floor.
  double get smallControlHeight => isTouch ? touchTarget : 24;

  /// Large control height (Carbon `lg`), e.g. modal footer buttons.
  double get largeControlHeight => isTouch ? 64 : 48;

  /// Minimum interactive footprint for icon-only and indicator controls.
  double get minTarget => isTouch ? touchTarget : 32;

  /// Glyph size inside controls.
  double get iconSize => isTouch ? 20 : 16;

  /// Horizontal padding inside text-bearing controls.
  double get controlPaddingX => isTouch ? 16 : 12;

  /// Surface fill for a layer [level] (0 = page background, 1–3 = layers).
  Color layer(int level) => switch (level.clamp(0, 3)) {
    0 => colors.background,
    1 => colors.layer01,
    2 => colors.layer02,
    _ => colors.layer03,
  };

  Color layerHover(int level) => switch (level.clamp(0, 3)) {
    0 => colors.backgroundHover,
    1 => colors.layerHover01,
    2 => colors.layerHover02,
    _ => colors.layerHover03,
  };

  Color layerActive(int level) => switch (level.clamp(0, 3)) {
    0 => colors.backgroundActive,
    1 => colors.layerActive01,
    2 => colors.layerActive02,
    _ => colors.layerActive03,
  };

  Color layerSelected(int level) => switch (level.clamp(0, 3)) {
    0 => colors.backgroundSelected,
    1 => colors.layerSelected01,
    2 => colors.layerSelected02,
    _ => colors.layerSelected03,
  };

  Color layerSelectedHover(int level) => switch (level.clamp(0, 3)) {
    0 => colors.backgroundSelectedHover,
    1 => colors.layerSelectedHover01,
    2 => colors.layerSelectedHover02,
    _ => colors.layerSelectedHover03,
  };

  Color layerAccent(int level) => switch (level.clamp(1, 3)) {
    1 => colors.layerAccent01,
    2 => colors.layerAccent02,
    _ => colors.layerAccent03,
  };

  /// Field fill for components placed in layer context [level].
  Color field(int level) => switch (level.clamp(1, 3)) {
    1 => colors.field01,
    2 => colors.field02,
    _ => colors.field03,
  };

  Color fieldHover(int level) => switch (level.clamp(1, 3)) {
    1 => colors.fieldHover01,
    2 => colors.fieldHover02,
    _ => colors.fieldHover03,
  };

  Color borderSubtle(int level) => switch (level.clamp(0, 3)) {
    0 => colors.borderSubtle00,
    1 => colors.borderSubtle01,
    2 => colors.borderSubtle02,
    _ => colors.borderSubtle03,
  };

  Color borderStrong(int level) => switch (level.clamp(1, 3)) {
    1 => colors.borderStrong01,
    2 => colors.borderStrong02,
    _ => colors.borderStrong03,
  };

  CarbonThemeData copyWith({
    CarbonThemeScheme? scheme,
    CarbonDensity? density,
    CarbonColors? colors,
    Brightness? brightness,
    CarbonFonts? fonts,
    CarbonTypography? compactTypography,
    CarbonTypography? touchTypography,
    double? touchTarget,
  }) {
    // A new scheme without explicit colors takes that scheme's palette;
    // otherwise the current (possibly custom) colors carry over.
    final nextScheme = scheme ?? this.scheme;
    return CarbonThemeData(
      scheme: nextScheme,
      density: density ?? this.density,
      colors: colors ?? (scheme == null ? this.colors : nextScheme.colors),
      brightness:
          brightness ?? (scheme == null ? this.brightness : nextScheme.brightness),
      fonts: fonts ?? this.fonts,
      compactTypography: compactTypography ?? _compactTypography,
      touchTypography: touchTypography ?? _touchTypography,
      touchTarget: touchTarget ?? this.touchTarget,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CarbonThemeData &&
      other.scheme == scheme &&
      other.density == density &&
      other.colors == colors &&
      other.brightness == brightness &&
      other.fonts == fonts &&
      other._compactTypography == _compactTypography &&
      other._touchTypography == _touchTypography &&
      other.touchTarget == touchTarget;

  @override
  int get hashCode => Object.hash(
    scheme,
    density,
    colors,
    brightness,
    fonts,
    _compactTypography,
    _touchTypography,
    touchTarget,
  );
}

// Typography is a pure function of (density, fonts); memoizing keeps the
// `typography` getter cheap in hot builds without a mutable field on the
// immutable theme.
final Map<(CarbonDensity, CarbonFonts), CarbonTypography> _typographyCache =
    <(CarbonDensity, CarbonFonts), CarbonTypography>{};

CarbonTypography _typographyFor(CarbonDensity density, CarbonFonts fonts) =>
    _typographyCache.putIfAbsent(
      (density, fonts),
      () => CarbonTypography.forDensity(
        density,
        sansFamily: fonts.sans,
        monoFamily: fonts.mono,
        fontPackage: fonts.package,
        fontFamilyFallback: fonts.fallback,
      ),
    );

/// Supplies [CarbonThemeData] to a subtree.
///
/// Scope Carbon to the surfaces that use it; nesting is supported, and an
/// inner scope may change only [density]. Changing [data] rebuilds dependents
/// in place — nothing remounts, so text, focus and scroll state survive.
///
/// Also sets the subtree's default text style and icon theme, so plain [Text]
/// and [CarbonIcon] inside a Carbon surface start from Carbon roles.
class CarbonTheme extends StatefulWidget {
  const CarbonTheme({
    super.key,
    required this.data,
    this.density,
    required this.child,
  });

  final CarbonThemeData data;

  /// Overrides [CarbonThemeData.density] for this subtree.
  final CarbonDensity? density;

  final Widget child;

  static final CarbonThemeData _fallback = CarbonThemeData();

  /// The nearest theme, or Carbon White compact when there is none.
  static CarbonThemeData of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_CarbonThemeScope>()?.data ??
      _fallback;

  /// A listenable that follows the nearest scope's theme, for content that
  /// cannot inherit it — chiefly Navigator routes pushed from inside a scoped
  /// subtree. Null when no scope exists. Use [CarbonScopeRelay] rather than
  /// calling this directly.
  static ValueListenable<CarbonThemeData>? listenableOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_CarbonThemeScope>()?.listenable;

  @override
  State<CarbonTheme> createState() => _CarbonThemeState();
}

class _CarbonThemeState extends State<CarbonTheme> {
  late final ValueNotifier<CarbonThemeData> _live = ValueNotifier(_resolved);

  CarbonThemeData get _resolved {
    final density = widget.density;
    return density == null || density == widget.data.density
        ? widget.data
        : widget.data.copyWith(density: density);
  }

  @override
  void didUpdateWidget(CarbonTheme oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = _resolved;
    if (next == _live.value) return;
    // Listeners live in other routes' subtrees; notifying them during this
    // build would mark non-descendants dirty mid-build. Relay on the next
    // frame instead — the scope's own dependents rebuild immediately.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) _live.value = _resolved;
      });
      SchedulerBinding.instance.ensureVisualUpdate();
    } else {
      _live.value = next;
    }
  }

  @override
  void dispose() {
    _live.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final data = _resolved;
    final type = data.typography;
    return _CarbonThemeScope(
      data: data,
      listenable: _live,
      child: DefaultTextStyle.merge(
        style: type.body.copyWith(color: data.colors.textPrimary),
        child: IconTheme.merge(
          data: IconThemeData(
            color: data.colors.iconPrimary,
            size: data.iconSize,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

class _CarbonThemeScope extends InheritedWidget {
  const _CarbonThemeScope({
    required this.data,
    required this.listenable,
    required super.child,
  });

  final CarbonThemeData data;
  final ValueListenable<CarbonThemeData> listenable;

  @override
  bool updateShouldNotify(_CarbonThemeScope old) => old.data != data;
}

/// Carbon's surface layering context.
///
/// [level] names which token set components in this subtree use: on the page
/// background they use the `01` set (`field01`, `layer01`); inside a surface
/// painted `layer01` they use `02`, and so on up to 3. Most code should use
/// [CarbonLayerSurface], which paints the current layer and raises the level
/// for its children.
class CarbonLayer extends InheritedWidget {
  const CarbonLayer({super.key, required this.level, required super.child})
    : assert(level >= 1 && level <= 3);

  final int level;

  /// The current layer level; 1 when no [CarbonLayer] encloses [context].
  static int of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CarbonLayer>()?.level ?? 1;

  @override
  bool updateShouldNotify(CarbonLayer old) => old.level != level;
}

/// A container painted with the current layer's surface color whose children
/// sit one layer up.
class CarbonLayerSurface extends StatelessWidget {
  const CarbonLayerSurface({
    super.key,
    this.padding,
    this.border = false,
    required this.child,
  });

  final EdgeInsetsGeometry? padding;

  /// Draws a 1px subtle border, for surfaces that sit on the same fill.
  final bool border;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final level = CarbonLayer.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.layer(level),
        border: border
            ? Border.all(color: theme.borderSubtle(level))
            : null,
      ),
      child: Padding(
        padding: padding ?? EdgeInsets.zero,
        child: CarbonLayer(level: (level + 1).clamp(1, 3), child: child),
      ),
    );
  }
}

/// Carries Carbon configuration from a trigger into content mounted elsewhere
/// in the tree, such as a Navigator route.
///
/// A one-time `InheritedTheme.capture` would freeze the theme for the life of
/// an open dialog. The relay instead follows the trigger's scope, so theme and
/// density changes reach an open modal without remounting it — entered text
/// and focus survive. Localizations and text direction are captured at open.
class CarbonScopeRelay {
  CarbonScopeRelay._(
    this._live,
    this._snapshot,
    this._messages,
    this._direction,
  );

  /// Captures the configuration visible from [context].
  factory CarbonScopeRelay.of(BuildContext context) => CarbonScopeRelay._(
    CarbonTheme.listenableOf(context),
    CarbonTheme.of(context),
    CarbonLocalizations.of(context),
    Directionality.maybeOf(context) ?? TextDirection.ltr,
  );

  final ValueListenable<CarbonThemeData>? _live;
  final CarbonThemeData _snapshot;
  final CarbonLocalizations _messages;
  final TextDirection _direction;

  /// Wraps [child] in the captured configuration.
  Widget wrap(Widget child) {
    Widget themed(CarbonThemeData data) => CarbonTheme(
      data: data,
      child: CarbonLocalizationsScope(
        messages: _messages,
        child: Directionality(textDirection: _direction, child: child),
      ),
    );
    final live = _live;
    if (live == null) return themed(_snapshot);
    return ValueListenableBuilder<CarbonThemeData>(
      valueListenable: live,
      builder: (context, data, _) => themed(data),
    );
  }
}
