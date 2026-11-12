# Deviations from Carbon web

Every place this package behaves differently from Carbon web, with the reason
and the evidence that supports it. Add a row in the same change that
introduces a deviation.

| Item | Carbon web behaviour | Flutter adaptation | Reason | Evidence |
| --- | --- | --- | --- | --- |
| Touch density floor | Control sizes 24, 32, 40, 48 px chosen per component (`sm`, `md`, `lg`); no touch-specific mode | Two explicit densities: compact 32 px, touch 48 px; small variant is 24 px compact and 48 px touch; icon buttons 32 / 48 px targets | Finger targets need at least 48 px on every native target; density is a host choice, not a viewport guess | `test/foundations/theme_data_test.dart` (density metrics) |
| Icons as path data | SVG files or components per icon | Glyphs converted to path data in `icons.g.dart` and painted by `CarbonIcon` | Synchronous paint, single-color tinting, identical rendering in tests, no asset lookups | `test/foundations/icon_test.dart`; `NOTICE` |
| Focus ring painted inset | CSS `outline` around the element, which may extend outside it | 2 px ring painted inside the bounds as a foreground decoration, with an optional 1 px inner ring on filled controls | No layout shift, no clipping by scroll views and panes; Carbon already uses an inset ring for most controls | focus ring primitive tests (see `coverage.md`) |
| Touch typography roles | Carbon has productive and expressive sets; no touch-specific set | Control and body text 16 px, label and helper 14 px in touch density, same hierarchy | Readable finger-use text without shrinking to fit fixed boxes | `test/foundations/theme_data_test.dart` (typography follows density) |
| Menus and popups via `OverlayPortal` | Absolutely positioned DOM nodes with their own stacking | `OverlayPortal` anchored popups that flip, clamp to viewport, safe area and keyboard, and dismiss on outside tap, Escape and system back | Inherits theme and layer from the anchor and avoids Navigator routes for transient UI | popup primitive tests (see `coverage.md`) |
| Third-layer secondary text contrast | Gray 90 and Gray 100 secondary, helper and error text on layer 03 and field 03 is below 4.5:1 | Kept as Carbon defines it; excluded from the default contrast pair list and available in `CarbonContrast.extendedPairs` | Changing Carbon's palette values would break role fidelity; custom themes may opt into the stricter set | `test/foundations/contrast_test.dart` |
| Package-qualified font families | Fonts loaded by the page | Families resolve as `packages/carbon_flutter/IBM Plex Sans` and `.../IBM Plex Mono` | Fonts ship inside the package with no network request | `test/foundations/theme_data_test.dart` (typography families) |
| Navigator routes do not inherit the theme | Portals inherit CSS from the document | `CarbonScopeRelay` carries the live theme into routes | Routes are mounted above the trigger's subtree | `test/foundations/theme_widget_test.dart` (CarbonScopeRelay) |

Component rows are added as each family lands.
