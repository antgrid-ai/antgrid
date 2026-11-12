# Changelog

## 0.1.0 (unreleased)

Initial release. Exercised with `flutter test` and built as a Windows desktop
gallery only; see "Verification status" in `doc/coverage.md`.

### Foundations

- Carbon v11 semantic color roles with the White, Gray 10, Gray 90 and Gray 100
  themes, explicit compact and touch density, density-resolved typography
  (IBM Plex Sans and Mono bundled), spacing, size, border and motion tokens,
  layer helpers, bundled Carbon icons as path data, and overridable
  localizations.
- `CarbonThemeData.touchTarget` (default 48) sets the touch-density control
  height, small control height and minimum target in one place, so a host can
  follow a 44 pt guideline without per-component overrides.
- `CarbonTheme`, `CarbonLayer`, `CarbonLayerSurface` and `CarbonScopeRelay`
  for scoping theme, density and layer context, including into Navigator
  routes.
- `CarbonContrast` for WCAG contrast checks of built-in and custom palettes.
- `CarbonLicenses.register()` for the bundled font and icon notices.

### Primitives

- `CarbonInteraction` (focus, hover, press, keyboard activation, semantics),
  `CarbonFocusRing`, `CarbonFieldFrame` and `CarbonFieldBox`,
  `CarbonAnchoredPopup` with `CarbonPopupController`, and `CarbonOption`.
- `CarbonFieldFrame.announceError` keeps an error as a polite live region
  for fields whose status line already carries one (Search uses it).
- `CarbonFieldBox.paddingX` (16 px text inset), `hoverable` (no hover fill for
  text input and search) and `startPadding`, the last two also on
  `CarbonActionFieldBox`, and `expanded` (an open list box
  draws a `border-subtle` bottom rule).
- `CarbonFieldAction.pressedFill` with `CarbonFieldActionPress` (`selected` or
  `active`) for the fill of a pressed field action.

### Components

- Button: `CarbonButton` (seven kinds, icon-only with tooltip, five sizes,
  busy, optional `minWidth`; `iconSize` and `hoverFill` on icon-only buttons)
  and `CarbonButtonSet`, whose end-aligned row buttons are at least 196 px columns.
- Text input: `CarbonTextInput` with single-line, password and multiline
  variants, clear and reveal actions, and a counter.
- Form: `CarbonForm`, `CarbonFormSection`, `CarbonFormActions`,
  `CarbonFormController` (focus the first invalid field) and
  `CarbonFormFieldRegistrar`, whose optional `announcement` is spoken when
  the first invalid field already has focus.
- Search: `CarbonSearch` with host-fed busy, error and result count.
- Select: `CarbonSelect`.
- Dropdown: `CarbonDropdown` and the searchable `CarbonComboBox`.
- Checkbox: `CarbonCheckbox` (including indeterminate, and `invalid` for a border without a message of its own) and
  `CarbonCheckboxGroup`.
- Toggle: `CarbonToggle` with a busy state.
- Tabs: `CarbonTabs` (line and contained, automatic and manual activation,
  overflow scrolling) and `CarbonTabPanels`.
- Content switcher: `CarbonContentSwitcher`.
- Menu: `CarbonMenu` (optional `rowHeight` and `border`) with items, check
  items, radio groups, groups, dividers and submenus, and `CarbonContextMenu`.
- Menu button: `CarbonMenuButton`, `CarbonOverflowMenu` and
  `CarbonSplitButton`.
- Modal: `CarbonModal` (informational, confirmation, form) presented with
  `showCarbonModal` and pluggable `CarbonModalPresentation`s.
- Tooltip: `CarbonTooltip`.
- Notification: `CarbonNotification` (title, subtitle or both, as in
  Carbon), `CarbonToast`, `CarbonToastController` and `CarbonToastOverlay`.
- Loading: `CarbonLoading`, `CarbonLoadingOverlay` and `CarbonSpinner`.
- Inline loading: `CarbonInlineLoading`.
- Tag: `CarbonTag` (read-only, dismissible, selectable, operational).
- Contained list: `CarbonContainedList`, `CarbonContainedListSliver` and
  `CarbonContainedListRow` (optional `disabled`).

### Gallery

- `example/` gallery covering every family and foundation, with theme,
  density, text scale, direction, reduced motion and width settings, and five
  compositions: settings form, action toolbar, list with row actions,
  searchable picker and confirmation flow.
