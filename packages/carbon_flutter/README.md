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

## Components

| Family | Classes |
| --- | --- |
| Button | `CarbonButton`, `CarbonButton.iconOnly`, `CarbonButtonSet` |
| Text input | `CarbonTextInput` (single-line, password, multiline) |
| Form | `CarbonForm`, `CarbonFormSection`, `CarbonFormActions`, `CarbonFormController`, `CarbonFormFieldRegistrar` |
| Search | `CarbonSearch` |
| Select | `CarbonSelect` |
| Dropdown | `CarbonDropdown`, `CarbonComboBox` |
| Checkbox | `CarbonCheckbox`, `CarbonCheckboxGroup` |
| Toggle | `CarbonToggle` |
| Tabs | `CarbonTabs`, `CarbonTabPanels` |
| Content switcher | `CarbonContentSwitcher` |
| Menu | `CarbonMenu`, `CarbonContextMenu` and its entries (`CarbonMenuItem`, `CarbonMenuCheckItem`, `CarbonMenuRadioGroup`, `CarbonMenuGroup`, `CarbonMenuDivider`, `CarbonMenuSubmenu`) |
| Menu button | `CarbonMenuButton`, `CarbonOverflowMenu`, `CarbonSplitButton` |
| Modal | `CarbonModal`, `showCarbonModal`, `CarbonModalPresentation` |
| Tooltip | `CarbonTooltip` |
| Notification | `CarbonNotification`, `CarbonToast`, `CarbonToastController`, `CarbonToastOverlay` |
| Loading | `CarbonLoading`, `CarbonLoadingOverlay`, `CarbonSpinner` |
| Inline loading | `CarbonInlineLoading` |
| Tag | `CarbonTag` |
| Contained list | `CarbonContainedList`, `CarbonContainedListSliver`, `CarbonContainedListRow` |

`doc/coverage.md` lists the supported variants, deferred items, tests and
gallery page for each family. To choose between Select, Dropdown, Menu and
Menu button, see the decision guide in `doc/carbon-to-flutter.md`.

Components never fetch, persist or debounce. Values, validation results and
busy flags come from the host, and callbacks report requested changes.

## Platform status

Only `flutter test` and the gallery running as a Windows desktop app have
been exercised. iOS, Android, macOS, Linux and web have not been built or run,
and screen-reader, IME and autofill behaviour has not been checked on a
device. See "Verification status" in `doc/coverage.md`.

## Install

The package is not published. Add it as a path dependency:

```yaml
dependencies:
  carbon_flutter:
    path: ../path/to/packages/carbon_flutter
```

It needs Flutter 3.47.1 or later (Dart 3.11). The IBM Plex fonts and licence
texts are bundled as package assets and need no extra pubspec entries in the
consuming app.

Register the bundled font and icon notices once at startup so they appear in
Flutter's licence page:

```dart
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  CarbonLicenses.register();
  runApp(const MyApp());
}
```

Text inputs, search and the combo box use Flutter's `TextField` for editing,
so the app must provide `MaterialLocalizations` (for example through
`DefaultMaterialLocalizations.delegate`), as any `TextField` requires. No
Material visuals are used.

## Theme and density

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

To follow the system appearance, map brightness yourself; the package never
reads it:

```dart
final brightness = MediaQuery.platformBrightnessOf(context);
CarbonTheme(
  data: CarbonThemeData.forBrightness(
    brightness, // light: White, dark: Gray 100
    density: CarbonDensity.touch,
  ),
  child: const MyScreen(),
)
```

- Change `data` to switch theme or density. Dependents rebuild in place;
  nothing remounts, so text, focus and scroll state survive.
- `CarbonTheme.of(context)` returns the nearest theme, or White compact when
  there is none.
- To change density for one subtree, nest a scope that overrides only
  density:

  ```dart
  CarbonTheme(
    data: CarbonTheme.of(context),
    density: CarbonDensity.touch,
    child: const TouchPanel(),
  )
  ```

### Choosing a density

Density is a host decision. Never derive it from viewport width or pointer
kind alone.

| Use | Density |
| --- | --- |
| Phones and tablets, including wide tablets | touch |
| Desktop with pointer and keyboard | compact |
| Desktop for a touch-first workflow | touch (host choice) |

Hover feedback is independent of density; touch controls still react to a
pointer. Text scaling stays enabled in both: controls grow rather than clip.

## Modals and other routes

Content in a Navigator route does not inherit from the widget that pushed it.
Present dialogs with `showCarbonModal`, which carries the theme across for
you:

```dart
final confirmed = await showCarbonModal<bool>(
  context,
  builder: (context) => CarbonModal.confirmation(
    title: 'Delete branch?',
    body: const Text('This cannot be undone.'),
    danger: true,
    secondary: CarbonModalAction(
      label: 'Cancel',
      onPressed: () => Navigator.of(context).pop(false),
    ),
    primary: CarbonModalAction(
      label: 'Delete',
      onPressed: () => Navigator.of(context).pop(true),
    ),
  ),
);
```

The modal follows the presenting context's theme and density live through a
`CarbonScopeRelay`: switching them while it is open updates it in place and
keeps typed text and focus. Localizations and text direction are captured when
it opens. `canDismiss` lets the host veto Escape, back and barrier dismissal
while work is in flight; `presentation` (or a `CarbonModalPresentationScope`)
chooses centered, full-screen, adaptive or a host-supplied presentation.

For any other route, wrap its content with
`CarbonScopeRelay.of(context).wrap(child)`. Menus, listboxes and tooltips use
`OverlayPortal` and inherit from their anchor without a relay.

## Fonts

IBM Plex Sans and Mono are declared by this package and resolve as
`packages/carbon_flutter/IBM Plex Sans` and `.../IBM Plex Mono`, so no network
request is made at runtime. To substitute families:

```dart
CarbonThemeData(
  fonts: const CarbonFonts(sans: 'Inter', mono: 'Fira Code', package: null),
)
```

Substituted fonts change metrics; check them in the gallery.

## Custom themes

Override values, not meanings: `CarbonColors.copyWith` on a built-in palette,
then check it with `CarbonContrast.validate`. See `doc/theming.md`.

## Gallery

The runnable gallery in `example/` shows every family, the foundations and
five compositions (settings form, action toolbar, list with row actions,
searchable picker, confirmation flow). Its settings switch theme, density,
text scale (up to 200%), direction, reduced motion and preview width (320,
390, 768, 1280 or fill).

```bash
cd example
flutter run -d windows
```

Each component page carries usage, keyboard and accessibility notes and its
Carbon reference.

## Tests

```bash
cd packages/carbon_flutter
flutter test          # the package suite (test/); `flutter test .` would also collect the gallery's tests

cd example
flutter test          # gallery smoke and composition tests
```

## Documentation

- `doc/coverage.md`: foundation and component coverage, and what has been
  verified.
- `doc/deviations.md`: where and why this package differs from Carbon web.
- `doc/carbon-to-flutter.md`: Carbon React to Flutter mapping and the
  Select, Dropdown, Menu or Menu button guide.
- `doc/theming.md`: themes, custom palettes, density, layers and routes.
- `doc/carbon-baseline.md`: pinned Carbon versions and regeneration.

## Licence

MPL-2.0 for the package source (`LICENSE`). Bundled fonts, icons and tokens
keep their own licences; see `NOTICE`.
