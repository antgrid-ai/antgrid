# Carbon baseline

carbon_flutter tracks Carbon v11. This file records exactly which published
artifacts the foundations were generated or transcribed from, so a version bump
is a deliberate, reviewable change.

| Source | Version | Used for |
| --- | --- | --- |
| `@carbon/themes` | 11.85.0 | Semantic color roles for White, Gray 10, Gray 90, Gray 100 (`colors.g.dart`) |
| `@carbon/icons` | 11.92.0 | Bundled glyph path data (`icons.g.dart`) |
| `@carbon/type` | as of themes 11.85.0 | Productive type roles; sizes, line heights and tracking in `typography.dart` |
| `@carbon/layout` | as of themes 11.85.0 | Spacing 01-13 and component sizes in `tokens.dart` |
| `@carbon/motion` | as of themes 11.85.0 | Durations and productive easing curves in `tokens.dart` |
| IBM Plex Sans / Mono | 1.1.0 | Bundled fonts: Sans 300/400/500/600, Mono 400/500/600 |

IBM Plex comes from the releases page of https://github.com/IBM/plex. The font
files and `OFL.txt` live in `assets/fonts/`.

## Values taken from Carbon

- Colors: every semantic role in the four themes, unchanged.
- Spacing: `$spacing-01` to `$spacing-13` = 2, 4, 8, 12, 16, 24, 32, 40, 48, 64,
  80, 96, 160 px (`CarbonSpacing`).
- Sizes: 24, 32, 40, 48, 64, 80 px (`CarbonSizes`).
- Motion: fast-01 70 ms, fast-02 110 ms, moderate-01 150 ms, moderate-02
  240 ms, slow-01 400 ms, slow-02 700 ms; productive standard
  `cubic-bezier(0.2, 0, 0.38, 0.9)`, entrance `(0, 0, 0.38, 0.9)`, exit
  `(0.2, 0, 1, 0.9)` (`CarbonMotion`).
- Compact typography: label-01 and helper-text-01 12/16, body-compact-01 14/18,
  body-01 14/20, heading-compact-01 14/18 semibold, heading-compact-02 16/22
  semibold, heading-03 20/28, code-01 12/16.
- Touch typography is a package decision, not a Carbon set; see
  `deviations.md`.

## Regenerating

Both generators are maintenance-only. The generated files are committed, so
building and testing never run them.

Colors:

```bash
npm i --ignore-scripts @carbon/themes@<version>      # in a scratch directory
node tool/generate_colors.cjs <scratch-directory> lib/src/foundations/colors.dart \
  > lib/src/foundations/colors.g.dart
```

Icons (append names to `ICONS` in the script to bundle more; the bundled set
includes `user`, `login` and `download` for account and update affordances):

```bash
npm pack @carbon/icons@<version> && tar xzf carbon-icons-<version>.tgz
node tool/generate_icons.cjs <extracted>/package > lib/src/foundations/icons.g.dart
```

After either, update the table above, `NOTICE`, and run `flutter test` (the
contrast tests re-check the built-in palettes).

## Reference URLs

| Foundation | Carbon reference |
| --- | --- |
| F01 Color roles | https://carbondesignsystem.com/elements/color/overview/ |
| F02 Themes, layering | https://carbondesignsystem.com/elements/themes/overview/ |
| F03 Typography | https://carbondesignsystem.com/elements/typography/overview/ |
| F04 Layout, spacing | https://carbondesignsystem.com/elements/spacing/overview/ |
| F05 Icons | https://carbondesignsystem.com/elements/icons/library/ |
| F06 Interaction states | https://carbondesignsystem.com/elements/color/usage/ |
| F07 Focus, keyboard | https://carbondesignsystem.com/guidelines/accessibility/keyboard/ |
| F08 Accessibility | https://carbondesignsystem.com/guidelines/accessibility/overview/ |
| F09 Overlays | https://carbondesignsystem.com/components/overview/ |
| F10 Motion | https://carbondesignsystem.com/elements/motion/overview/ |
| Components | https://carbondesignsystem.com/components/overview/components/ |
