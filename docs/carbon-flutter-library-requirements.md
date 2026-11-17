# Carbon Flutter Component Library Requirements

**Status:** Draft requirements for review

**Date:** 2026-11-12

**First consumer:** Antgrid

**Initial location:** A standalone Flutter package under this repository's `packages/` directory

**Initial scope:** 19 component families and shared foundations

## Purpose and direction

Build a reusable Flutter implementation of Carbon as a standalone package under this repository's `packages/` directory. It must provide one visual system with explicit **compact** and **touch** sizing. Antgrid will consume the library and retain its application-specific components, navigation and state. Moving the package into a separate repository is an optional later step.

The accepted direction is a shared Carbon library across desktop, iOS and Android. Platform conventions for input, navigation and system interactions remain part of the experience. A separate Cupertino version of every component is not required.

The library should make routine interface decisions predictable: which control to use, how related controls align, how states appear, and how interactions work. Its first release must be useful in a real Antgrid workflow without requiring the rest of Carbon to be implemented.

This document defines required outcomes and release criteria. Package naming, public Dart API signatures and the implementation sequence belong in the subsequent technical design. Numerical sizing and validation targets below are proposed library requirements, not claims of universal Carbon or platform rules.

## Scope and ownership

| Library owns | Antgrid owns |
| --- | --- |
| Tokens, themes, typography, density and generic component behavior | Brand configuration and documented product adaptations |
| Focus, keyboard interaction, semantics, overlays and component state presentation | Session models, providers, commands, authorization and data loading |
| The 19 families below, documentation, gallery and component tests | Session rows, terminal controls, agent status, rich composer and other domain compositions |
| Extension points for platform-appropriate presentation | Application routes, pane layouts, mobile navigation and system-service integrations |

The dependency must run from Antgrid to the component package. The package must run in its own example app without Antgrid code, services or accounts. Existing Ab widgets may become thin adapters during migration; they must not maintain a second implementation of shared styling.

The package must own its `pubspec.yaml`, public exports, assets, tests, documentation and example gallery. It must not import application code or depend on Antgrid services, sibling product packages or repository-only build steps. Its checks must run from the package directory with the documented Flutter toolchain and declared dependencies. Keeping these boundaries allows package and consumer changes in one commit while preserving the option to extract the package later.

Initial native targets are Windows, macOS, Linux, Android and iOS, including tablets. A web gallery is desirable for review but does not introduce an Antgrid web-client requirement or replace native validation.

## Implementation architecture

Use one Flutter package with foundations, shared interaction primitives and public components. Dependencies flow from components through primitives to foundations; Antgrid consumes the public API through its design adapters. Introduce shared primitives as real controls need them.

