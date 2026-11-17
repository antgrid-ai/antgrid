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

Carbon React names on the left; `carbon_flutter` classes and parameters on the
right. Props not listed have no counterpart or are covered by theme, density
or `CarbonLocalizations`. Differences in behaviour are in `deviations.md`.

Conventions that apply to every family:

- `disabled` becomes a null callback (`onPressed`, `onChanged`), or
  `enabled: false` where a field has no single callback.
- `invalid` plus `invalidText` becomes `errorText`; `warn` plus `warnText`
  becomes `warnText`. Validation stays with the host.
- Values are host-owned and controlled: the widget reports a requested change
  and shows what the host passes back. There is no `defaultValue` or
  uncontrolled mode.
- Options are `CarbonOption<T>(value:, label:, enabled:, icon:, description:)`,
  identified by `value`. They replace `items` with `itemToString`,
  `SelectItem`, `Tab` and `Switch` children.
- Size follows density unless the family exposes an explicit size enum.

| Carbon React | carbon_flutter | Key props to parameters |
| --- | --- | --- |
| `Button` | `CarbonButton` | `kind` to `kind` (`danger--tertiary` and `danger--ghost` are `dangerTertiary` and `dangerGhost`); `size` `sm`/`md`/`lg`/`xl` to `CarbonButtonSize.small`/`medium`/`large`/`extraLarge`; `renderIcon` to `icon`; `onClick` to `onPressed`; `busy` has no Carbon prop |
| `Button` with `hasIconOnly`, `IconButton` | `CarbonButton.iconOnly` | `renderIcon` to `icon`; `iconDescription` or `label` to `semanticLabel`, also shown as its tooltip |
| `ButtonSet` | `CarbonButtonSet` | children in reading order; stacking is automatic |
| `TextInput` | `CarbonTextInput` | `labelText` to `label`; `placeholder`; `helperText`; `readOnly`; `size` to `CarbonFieldSize`; `maxCount` with `enableCounter` to `maxLength` with `showCounter`; `value` with `onChange` to `controller` and `onChanged`; `hideLabel` to `semanticLabel` without `label` |
| `PasswordInput` | `CarbonTextInput` | `variant: CarbonTextInputVariant.password`; show and hide labels come from localizations |
| `TextArea` | `CarbonTextInput` | `variant: CarbonTextInputVariant.multiline`; `rows` to `minLines` and `maxLines` |
| `Form`, `FormGroup` | `CarbonForm`, `CarbonFormSection`, `CarbonFormActions` | `FormGroup` `legendText` to `CarbonFormSection.title`; move focus to the first error with `CarbonFormController.focusFirstInvalid` |
| `Search` | `CarbonSearch` | `labelText` to `semanticLabel`; `placeholder`; `size`; `onChange` to `onChanged`; `onClear` to `onCleared`; Enter to `onSubmitted`; host status through `busy`, `errorText`, `resultCount` |
| `Select`, `SelectItem` | `CarbonSelect<T>` | `labelText` to `label`; `SelectItem` `value`/`text` to `CarbonOption` `value`/`label`; `value` with `onChange` to `value` with `onChanged`; `helperText`; `readOnly` |
| `Dropdown` | `CarbonDropdown<T>` | `titleText` to `label`; `label` (Carbon's placeholder text) to `placeholder`; `items` to `options`; `selectedItem` with `onChange` to `value` with `onChanged`; `helperText`; `readOnly`; host list state through `loading`, `listErrorText`, `emptyText` |
| `ComboBox` | `CarbonComboBox<T>` | `titleText` to `label`; `placeholder`; `items` to `options`; `selectedItem` with `onChange` to `value` with `onChanged`; `onInputChange` to `onInputChanged`; `shouldFilterItem` to `filter`; `allowCustomValue` to `allowCustomValue` with `onCustomValue` |
| `Checkbox` | `CarbonCheckbox` | `labelText` to `labelText` (or a `label` widget); `checked` to `value`; `indeterminate` to `value: null` with `tristate: true`; `onChange` to `onChanged`; `helperText`; `readOnly` |
| `CheckboxGroup` | `CarbonCheckboxGroup<T>` | `legendText` to `legend`; child checkboxes to `items` (`CarbonCheckboxItem`); checked state to `selected` (a set) with `onChanged` |
| `Toggle` | `CarbonToggle` | `labelText` to `labelText`; `labelA`/`labelB` to `offText`/`onText`; `toggled` with `onToggle` to `value` with `onChanged`; `size="sm"` to `small: true`; `readOnly`; `hideLabel` to `semanticLabel` without `labelText` |
| `Tabs`, `TabList`, `Tab` | `CarbonTabs<T>` | tabs to `tabs`; `selectedIndex` with `onChange` to `value` with `onChanged`; `activation="manual"` to `activation: CarbonActivationMode.manual`; `contained` to `variant: CarbonTabsVariant.contained`; `Tab` `disabled` and `renderIcon` to `CarbonOption.enabled` and `icon` |
| `TabPanels`, `TabPanel` | `CarbonTabPanels<T>`, `CarbonTabPanel<T>` | panels keyed by tab `value`; `keepAlive` keeps hidden panes mounted |
| `ContentSwitcher`, `Switch`, `IconSwitch` | `CarbonContentSwitcher<T>` | switches to `options`; `selectedIndex` with `onChange` to `value` with `onChanged`; `size`; `selectionMode="manual"` to `activation`; `IconSwitch` to `iconOnly: true` with `CarbonOption.icon` |
| `Menu` | `CarbonMenu` | `open` and `onClose` to `controller` (`CarbonPopupController`) and `onDismissed`; `label` to `semanticLabel`; the anchor is `child` |
| `MenuItem` | `CarbonMenuItem` | `label`; `onClick` to `onPressed`; `shortcut`; `renderIcon` to `icon`; `kind="danger"` to `kind: CarbonMenuItemKind.danger` |
| `MenuItem` with children | `CarbonMenuSubmenu` | `label`; children to `entries` |
| `MenuItemSelectable` | `CarbonMenuCheckItem` | `label`; `selected` with `onChange` to `checked` with `onChanged` |
| `MenuItemRadioGroup` | `CarbonMenuRadioGroup<T>` | `label`; `items` to `options`; `selectedItem` with `onChange` to `value` with `onChanged` |
| `MenuItemGroup`, `MenuItemDivider` | `CarbonMenuGroup`, `CarbonMenuDivider` | `label` |
| `useContextMenu` with `Menu` | `CarbonContextMenu` | items to `entries`; the target is `child` |
| `MenuButton` | `CarbonMenuButton` | `label`; `kind` (primary, tertiary, ghost); `size`; `menuAlignment` to `alignment`; children to `entries` |
| `OverflowMenu`, `OverflowMenuItem` | `CarbonOverflowMenu` with `CarbonMenuItem` entries | `iconDescription` to `semanticLabel`; a horizontal icon to `horizontal: true`; `flipped` or `align` to `alignment`; `itemText` to `label`; `isDelete` to `kind: CarbonMenuItemKind.danger`; `hasDivider` to a `CarbonMenuDivider` entry |
| `ComboButton` | `CarbonSplitButton` | `label`; `onClick` to `onPressed`; children to `entries`; `size`; `menuAlignment` to `alignment`; `disabled` to a null `onPressed` and `menuEnabled: false` |
| `Modal` | `CarbonModal`, shown with `showCarbonModal` | `open` and `onRequestClose` to `showCarbonModal` and `onClose`; `modalHeading` to `title`; `modalLabel` to `label`; children to `body`; `size` to `CarbonModalSize`; `passiveModal` to `CarbonModal.informational`; `primaryButtonText`/`onRequestSubmit` and `secondaryButtonText`/`onSecondarySubmit` to `CarbonModal.confirmation(primary:, secondary:)` or `actions`; `danger`; `primaryButtonDisabled` to a null `CarbonModalAction.onPressed`; `loadingStatus` to `CarbonModalAction.busy`; `preventCloseOnClickOutside` to `barrierDismissible: false` |
| `Tooltip` | `CarbonTooltip` | `label` or `description` to `message`; `align` to `alignment` with `preferAbove`; `enterDelayMs` to `showDelay`; `leaveDelayMs` to `hideGrace` |
| `InlineNotification`, inline `ActionableNotification` | `CarbonNotification` | `kind`; `title`; `subtitle`; `lowContrast` to `highContrast` (inverted, with a different default); `hideCloseButton` to a null `onClose`; the action button to `action` (`CarbonNotificationAction`) |
| `ToastNotification` | `CarbonToast`, through `CarbonToastController.show` and `CarbonToastOverlay` | `kind`; `title`; `subtitle`; `caption`; `timeout` to `autoDismiss`; `onClose` to the handle's `dismiss` or the close button |
| `Loading` | `CarbonLoading`, `CarbonLoadingOverlay` | `active`; `small` to `size: CarbonLoadingSize.small`; `withOverlay` to `overlay` or `CarbonLoadingOverlay`; `description` to `semanticLabel` |
| `InlineLoading` | `CarbonInlineLoading` | `status`; `description`; `iconDescription` to `statusLabel`; `onSuccess` and `successDelay` stay with the host |
| `Tag` | `CarbonTag` | `type` to `color` (`CarbonTagColor`); `size`; `renderIcon` to `icon`; `text` to `label`; `disabled` |
| `DismissibleTag` | `CarbonTag` with `onDismissed` | `onClose` to `onDismissed`; `title` to `dismissLabel` |
| `SelectableTag` | `CarbonTag` with `selected` | `selected` with `onChange` to `selected` with `onSelectedChanged` |
| `OperationalTag` | `CarbonTag` with `onPressed` | `onClick` to `onPressed` |
| `ContainedList` | `CarbonContainedList`, `CarbonContainedList.builder`, `CarbonContainedListSliver` | `label`; `action`; `kind` to `variant`; `isInset` to `inset`; host states through `status` and the content slots |
| `ContainedListItem` | `CarbonContainedListRow` | children to `title` and `secondary`; `renderIcon` to `leading`; `action` to `actions`; `onClick` to `onPressed`; selection through `selected` with `onSelectedChanged` |

Components share primitives for interaction (focus, hover, press,
activation), the focus ring, the field frame and box, anchored popups and
options. Build on them instead of re-implementing.

## Select, Dropdown, Menu or Menu button

A visible chevron or shared popup code does not decide the role. Choose by
what the control holds:

| The control | Use | Example |
| --- | --- | --- |
| Holds one form value from a short list, with a label, helper and validation | `CarbonSelect` | A port-detection preference in a settings form |
| Picks one value from a longer list, with host-driven loading or error states | `CarbonDropdown` | A target chosen from a few dozen entries |
| Picks one value from a list long enough to need typing, or accepts free text when the host allows it | `CarbonComboBox` | A project or branch list |
| Runs commands, possibly including checked settings or a radio choice | `CarbonMenu`, opened by one of the triggers below | Rename, duplicate, delete; a view-mode choice |
| Opens a menu of commands from a labelled button | `CarbonMenuButton` | "Actions" in a toolbar |
| Opens a menu of secondary commands from an icon | `CarbonOverflowMenu` | Row actions in a list |
| Offers one primary command plus related alternatives | `CarbonSplitButton` | "Save" with "Save as" and "Save all" |
| Opens commands at the pointer or from the Menu key | `CarbonContextMenu` | Right-click on a file row |

A menu button has no value of its own: never use it in place of a form
field's label, value and validation. A menu's check and radio items change
settings in place; they do not make the menu a form field.

## Web-only concepts

| Carbon web | Flutter |
| --- | --- |
| CSS custom properties and Sass tokens | `CarbonColors` roles and `CarbonThemeData` |
| `.cds--layer-*` theme zones | `CarbonLayer` and `CarbonLayerSurface` |
| `:hover`, `:active`, `:focus-visible` | `CarbonInteractionState` (hovered, pressed, focusVisible) |
| `outline` focus ring | inset ring painted as a foreground decoration |
| `position: absolute` menus and popovers | `OverlayPortal` anchored popups |
| Modal in portal with focus trap | Navigator route pushed by `showCarbonModal`, which wraps it in `CarbonScopeRelay` |
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
