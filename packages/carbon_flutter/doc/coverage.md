# Coverage

Each row lists what is supported, what is deferred, adaptations (see
`deviations.md`), where it is tested and where the gallery shows it. Rows
marked pending are not yet filled.

## Foundations

| ID | Foundation | Supported variants | Deferred | Adaptations | Tests | Gallery |
| --- | --- | --- | --- | --- | --- | --- |
| F01 | Semantic tokens | All Carbon v11 roles in four themes; `copyWith` custom palettes | Component-specific tokens beyond semantic roles | none | `test/foundations/theme_data_test.dart` | pending |
| F02 | Themes and layering | White, Gray 10, Gray 90, Gray 100; custom palettes; three layer levels; live theme relay into routes; contrast validation | Automatic system-appearance following (host decides) | Third-layer secondary text pairs outside default validation | `theme_data_test.dart`, `theme_widget_test.dart`, `contrast_test.dart` | pending |
| F03 | Typography | Eight density-resolved roles; bundled Plex Sans and Mono; family substitution | Expressive type sets | Touch roles | `theme_data_test.dart` | pending |
| F04 | Layout and composition | Spacing 01-13, sizes, borders, shapes, control metrics | Layout helpers beyond tokens | Density metrics | `theme_data_test.dart` | pending |
| F05 | Icons and naming | Bundled glyphs as path data; decorative by default; labelled icons announced; RTL mirroring of directional glyphs; any widget accepted by controls | Full icon catalog | Path data | `test/foundations/icon_test.dart` | pending |
| F06 | Interaction states | Interaction core in the primitives | n/a for foundations | Focus ring inset | pending | pending |
| F07 | Focus and keyboard | Focus ring and interaction primitives | n/a for foundations | Focus ring inset | pending | pending |
| F08 | Accessibility and localization | Semantics for icons; overridable strings by delegate or scope; RTL; contrast check API | Platform high-contrast theming | none | `localizations_test.dart`, `icon_test.dart`, `contrast_test.dart` | pending |
| F09 | Overlays and scrolling | Anchored popup primitive; scope relay for routes | n/a for foundations | `OverlayPortal` popups | `theme_widget_test.dart` (relay); popup tests pending | pending |
| F10 | Motion and feedback | Named durations and curves; reduced-motion resolution | Haptics | none | pending | pending |

## Components

| ID | Family | Supported variants | Deferred | Adaptations | Tests | Gallery |
| --- | --- | --- | --- | --- | --- | --- |
| C01 | Button (`CarbonButton`) | pending | pending | pending | pending | pending |
| C02 | Text input (`CarbonTextInput`) | pending | pending | pending | pending | pending |
| C03 | Form (`CarbonForm`, `CarbonFormSection`) | pending | pending | pending | pending | pending |
| C04 | Search (`CarbonSearch`) | pending | pending | pending | pending | pending |
| C05 | Select (`CarbonSelect`) | pending | pending | pending | pending | pending |
| C06 | Dropdown (`CarbonDropdown`) | pending | pending | pending | pending | pending |
| C07 | Checkbox (`CarbonCheckbox`) | pending | pending | pending | pending | pending |
| C08 | Toggle (`CarbonToggle`) | pending | pending | pending | pending | pending |
| C09 | Tabs (`CarbonTabs`) | pending | pending | pending | pending | pending |
| C10 | Content switcher (`CarbonContentSwitcher`) | pending | pending | pending | pending | pending |
| C11 | Menu (`CarbonMenu`) | pending | pending | pending | pending | pending |
| C12 | Menu button (`CarbonMenuButton`, `CarbonSplitButton`) | pending | pending | pending | pending | pending |
| C13 | Modal (`CarbonModal`) | pending | pending | pending | pending | pending |
| C14 | Tooltip (`CarbonTooltip`) | pending | pending | pending | pending | pending |
| C15 | Notification (`CarbonNotification`, `CarbonToast`) | pending | pending | pending | pending | pending |
| C16 | Loading (`CarbonLoading`) | pending | pending | pending | pending | pending |
| C17 | Inline loading (`CarbonInlineLoading`) | pending | pending | pending | pending | pending |
| C18 | Tag (`CarbonTag`) | pending | pending | pending | pending | pending |
| C19 | Contained list (`CarbonContainedList`) | pending | pending | pending | pending | pending |