- Keep implementation libraries under `lib/src/`, with explicit public exports from the package entry point. Include `test/`, a runnable `example/` gallery and package documentation under `doc/`. Antgrid and the gallery must not import package internals. [Dart package conventions](https://dart.dev/tools/pub/package-layout)
- Supply immutable theme data and explicit density through an inherited theme scope. Colors, typography, dimensions and surface layers resolve from that scope; mutable global theme or density settings are prohibited.
- Components receive values, callbacks, validation results and busy state from the host. They own transient interaction state such as hover, focus, popup visibility and animation. The package must not require Riverpod, application services or persistence.
- Reuse Flutter's editing, focus, shortcuts, form and semantics infrastructure. Carbon owns component presentation and behavior; low-level platform input machinery must remain framework-provided.
- Use shared anchored-popup infrastructure, with `OverlayPortal` as the initial implementation choice. Modal presentation uses Navigator routes. Preserve distinct menu, selection and dialog semantics, including the lifecycle requirements below.
- Keep Antgrid adapters thin, with a single theme mapping at the app boundary. Product compositions, routing, terminal rendering and platform-service integration remain in the app.

## Carbon baseline and customization

- Use the stable Carbon v11 design baseline for the first release. Record the upstream package revision and documentation references used; review upstream changes deliberately.
- Follow Carbon's component roles, state vocabulary and visual relationships. Record Flutter-specific and density adaptations in a short deviations register with their reason and validation evidence.
- Keep Carbon defaults available independently of the Antgrid theme. Product-specific colors, fonts and compositions must not become hard-coded package defaults.
- Customize through semantic themes, density and named component variants. Avoid routine per-screen overrides for padding, radius, label size or state colors.
- The library must have no incidental Material ripples, elevation or styling. Flutter's underlying editing and interaction machinery may be reused while the library owns visual presentation.
- Maintain a coverage matrix distinguishing supported variants, deliberately deferred variants and documented adaptations. Supporting a family does not claim complete parity with every Carbon web variant.
- Describe the package as an independently maintained Flutter implementation. Official Carbon framework support does not extend to this package. [Carbon framework support](https://www.carbondesignsystem.com/getting-started/developing/overview)

Carbon defines role-based tokens separately from the theme values assigned to them. The Flutter theme model must preserve that separation. [Carbon color guidance](https://www.carbondesignsystem.com/building-blocks/foundations/color/overview)

## Compact and touch sizing

Density is an explicit, inheritable library setting. Layout width, input method and text scaling are related concerns but must not be treated as the same setting.

| Requirement | Compact | Touch |
| --- | --- | --- |
| Intended use | Pointer and keyboard workflows with dense information | Finger interaction on phones, tablets and touch-capable devices |
| Default single-line control height | 32 logical pixels | 48 logical pixels |
| Default icon-button footprint | 32 by 32 logical pixels | At least 48 by 48 logical pixels |
| Rows and menu items | Minimum 32 logical pixels; grow for content | Minimum 48 logical pixels; grow for content |
| Typography | Carbon productive roles | Explicit readable touch roles within the same hierarchy |
| Secondary actions | May be revealed on hover and keyboard focus | Must have a discoverable touch-accessible presentation |

These are baseline minimums at ordinary text scale, not fixed heights that may clip content. Compact controls may expose a documented smaller variant for constrained chrome. Touch mode must preserve its target floor.

The sizing contract must satisfy all of the following:

- A host can choose density at application or subtree level. A standalone gallery can switch modes explicitly.
- Phones and tablets default to touch. A wide viewport or an attached keyboard must not silently force compact sizing. Desktop hosts may select touch mode for touch-first use.
- Hover capability is independent of density: a pointer can still reveal hover feedback in touch mode. Moving a pointer must not repeatedly resize the interface.
- Changing theme or density must preserve focus, entered text, selection and scroll position where the control remains mounted.
- Text scaling must remain enabled. Controls must wrap, grow, scroll or change presentation when necessary; fixed toolbars must not clip enlarged text or shrink touch targets.
- Small visual marks, such as a checkbox indicator, may sit inside a larger interactive footprint. The footprint must participate in layout and must not overlap a neighboring action.
- Interactive rows and their trailing actions must remain separately reachable. A row's large hit area does not compensate for an inaccessible trailing button.
- Inline text links may follow text layout rather than square button geometry, with readable line spacing and verified touch and accessibility behavior.
- Essential information and actions must remain available without hover. Tooltip text alone must not carry required instructions or validation errors.

Apple emphasizes text-size adaptation and comfortable touch interaction. This library adopts a 48-pixel touch target policy across its native targets for consistency. [Apple accessibility guidance](https://developer.apple.com/design/human-interface-guidelines/accessibility)

## Required foundations

### F01 Semantic tokens

Provide named roles for background layers, fields, text, icons, borders, actions, selection, focus, feedback and disabled states. Include spacing, component dimensions, corner treatment, border widths, typography and motion. Component implementations consume these roles; consumer screens must not reconstruct the same appearance from literal values.

Primitive palette values and component-specific tokens must have a clear relationship to semantic roles. Overrides must preserve the meaning of a role rather than reuse a success color as an unrelated primary action color.

### F02 Themes and surface layering

Support Carbon's White, Gray 10, Gray 90 and Gray 100 themes, plus a documented custom-theme mechanism. The host chooses explicit light/dark themes or follows system appearance. Nested surfaces, menus, dialogs and tooltips must inherit the correct theme and layer treatment, including when rendered in an overlay.

Theme changes must not remount the application. Default and interactive color pairs must be checked for contrast; custom themes must have a documented validation path.

### F03 Typography and text behavior

Provide named styles for body text, compact labels, headings, field labels, helper/error text and code/data. Each role defines family, size, weight, line height and tracking. Include a documented font-asset setup for IBM Plex Sans and Mono; fonts must be available without a runtime network request. Consumers may substitute families through the theme and validate resulting metrics.

Compact mode uses Carbon's productive hierarchy. Touch typography must be defined explicitly and reviewed on devices, without reducing text to fit a fixed box. Sans is the default for interface chrome; monospace is reserved for code and data. Antgrid may retain its terminal font independently.

Respect system text scaling, font fallbacks, bidirectional text and text selection. Use directional alignment and insets. Truncation must be intentional, with a way to access important full values. [Carbon typography](https://www.carbondesignsystem.com/building-blocks/foundations/typography/type-sets)

### F04 Layout and composition

Define consistent control alignment, label-to-field spacing, helper spacing, action groups, section spacing and row anatomy. Controls of the same density must align when used together. Long labels, multiline values, localized strings and constrained widths must not require one-off screen fixes.

The package may provide small layout helpers. Application grids, resizable IDE panes and route structure remain consumer concerns.

### F05 Icons and accessible naming

Provide consistent icon sizing, alignment, color roles and directional mirroring rules. Supply a supported Carbon icon path and allow consumer-supplied icons through a documented interface. The first release need only bundle icons required by its controls and examples; it does not need to reproduce the entire icon catalog.

Icon-only controls require accessible names. Decorative icons must not produce duplicate announcements. Asset provenance and redistribution notices must accompany shipped fonts and icons.

### F06 Interaction states

Define default, hover, pressed, keyboard focus, selected, disabled, read-only, busy and validation states wherever applicable. Distinguish read-only from disabled, and selected from focused. Define combinations such as selected plus hovered or invalid plus focused so components do not invent precedence individually.

Disabled controls must not activate; read-only fields must retain permitted inspection and copy behavior. Loading must communicate ongoing work without allowing unintended repeat actions. State changes should preserve layout unless content genuinely needs more space.

### F07 Focus and keyboard interaction

Provide visible focus treatment, logical traversal, component-appropriate activation and directional navigation. Focus must not become trapped outside a modal. Menus, selections, tabs and dialogs must each document their keyboard contract rather than applying one key map universally.

Closing an overlay must return focus to its trigger when it still exists, or to a sensible host-provided fallback. Hover-revealed actions must also be discoverable with keyboard focus. Keyboard handling must preserve text-editing shortcuts and input-method composition.

### F08 Accessibility and localization

Expose meaningful names, roles, values, checked/selected states, expanded state, errors and available actions through Flutter semantics. Use [WCAG 2.2 AA](https://www.w3.org/TR/WCAG22/) as the baseline for applicable contrast and interaction criteria, together with native platform accessibility behavior; automated checks alone do not establish conformance.

Do not use color as the only signal. Support screen readers, high-contrast preferences where the platform exposes them, reduced motion and enlarged text. Built-in strings must be localizable, and both left-to-right and right-to-left layouts must be supported.

### F09 Overlays and scrolling

Provide shared infrastructure for anchoring, collision handling, stacking, dismissal, focus ownership and scrollable popup content. Reposition or dismiss safely when an anchor moves, disappears, the window resizes or the keyboard opens. Popups must fit the available viewport and respect safe areas.

Menu and field popup infrastructure may be shared, while their focus and selection semantics remain distinct. Modal barriers must prevent accidental interaction with content behind them. Preserve platform-appropriate scrolling and text-selection behavior rather than globally forcing desktop physics.

### F10 Motion and feedback

Use named durations and easing curves. Motion should explain a transition or progress, avoid unnecessary layout movement and respect reduced-motion preferences. Static alternatives must still communicate loading and state changes.

Keep haptic behavior optional and platform-aware. Animation must not be required to understand success, error or selection, and off-screen animations must not consume continuous resources unnecessarily.

## Initial component requirements

Every family must support both densities, the supplied themes, relevant states, keyboard operation and accessibility semantics. The table states additional requirements specific to each family. Variant names may be refined during API design while preserving this scope.

| ID | Family | Required first-release behavior |
| --- | --- | --- |
| C01 | Button | Primary, secondary, tertiary, ghost and danger treatments; text, icon-only and icon-with-text forms. Support disabled and busy states, a stable label footprint and accessible icon labels. A busy action must not submit twice. |
| C02 | Text input | Single-line, multiline and password variants; placeholder, label, helper/error association, prefix/suffix and optional clear/reveal actions. Preserve editing, selection, IME composition, autofill and appropriate keyboard options. Respect supplied controller and focus lifetimes. |
| C03 | Form | Consistent field grouping, label and validation presentation, required-field communication and action alignment. Support host-controlled submission and validation results; make errors discoverable and allow focus to the first invalid field. Business validation stays with the host. |
| C04 | Search | Search field with clear action, accessible labeling and optional submission. Accept host-provided busy, error and result-count presentation. Debouncing and result fetching stay with the host. Escape/clear behavior must be documented and must not discard unrelated input. |
| C05 | Select | A labeled single-value form field with placeholder, helper/error text, disabled/read-only behavior and keyboard selection. Display the committed value. Support empty and unavailable option sets without silently committing a replacement. Rendering is Flutter-owned; browser-native HTML is not a requirement. |
| C06 | Dropdown | Single selection and searchable combo-box variants with keyboard navigation, committed-value indication and empty/loading/error presentation. Free-text entry is explicitly enabled by the host when appropriate. Search changes must not accidentally commit a value. Multiselect is deferred. |
| C07 | Checkbox | Checked, unchecked and explicitly enabled indeterminate states; label, disabled state and accessible checked/mixed semantics. Label and indicator share an adequate target without causing duplicate toggles. |
| C08 | Toggle | On/off control for an immediately applied setting, with visible or accessible label and disabled state. Communicate the current value without relying on color alone. Pending or failed persistence is host-controlled and must not imply success prematurely. |
| C09 | Tabs | Horizontal tabs with selected, focused and disabled states, keyboard movement and overflow scrolling. Document automatic versus manual activation behavior. Preserve content state through host composition. Closable, draggable IDE tabs are a later extension. |
| C10 | Content switcher | Text and icon variants for switching between related views, with exactly one selected option and accessible labels. Support disabled choices and keyboard navigation. Keep selection distinct from hover and focus. |
| C11 | Menu | Action items, groups, separators, icons, shortcut hints, disabled/danger actions, checkable items and submenus. Support keyboard traversal, dismissal and focus restoration. Nested menus need an explicit tap-based path in touch mode; hover must not be required. |
| C12 | Menu button | Standard menu trigger, overflow trigger and split/combo button. Expose expanded state and associated menu semantics. In a split button, the primary action and menu trigger are separately reachable and must not activate each other. Compose the shared Menu implementation. |
| C13 | Modal | Informational, confirmation and form dialogs with title, body, close action and action group. Provide controlled dismissal, focus containment/restoration and scrollable content. Long content and keyboard insets must keep actions reachable. Allow host presentation adapters for compact screens. |
| C14 | Tooltip | Concise supplementary descriptions on hover and keyboard focus, with sensible placement and dismissal. Provide a documented touch trigger where useful. Interactive content belongs in a different surface. A tooltip must not replace a required accessible label. |
| C15 | Notification | Inline and toast variants for informational, success, warning and error messages, with optional actions and dismissal. Provide appropriate announcements, host-controlled lifetime and accessible timing behavior. Critical information must remain available rather than disappearing only in a toast. |
| C16 | Loading | Indeterminate loading for a region or view, with an optional status message and accessible busy indication. Provide a reduced-motion presentation. The host controls which region is unavailable; a loading indicator must not block unrelated work implicitly. |
| C17 | Inline loading | Compact pending, success and failure feedback beside an action or inside a control. Preserve alignment and associate announcements with the relevant action. Keep retry actions explicit and avoid repeatedly announcing every animation frame. |
| C18 | Tag | Read-only, dismissible and filter/selectable variants with optional icon and semantic color roles. Separate selection from removal when both exist. Ensure the remove action is named and touch-accessible. Antgrid's live agent-status model remains outside the generic tag API. |
| C19 | Contained list | Grouped rows with header, leading content, title, optional secondary text, trailing actions and optional selection. Support multiline content and host-provided loading/error/empty content. Row activation and trailing controls must be independent; larger text must grow rows. |

Carbon's catalog supplies the family names and baseline guidance. The table above is the bounded Flutter release scope, including the required adaptations. [Carbon components](https://www.carbondesignsystem.com/building-blocks/core/components/overview/components)

### Selection and menu boundaries

Select, Dropdown, Menu and Menu button must remain distinguishable in documentation and APIs:

- **Select:** a field holding one form value, such as a port-detection preference.
- **Dropdown or combo box:** an option picker that may support search, such as a long project or branch list.
- **Menu:** a collection of commands, possibly including checked settings, such as rename, delete or a mode choice.
- **Menu button:** the control that opens a Menu, including an overflow or split-button trigger.

A visible chevron, or reuse of popup code, does not determine the semantic role. A menu button must not be used as a substitute for a form field's labeling, value and validation contract. Menu-specific checked items do not require the standalone Radio button family to enter this release.

These distinctions follow Carbon's [Select guidance](https://www.carbondesignsystem.com/building-blocks/core/components/select/guidelines), [Dropdown guidance](https://www.carbondesignsystem.com/building-blocks/core/components/dropdown/guidelines) and [Menu button guidance](https://www.carbondesignsystem.com/building-blocks/core/components/menu-buttons/guidelines).

## Platform adaptation

Carbon remains the visual language of library-owned controls. Density does not automatically replace them with Material or Cupertino alternatives.

| Concern | Required behavior |
| --- | --- |
| iOS and iPadOS | Support native text editing expectations, keyboard insets, safe areas, accessible text sizes and touch use. Host navigation preserves appropriate back gestures and transitions. |
| Android | Preserve system back behavior, text editing and accessibility services. Touch sizing applies regardless of phone/tablet width. |
| Desktop | Support keyboard-first operation, mouse hover, right-click where relevant, window resizing and display/text scaling. Touch mode remains available. |
| Dialog and picker presentation | The host may present a compact-screen sheet or an iOS-style action sheet through an adapter. Values, validation and focus behavior must stay consistent. |
| System surfaces | File/photo selection, sharing, permissions and authentication remain platform integrations owned by the host. |

Cupertino widgets may be used behind a deliberate presentation adapter; they are Flutter-rendered components, not a substitute for actual system service integration. The package must not require an application to duplicate its entire widget tree per platform. [Flutter platform adaptations](https://docs.flutter.dev/ui/adaptive-responsive/platform-adaptations)

## Implementation gotchas and safeguards

These safeguards apply to component implementation and review. Validate them in composed examples as well as isolated controls; a small animated indicator can affect a much larger surrounding view.

1. **Animation repaint isolation.** A spinner or pulsing indicator must not cause unnecessary painting of its surrounding form, list or app pane. Evaluate `RepaintBoundary` where the animated subtree and its surroundings repaint independently, accounting for boundaries Flutter already supplies. A boundary isolates paint work; it does not prevent widget rebuilds or layout. Avoid adding one to every control: extra layers and caching can cost resources. Use repaint visualization to inspect propagation, then profile representative compositions to confirm the benefit. [Flutter RepaintBoundary](https://api.flutter.dev/flutter/widgets/RepaintBoundary-class.html)

2. **Rebuilding static content on every animation tick.** Keep animation listeners and state changes close to the changing visual. Prefer transition widgets or a narrow `AnimatedBuilder`, passing invariant content through its `child` parameter. A loading icon must not rebuild its entire form or gallery. Avoid parsing assets, measuring all options or constructing expensive derived data inside frequently invoked builders. [AnimatedBuilder optimization](https://api.flutter.dev/flutter/widgets/AnimatedBuilder-class.html), [Flutter build performance](https://docs.flutter.dev/perf/best-practices)

3. **Hidden animations that keep running.** `Offstage` children can still animate and receive keyboard focus. Retained tabs and panes need an explicit visibility policy that mutes tickers and excludes hidden controls from focus. Use widget-aware ticker providers so `TickerMode` works; timers and subscriptions need their own lifecycle handling. Stop unnecessary repeating work when hidden, disposed or motion is reduced, while preserving meaningful loading feedback. Scrolling a kept-alive item off-screen must not be assumed to mute it automatically. [Offstage behavior](https://api.flutter.dev/flutter/widgets/Offstage-class.html), [TickerMode](https://api.flutter.dev/flutter/widgets/TickerMode-class.html)

4. **Expensive painting and layout disguised as styling.** Avoid routine `saveLayer`, nested opacity groups, backdrop effects and intrinsic sizing across repeated rows. Choose the least expensive rendering approach that preserves the required appearance. Use lazy item construction for large option sets and lists. Fixed extents are appropriate only when the content and text-scale contract guarantees them; otherwise allow rows to grow. Measure UI-thread and raster-thread work separately in profile mode on the target devices. [Flutter performance guidance](https://docs.flutter.dev/perf/best-practices)

5. **Controller and listener ownership.** Never create a text, focus, scroll or animation controller in `build`. Dispose controllers created by the component; leave caller-owned controllers alive. When a supplied controller changes, detach listeners from the old instance and attach them to the replacement. Cancel owned timers and subscriptions and remove owned overlays during teardown. Exercise controller replacement and repeated mount/unmount in lifecycle tests.

6. **Late callbacks and stale results.** Every asynchronous operation needs explicit completion and error ownership. Await or return its Future, or deliberately detach it with an error handler; `unawaited` alone does not handle errors. After an asynchronous gap, verify that the relevant state/context is still mounted before updating it. Being mounted does not make an old result current: reject obsolete completions after the input or operation changes. Fetching and business-operation state stay host-owned; rebuilding a control must not start another request. [BuildContext lifetime](https://api.flutter.dev/flutter/widgets/BuildContext/mounted.html)

7. **Theme capture that becomes stale.** `InheritedTheme.capture` freezes the captured themes. A one-time capture cannot satisfy live theme and density updates for an open modal. Supply a live configuration path or deliberately refresh the captured configuration without remounting the form. Test theme and density changes while menus and dialogs are open, including nested overrides and text already entered. [InheritedTheme capture](https://api.flutter.dev/flutter/widgets/InheritedTheme/capture.html)

8. **Popups whose anchors move or disappear.** `OverlayPortal` can inherit the trigger's configuration, but its accessibility subtree can disappear when a kept-alive trigger becomes invisible. Reposition or dismiss according to the component contract when the anchor scrolls away, is removed, or the viewport/keyboard changes. Verify that no popup remains visibly stranded or inaccessible and that focus restoration handles a removed trigger. Submenus must close with their owning menu. [OverlayPortal lifecycle and semantics](https://api.flutter.dev/flutter/widgets/OverlayPortal-class.html)

9. **Identity changes that reset user state.** Do not generate new keys during ordinary rebuilds or use theme/density as a control's identity. Use stable item identities in reorderable or filtered content. Keep text controllers and committed selection independent of popup presentation. Closing a popup or changing appearance must not silently discard the host's value, text selection or scroll position.

10. **Density overrides that defeat touch or text scaling.** Do not infer compact density from viewport width or attach a small fixed height to every control. Respect system `TextScaler`, including nonlinear scaling. Expanded targets must participate in layout without overlapping neighbors; suffix buttons, tag removal and split-button triggers need their own usable targets. Verify long labels, errors, RTL and enlarged text in composed toolbars and forms, not only isolated widgets. [Flutter accessibility guidance](https://docs.flutter.dev/ui/accessibility)

11. **Custom input behavior that breaks editing.** Reuse Flutter's text-editing and focus machinery. Do not rewrite controller text on every build, clear composing ranges to normalize input, or intercept ordinary typing and arrow keys globally. Menu navigation shortcuts must be scoped so an embedded search field retains its editing behavior. Check IME composition, selection, copy/paste, autofill and password reveal on relevant platforms. [Flutter editing and shortcut behavior](https://api.flutter.dev/flutter/widgets/EditableText-class.html)

12. **Visual states without matching interaction and semantics.** A dimmed control must actually stop activation when disabled. A read-only field must retain permitted inspection and copy behavior. Announce meaningful loading/status changes once rather than on every animation frame. Give icon actions accessible names, exclude decorative duplicates and keep a row's primary action separate from its trailing action. Pointer cancellation, keyboard activation and touch activation must produce consistent results.

13. **Optimization that silently makes rendering stale.** Cache only values whose dependencies and invalidation are understood. Theme, density, text scale, locale, direction and constraints may change. A custom painter's `shouldRepaint` and semantics update decisions must reflect the values it renders; do not return false when the new delegate represents changed visual information. Prefer immutable configuration and localized dependencies over mutable global token caches. [CustomPainter invalidation](https://api.flutter.dev/flutter/rendering/CustomPainter/shouldRepaint.html)

14. **Misleading verification.** Debug-mode timings are not release performance evidence. Profile the gallery and a real Antgrid composition with named devices and refresh rates. Pin fonts and rendering conditions for visual comparisons. Repeating loading animations require bounded test pumping or explicitly stopping the animation; `pumpAndSettle` times out if an infinite animation keeps scheduling frames. Include behavioral checks for disposal, open-overlay updates, focus restoration and off-screen work alongside screenshots. [Widget test pumping](https://api.flutter.dev/flutter/flutter_test/WidgetTester/pumpAndSettle.html)

## Gallery and developer experience

The package must include a runnable component gallery in its `example/` directory as a first-class deliverable. It must demonstrate:

- Every in-scope family and required variant, with controls to change theme, density, text scale, direction and available width.
- Relevant interaction states, including combinations such as invalid plus focused, selected plus disabled, and busy plus enlarged text.
- Realistic long labels, empty values, unavailable options, multiline content, validation errors and keyboard-visible layouts.
- Compositions: a settings form, an action toolbar, a list with row actions, a searchable picker and a confirmation flow.
- Compact and touch examples at phone, tablet and desktop widths, including a wide layout using touch density.

Each family needs usage guidance, a decision example, keyboard behavior, accessibility notes, its Carbon reference and documented deviations. Public examples must use public package APIs and require no Antgrid setup.

The package documentation must include a Carbon-to-Flutter mapping guide for contributors and agents. Carbon MCP can retrieve upstream facts when available; checked-in references and the chosen baseline remain sufficient to build and test offline. Carbon's web code-audit tool is not a Dart correctness or accessibility gate.

## Release acceptance criteria

| Gate | Evidence required before the first release |
| --- | --- |
| Scope | Coverage matrix accounts for C01-C19 and F01-F10, with every required variant implemented or the requirements revised explicitly. |
| Visual consistency | Reviewed gallery screenshots cover all supplied themes and both densities. Visual regression checks cover representative states and composed examples using pinned fonts and rendering conditions. |
| Sizing and scaling | Touch controls meet the stated target policy. Representative compositions work at 320, 390, 768 and 1280 logical-pixel widths, at ordinary and 200% text scale, including nonlinear system scaling where supported. No clipped essential labels, errors or actions. |
| Interaction | Widget tests exercise pointer, touch and keyboard behavior, cancellation, disabled/read-only states, selection, overlay dismissal and focus restoration. |
| Accessibility | Automated semantics and contrast checks plus manual screen-reader walkthroughs on iOS and Android. Desktop keyboard checks cover all native desktop targets; platform validation records supported screen-reader behavior and limitations. |
| Input reliability | Device checks cover selection/copy/paste, password reveal, IME composition, autofill where applicable and keyboard opening/dismissal. |
| Platform readiness | The gallery builds and runs on each declared native target. Platform-specific claims require tests on that platform; unverified targets are not labeled supported. |
| State continuity | Changing theme or density preserves entered values, focus and host-owned selection. Opening and closing overlays leaves no orphaned layers or focus traps. |
| Performance | Profile representative scrolling, repeating animations and overlay interactions on a named baseline phone and desktop. Define and record device/refresh-rate budgets before implementation; no unexplained sustained frame-budget overruns, broad animation-driven repaint/rebuild work or off-screen animation churn. Record evidence for repaint-boundary placement where it affects representative compositions. |
| Lifecycle | Repeated mount/unmount and supplied-controller replacement leave no listeners, tickers or overlays active unintentionally. Open overlays preserve configuration and focus behavior when themes, density, anchors and viewport constraints change. |
| Integration | One real Antgrid workflow uses the package in compact and touch modes, exercises a form and a menu/dialog flow, and passes the app's relevant regression checks. |
| Packaging | Public exports, compatible Flutter/Dart ranges, font/icon setup, notices, changelog and dependency instructions are present and reproducible. Package checks and the example gallery require no Antgrid application setup. |

Tests must validate observable behavior and failure-prone boundaries. Screenshot tests supplement interaction and semantics checks; they do not replace them. Density is a usability contract, so enlarging an invisible hit region without checking surrounding layout is insufficient.

## Delivery and adoption

1. Establish the standalone Flutter package under `packages/`, with the Carbon baseline, foundations and example gallery. Verify density and text scaling before expanding the control set.
2. Implement enough of the 19 families to exercise a real Antgrid settings or new-session flow. Use that integration to validate APIs and mobile presentation early.
3. Complete the remaining first-release families and acceptance gates. Record supported platforms, coverage and deviations in the release.

Antgrid must initially consume the package through a relative path dependency in `app/pubspec.yaml`. Package and consumer changes can ship in the same commit; shared builds use the same repository revision and the app's committed lockfile. Changes must run the library checks and the affected Antgrid checks. Separate publishing or release coordination is not required for this initial arrangement.

Revisit a separate repository when the API has settled, another consumer needs the library or independent release ownership becomes useful. Extraction must preserve the public API and move the package's assets, tests, documentation and gallery with it. Antgrid would then switch to a reviewed package version or pinned Git revision; local path overrides may support development across the two repositories. Extraction is not a first-release acceptance criterion.

The library owns generic behavior fixes; Antgrid owns product compositions. When migration changes an existing design rule, update the relevant app guidance in the implementation change. This requirements document does not itself replace current app conventions.

## Excluded from the first release

The nine previously identified follow-on families remain outside this release: Accordion, Breadcrumb, Tree view, Radio button, Tile, Progress bar, Code snippet, Link and List. Inline text/link styling needed inside an in-scope field or notification does not imply a standalone Link component.

Calendar/date picking, file-upload presentation, Number input, Multiselect, standalone Popover/Toggletip, data tables, pagination, charts, experimental Carbon components and a complete Carbon UI shell are also deferred.

Antgrid's terminal renderer, editor/diff viewers, rich composer, session-specific components, command palette and pane layout remain application features. Their eventual migration can compose library controls without moving their domain behavior into the package.

## Decisions for technical design

- Package name and ownership within `packages/`. A separate repository name, visibility and external distribution channel are deferred until extraction or publication is needed.
- Initial Flutter/Dart version range and baseline devices for performance qualification.
- Exact compact/touch typography metrics and supported per-component sizes, validated in the gallery against the sizing policy.
- The first Antgrid pilot workflow and any required presentation adapters.
- Public API organization, custom-theme validation and asset packaging, with provenance and attribution checked before distribution.

These decisions should be resolved in the technical design without expanding the 19-family release scope implicitly.
