# Carbon to Flutter mapping

For contributors and agents adding or changing a Carbon-derived widget. Use the
Carbon MCP server (when available) to read the Carbon component spec, tokens
and accessibility notes before implementing, then record any difference in
`deviations.md`.

## Tokens and roles

| Carbon | Dart |
| --- | --- |
| Semantic color token (`$text-primary`, `$layer-01`) | `CarbonTheme.of(context).colors.textPrimary`, `.layer01` |
| Layer-indexed token | `theme.layer(level)`, `theme.field(level)`, `theme.borderStrong(level)` with `level = CarbonLayer.of(context)` |
| Tag color set | `colors.tagBlue` etc. (`CarbonTagColors`) |
| Type style (`body-compact-01`) | `theme.typography.control` / `.body` / `.label` / `.helper` / `.heading` / `.headingLarge` / `.title` / `.code` |
| `$spacing-0x` | `CarbonSpacing.spacing0x` |
| `$size-*` and control height | `CarbonSizes.*`; `theme.controlHeight`, `.smallControlHeight`, `.largeControlHeight` |
| Border widths | `CarbonBorders.hairline/focus/indicator/selectedTab` |
| Radius | `CarbonShape.*` (square by default) |
| Duration and easing | `CarbonMotion.fast01 ... slow02`, `.standard/.entrance/.exit`, `CarbonMotion.resolve(context, d)` |
| Icon | `CarbonIcon(CarbonIcons.x)` |
| Translatable string | `CarbonLocalizations.of(context)` |

Pick a role by meaning. Never copy a hex value.

## Components

| Carbon component | Public class |
| --- | --- |
| Button | `CarbonButton` |
| Text input | `CarbonTextInput` |
| Form | `CarbonForm`, `CarbonFormSection` |
| Search | `CarbonSearch` |
| Select | `CarbonSelect` |
| Dropdown, combo box | `CarbonDropdown` |
| Checkbox | `CarbonCheckbox` |
| Toggle | `CarbonToggle` |
| Tabs | `CarbonTabs` |
| Content switcher | `CarbonContentSwitcher` |
| Menu | `CarbonMenu` |
| Menu button, overflow menu, combo button | `CarbonMenuButton`, `CarbonSplitButton` |
| Modal | `CarbonModal` |
| Tooltip | `CarbonTooltip` |
| Notification (inline, toast) | `CarbonNotification`, `CarbonToast` |
| Loading | `CarbonLoading` |
| Inline loading | `CarbonInlineLoading` |
| Tag | `CarbonTag` |
| Contained list | `CarbonContainedList` |

Components share primitives for interaction (focus, hover, press,
activation), the focus ring, the field frame and box, anchored popups and
options. Build on them instead of re-implementing.

## Web-only concepts

| Carbon web | Flutter |
| --- | --- |
| CSS custom properties and Sass tokens | `CarbonColors` roles and `CarbonThemeData` |
| `.cds--layer-*` theme zones | `CarbonLayer` and `CarbonLayerSurface` |
| `:hover`, `:active`, `:focus-visible` | `CarbonInteractionState` (hovered, pressed, focusVisible) |
| `outline` focus ring | inset ring painted as a foreground decoration |
| `position: absolute` menus and popovers | `OverlayPortal` anchored popups |
| Modal in portal with focus trap | Navigator route wrapped by `CarbonScopeRelay` |
| ARIA roles and `aria-*` | `Semantics` flags and labels |
| `aria-live` regions | `SemanticsService` announcements and live-region semantics |
| `prefers-reduced-motion` | `MediaQuery.disableAnimations` via `CarbonMotion.reduced` |
| `rem`/`em` text sizing, browser zoom | system text scale; controls grow, never clip |
| `dir="rtl"`, logical properties | `Directionality`, `EdgeInsetsDirectional`, `AlignmentDirectional` |
| Icon SVG assets | path data painted by `CarbonIcon` |
| Web fonts | bundled IBM Plex, no runtime fetch |

## Adding to the library

1. Read the Carbon spec for the component, including keyboard and
   accessibility sections.
2. Take every color, size, type style and duration from tokens above.
3. Support both densities, all four themes, RTL and enlarged text.
4. Record deviations in `deviations.md` and update `coverage.md`.
5. Add widget tests (heights in both densities, keyboard activation, disabled
   inertness, semantics, RTL, theme and density switch with live state) and a
   gallery page.
