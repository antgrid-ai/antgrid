# Theming

## The four themes

`CarbonThemeScheme` selects a built-in palette: `white`, `gray10` (light) and
`gray90`, `gray100` (dark). `CarbonThemeData.forBrightness` maps light to White
and dark to Gray 100 for hosts that follow system appearance. The host decides;
the package never reads the platform brightness on its own.

Switching scheme through `copyWith(scheme: ...)` takes that scheme's palette.
Passing `colors:` as well keeps the supplied palette.

## Custom themes

A custom theme overrides values, never meanings. Start from a built-in palette
and replace roles:

```dart
final colors = CarbonColors.gray100.copyWith(
  interactive: const Color(0xFF3DDBD9),
  focus: const Color(0xFFFFFFFF),
);
final theme = CarbonThemeData(
  scheme: CarbonThemeScheme.gray100,
  colors: colors,
);
```

Rules:

- Keep a role's meaning. `supportSuccess` is for success, not a brand accent;
  use `interactive` or `buttonPrimary` for primary actions.
- Change related roles together. `interactive`, `borderInteractive`,
  `linkPrimary`, `buttonPrimary` and `focus` move as a family.
- Do not recolor per screen. Put the palette in one place and pass it to
  `CarbonTheme`.
- Brightness must match the palette (`brightness:`) when it differs from the
  scheme.

Custom colors carry over `copyWith` calls that do not name a scheme, so
density switches never lose them.

## Validating a palette

```dart
final issues = CarbonContrast.validate(colors);
for (final issue in issues) {
  debugPrint('$issue'); // e.g. textHelper on layer01: 3.90:1 (needs 4.5:1)
}
```

`validate` checks the default and interactive pairs components paint: primary,
secondary, helper and error text on the background, layers and fields; text on
filled buttons; icon, focus, strong border, error and interactive colors as
3:1 non-text marks. It excludes roles WCAG exempts (placeholder and disabled
text and icons) and decorative subtle borders. Carbon's own Gray 90 and Gray
100 themes fall below 4.5:1 for secondary, helper and error text on the third
layer, so those pairs are only in `CarbonContrast.extendedPairs`. Pass
`pairs: CarbonContrast.extendedPairs` to hold a custom palette to the stricter
bar. An empty result is necessary, not sufficient, for WCAG conformance.

## Density

Density is explicit. Set it on `CarbonThemeData` or override it for a subtree:

```dart
CarbonTheme(data: theme, density: CarbonDensity.touch, child: ...)
```

| | Compact | Touch |
| --- | --- | --- |
| Control height | 32 | 48 |
| Small control | 24 | 48 |
| Large control | 48 | 64 |
| Minimum target | 32 | 48 |
| Icon size | 16 | 20 |
| Control padding | 12 | 16 |
| Control text | 14 | 16 |
| Label and helper text | 12 | 14 |

Selection rules: phones and tablets use touch regardless of width; a desktop
with pointer and keyboard uses compact; a desktop host may choose touch for
touch-first use. Heights are minimums at ordinary text scale and grow with
enlarged text. Touch never shrinks below 48 px, including the small variant.
Hover feedback is independent of density.

## Layers

Carbon raises surfaces in levels: page background, then layer 01, 02, 03.
Components use the token set matching the layer they sit on (`field01` on the
page, `field02` inside a layer-01 surface, and so on).

`CarbonLayerSurface` paints the current layer and raises its children by one
level, capped at 3. `CarbonLayer.of(context)` reads the level (1 when absent).
Theme helpers resolve the token for a level and clamp out-of-range values:
`layer`, `layerHover`, `layerActive`, `layerSelected`, `layerSelectedHover`
(0-3, where 0 is the page), `layerAccent`, `field`, `fieldHover`,
`borderStrong` (1-3) and `borderSubtle` (0-3).

## Overlays and routes

Content in an `OverlayPortal` inherits from its anchor. Content in a Navigator
route does not; wrap it with `CarbonScopeRelay.of(context).wrap(child)`, which
follows the live theme (so an open modal updates without remounting) and
captures localizations and text direction at open time.
