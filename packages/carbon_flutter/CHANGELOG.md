# Changelog

## 0.1.0 (unreleased)

Initial release. Exercised with `flutter test` and as a Windows desktop
gallery only; see "Verification status" in `doc/coverage.md`.

### Foundations

- Carbon v11 semantic color roles with the White, Gray 10, Gray 90 and Gray 100
  themes, explicit compact and touch density, density-resolved typography
  (IBM Plex Sans and Mono bundled), spacing, size, border and motion tokens,
  layer helpers, bundled Carbon icons as path data, and overridable
  localizations.
- `CarbonTheme`, `CarbonLayer`, `CarbonLayerSurface` and `CarbonScopeRelay`
  for scoping theme, density and layer context, including into Navigator
  routes.
- `CarbonContrast` for WCAG contrast checks of built-in and custom palettes.
- `CarbonLicenses.register()` for the bundled font and icon notices.

### Primitives

- `CarbonInteraction` (focus, hover, press, keyboard activation, semantics),
  `CarbonFocusRing`, `CarbonFieldFrame` and `CarbonFieldBox`,
  `CarbonAnchoredPopup` with `CarbonPopupController`, and `CarbonOption`.

### Components

- Button: `CarbonButton` (seven kinds, icon-only with tooltip, four sizes,
  busy) and `CarbonButtonSet`.
- Text input: `CarbonTextInput` with single-line, password and multiline
  variants, clear and reveal actions, and a counter.
- Form: `CarbonForm`, `CarbonFormSection`, `CarbonFormActions`,
  `CarbonFormController` (focus the first invalid field) and
  `CarbonFormFieldRegistrar`.
- Search: `CarbonSearch` with host-fed busy, error and result count.
- Select: `CarbonSelect`.
- Dropdown: `CarbonDropdown` and the searchable `CarbonComboBox`.
- Checkbox: `CarbonCheckbox` (including indeterminate) and
  `CarbonCheckboxGroup`.
- Toggle: `CarbonToggle` with a busy state.
- Tabs: `CarbonTabs` (line and contained, automatic and manual activation,
  overflow scrolling) and `CarbonTabPanels`.
- Content switcher: `CarbonContentSwitcher`.
- Menu: `CarbonMenu` with items, check items, radio groups, groups,
  dividers and submenus, and `CarbonContextMenu`.
- Menu button: `CarbonMenuButton`, `CarbonOverflowMenu` and
  `CarbonSplitButton`.
- Modal: `CarbonModal` (informational, confirmation, form) presented with
  `showCarbonModal` and pluggable `CarbonModalPresentation`s.
- Tooltip: `CarbonTooltip`.
- Notification: `CarbonNotification`, `CarbonToast`, `CarbonToastController`
  and `CarbonToastOverlay`.
- Loading: `CarbonLoading`, `CarbonLoadingOverlay` and `CarbonSpinner`.
- Inline loading: `CarbonInlineLoading`.
- Tag: `CarbonTag` (read-only, dismissible, selectable, operational).
- Contained list: `CarbonContainedList`, `CarbonContainedListSliver` and
  `CarbonContainedListRow`.

### Gallery

- `example/` gallery covering every family and foundation, with theme,
  density, text scale, direction, reduced motion and width settings, and five
  compositions: settings form, action toolbar, list with row actions,
  searchable picker and confirmation flow.
