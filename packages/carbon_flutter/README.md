# carbon_flutter

An independently maintained Flutter implementation of the
[Carbon Design System](https://carbondesignsystem.com). It is not an official
Carbon framework and is not endorsed by IBM. It follows Carbon v11 and
documents every place where Flutter, touch input or accessibility required a
different behaviour (see `doc/deviations.md`).

Its distinguishing choice is explicit density: every control exists in a
**compact** (32 px, pointer and keyboard) and a **touch** (48 px, finger)
form, chosen by the host rather than inferred from the window.

The first consumer is Antgrid; nothing in the package depends on it.

## Install

The package is not published. Use a path dependency:

```yaml
dependencies:
  carbon_flutter:
    path: ../path/to/packages/carbon_flutter
```

The IBM Plex fonts and licence texts are bundled as package assets and need no
extra pubspec entries in the consuming app.

## Set up the theme

Scope Carbon to the surfaces that use it:

```dart
import 'package:carbon_flutter/carbon_flutter.dart';

CarbonTheme(
  data: CarbonThemeData(
    scheme: CarbonThemeScheme.gray100,
    density: CarbonDensity.compact,
  ),
  child: const MyScreen(),
)
```

- Change `data` to switch theme or density. Dependents rebuild in place;
  nothing remounts, so text, focus and scroll state survive.
- `CarbonTheme.of(context)` returns the nearest theme, or White compact when
  there is none.
- Nest a `CarbonTheme` with `density:` to change density for one subtree.
- Content in a Navigator route (modals) does not inherit from the trigger. Wrap
  it with `CarbonScopeRelay.of(context).wrap(child)` so it follows the live
  theme.

## Choosing a density

Density is a host decision. Never derive it from viewport width or pointer
kind alone.

| Use | Density |
| --- | --- |
| Phones and tablets, including wide tablets | touch |
| Desktop with pointer and keyboard | compact |
| Desktop for a touch-first workflow | touch (host choice) |

Hover feedback is independent of density; touch controls still react to a
pointer. Text scaling stays enabled in both: controls grow rather than clip.

## Fonts and licences

IBM Plex Sans and Mono are declared by this package and resolve as
`packages/carbon_flutter/IBM Plex Sans` and `.../IBM Plex Mono`, so no network
request is made at runtime. To substitute families:

```dart
CarbonThemeData(
  fonts: const CarbonFonts(sans: 'Inter', mono: 'Fira Code', package: null),
)
```

Substituted fonts change metrics; check them in the gallery.

Register the bundled font and icon notices once at startup so they appear in
Flutter's licence page:

```dart
WidgetsFlutterBinding.ensureInitialized();
CarbonLicenses.register();
```

## Public API overview

Import only `package:carbon_flutter/carbon_flutter.dart`.

| Area | Names |
| --- | --- |
| Theme | `CarbonTheme`, `CarbonThemeData`, `CarbonThemeScheme`, `CarbonDensity`, `CarbonFonts`, `CarbonScopeRelay` |
| Layers | `CarbonLayer`, `CarbonLayerSurface`, layer helpers on `CarbonThemeData` |
| Color | `CarbonColors`, `CarbonTagColors` |
| Type | `CarbonTypography` |
| Tokens | `CarbonSpacing`, `CarbonSizes`, `CarbonBorders`, `CarbonShape`, `CarbonMotion` |
| Icons | `CarbonIcon`, `CarbonIcons` |
| Text | `CarbonLocalizations`, `CarbonLocalizationsScope` |
| Accessibility | `CarbonContrast`, `CarbonContrastIssue` |
| Legal | `CarbonLicenses` |

Component families (buttons, fields, menus, modals and so on) are listed in
`doc/coverage.md` with their status.

## Custom themes

Override values, not meanings: `CarbonColors.copyWith` on a built-in palette,
then check it with `CarbonContrast.validate`. See `doc/theming.md`.

## Documentation

- `doc/carbon-baseline.md`: pinned Carbon versions and regeneration.
- `doc/theming.md`: themes, custom palettes, density, layers.
- `doc/carbon-to-flutter.md`: mapping guide for contributors and agents.
- `doc/deviations.md`: where and why this package differs from Carbon web.
- `doc/coverage.md`: foundation and component coverage matrix.

## Running tests and the gallery

```bash
cd packages/carbon_flutter
flutter test

cd example
flutter run -d windows   # or macos, linux, an emulator
```

The gallery shows every family in both densities and all four themes.

## Licence

MPL-2.0 for the package source (`LICENSE`). Bundled fonts, icons and tokens
keep their own licences; see `NOTICE`.
