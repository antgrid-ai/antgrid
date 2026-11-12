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

### Interaction-state fixes

- Text input and search paint selection handles in `text-primary` (Material and
  iOS), show a not-allowed cursor when disabled, and build their selection
  toolbar from Carbon colours instead of the host's Material theme. The
  multi-line text area no longer takes the host's `ScrollbarTheme`.
- A field box enabled under a resting pointer shows its hover fill at once, and
  a warning no longer insets the action hover fill.
- Controls show the keyboard focus ring on phones and tablets once a mouse is
  connected, and a control enabled under a resting pointer is hovered at once.
- A press already in flight when `CarbonLoadingOverlay` starts loading is
  cancelled instead of activating the covered control.
- Contained list rows hover and press on the content cell only, so hovering a
  trailing action leaves the content at rest, and the selection bar stays
  visible while a selected row is pressed.
- A selected contained list row shows a check mark after its text, and every
  row of the selection keeps room for it.
- Notification actions hover and press with `notification-action-hover`
  (`background-inverse-hover` and `link-inverse` text in high contrast), and
  the high-contrast close icon is `icon-inverse`.
- The modal close button hovers with `layer-hover`, and the modal body draws no
  host scrollbar.
- A pressed tab takes focus and the focus outline at once; the disabled
  contained label colour is recorded under C09-visuals.
- An open overflow trigger keeps its layer fill under hover and press, a
  danger menu row shows the danger fill while touch-pressed, and a tall menu no
  longer takes the host's Material scrollbar.
- A tooltip times its touch long press from raw pointer events, so the pressed
  fill of an icon-only button or a truncated menu row starts at pointer down.
- Select, dropdown and combo box lists fill a row with `layer-hover` only
  while the pointer is over it (never for a selected row opened by click or
  touch), clear the fill when the pointer leaves or moves onto a disabled row,
  keep the hover fill under a keyboard highlight and on a pressed selected
  row, show a not-allowed cursor on disabled rows, size the checkmark and
  error icons from the theme, and draw no host scrollbar. A dropdown with a
  committed value drops its trigger outline while open, an outside click blurs
  select and dropdown like the combo box, and the combo box selection handles
  use `text-primary`.
- Text fields no longer take the host's `InputDecorationTheme`: a host with
  outlined or filled fields drew a second, rounded box inside Carbon's.
- The option list drops its 1 px frame for Carbon's `0 2px 6px` shadow and is
  exactly 5.5 rows tall. A hovered or selected row filled over the frame and
  erased its sides.
- A hovered content switcher segment fills inside the frame, so an end
  segment keeps its outer edge, while a selected or focused one covers it as
  in Carbon. Contained tabs draw their rule on the leading edge, with none
  beside the selected tab. A bordered menu insets its rows inside the frame.
  Option-list rules are hidden beside the keyboard-highlighted row and the
  row under the pointer.
- A long touch press that opens a tooltip cancels the press, so it no longer
  also activates the icon-only button, menu row or tag under it.
- The text field selection toolbar takes the field's Carbon theme, so it is
  Gray 100 in a dark app rather than the default White.
- Controls activate only when the pointer is released over them, so a press
  dragged onto the next menu row, or off a button, activates nothing.
- An open combo box thins its focus outline to 1 px while a row is
  highlighted.
- Tertiary and danger tertiary buttons keep the focus fill and the inner focus
  ring through hover and press, a button set drops its separator beside a
  focused button and draws the disabled separator before a disabled one, and
  selectable and operational tags keep their border under the hover fill.
- The read-only toggle keeps its full-size handle, a disabled or read-only
  checkbox or group shows its helper text instead of the error, and the close
  button of a high-contrast tag focuses with `focus-inverse`.

### Gallery

- `example/` gallery covering every family and foundation, with theme,
  density, text scale, direction, reduced motion and width settings, and five
  compositions: settings form, action toolbar, list with row actions,
  searchable picker and confirmation flow.
