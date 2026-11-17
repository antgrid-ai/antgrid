// Regenerates lib/src/foundations/colors.g.dart from the pinned Carbon theme
// package. Maintenance-only: the generated file is committed, so building or
// testing the package never runs this.
//
//   npm i --ignore-scripts @carbon/themes@<version>   (in any scratch directory)
//   node tool/generate_colors.cjs <scratch-directory> lib/src/foundations/colors.dart \
//     > lib/src/foundations/colors.g.dart
//
// Record the new version in doc/carbon-baseline.md with the regeneration.
const path = require('path');

const root = process.argv[2];
if (!root) {
  console.error('usage: node tool/generate_colors.cjs <dir containing node_modules/@carbon/themes>');
  process.exit(2);
}
const themes = require(path.join(root, 'node_modules/@carbon/themes'));
const version = require(path.join(root, 'node_modules/@carbon/themes/package.json')).version;

const THEMES = [
  ['white', 'white', 'whiteTheme'],
  ['gray10', 'g10', 'g10'],
  ['gray90', 'g90', 'g90'],
  ['gray100', 'g100', 'g100'],
];

const ROLES = [
  ['background', 'Default page background.'],
  ['backgroundHover', 'Hover tint over [background].'],
  ['backgroundActive', 'Pressed tint over [background].'],
  ['backgroundSelected', 'Selected tint over [background].'],
  ['backgroundSelectedHover', 'Hover tint over a selected [background] item.'],
  ['backgroundInverse', 'High-contrast inverse surface, e.g. tooltips.'],
  ['backgroundInverseHover', 'Hover over [backgroundInverse].'],
  ['backgroundBrand', 'Brand-colored surface.'],
  ['layer01', 'First container layer on [background].'],
  ['layer02', 'Second container layer.'],
  ['layer03', 'Third container layer.'],
  ['layerHover01', ''], ['layerHover02', ''], ['layerHover03', ''],
  ['layerActive01', ''], ['layerActive02', ''], ['layerActive03', ''],
  ['layerSelected01', ''], ['layerSelected02', ''], ['layerSelected03', ''],
  ['layerSelectedHover01', ''], ['layerSelectedHover02', ''], ['layerSelectedHover03', ''],
  ['layerSelectedInverse', 'Inverse selected layer, e.g. a selected content-switcher item.'],
  ['layerSelectedDisabled', ''],
  ['layerAccent01', ''], ['layerAccent02', ''], ['layerAccent03', ''],
  ['layerAccentHover01', ''], ['layerAccentHover02', ''], ['layerAccentHover03', ''],
  ['layerAccentActive01', ''], ['layerAccentActive02', ''], ['layerAccentActive03', ''],
  ['field01', 'Field fill on layer 1.'], ['field02', 'Field fill on layer 2.'], ['field03', 'Field fill on layer 3.'],
  ['fieldHover01', ''], ['fieldHover02', ''], ['fieldHover03', ''],
  ['borderSubtle00', ''], ['borderSubtle01', ''], ['borderSubtle02', ''], ['borderSubtle03', ''],
  ['borderSubtleSelected01', ''], ['borderSubtleSelected02', ''], ['borderSubtleSelected03', ''],
  ['borderStrong01', ''], ['borderStrong02', ''], ['borderStrong03', ''],
  ['borderTile01', ''], ['borderTile02', ''], ['borderTile03', ''],
  ['borderInverse', ''], ['borderInteractive', ''], ['borderDisabled', ''],
  ['textPrimary', ''], ['textSecondary', ''], ['textPlaceholder', ''], ['textHelper', ''],
  ['textError', ''], ['textInverse', ''], ['textOnColor', ''], ['textOnColorDisabled', ''], ['textDisabled', ''],
  ['linkPrimary', ''], ['linkPrimaryHover', ''], ['linkSecondary', ''], ['linkVisited', ''],
  ['linkInverse', ''], ['linkInverseActive', ''], ['linkInverseHover', ''], ['linkInverseVisited', ''],
  ['iconPrimary', ''], ['iconSecondary', ''], ['iconOnColor', ''], ['iconOnColorDisabled', ''],
  ['iconInverse', ''], ['iconDisabled', ''], ['iconInteractive', ''],
  ['supportError', ''], ['supportSuccess', ''], ['supportWarning', ''], ['supportInfo', ''],
  ['supportErrorInverse', ''], ['supportSuccessInverse', ''], ['supportWarningInverse', ''], ['supportInfoInverse', ''],
  ['supportCautionMajor', ''], ['supportCautionMinor', ''], ['supportCautionUndefined', ''],
  ['focus', 'Keyboard focus outline.'], ['focusInset', 'Inner contrast ring inside [focus] on colored fills.'],
  ['focusInverse', ''],
  ['interactive', ''], ['highlight', ''], ['overlay', 'Modal scrim.'], ['toggleOff', ''], ['shadow', ''],
  ['skeletonBackground', ''], ['skeletonElement', ''],
  ['buttonPrimary', ''], ['buttonPrimaryHover', ''], ['buttonPrimaryActive', ''],
  ['buttonSecondary', ''], ['buttonSecondaryHover', ''], ['buttonSecondaryActive', ''],
  ['buttonTertiary', ''], ['buttonTertiaryHover', ''], ['buttonTertiaryActive', ''],
  ['buttonDangerPrimary', ''], ['buttonDangerSecondary', ''], ['buttonDangerHover', ''], ['buttonDangerActive', ''],
  ['buttonSeparator', ''], ['buttonDisabled', ''],
  ['notificationBackgroundError', ''], ['notificationBackgroundSuccess', ''],
  ['notificationBackgroundInfo', ''], ['notificationBackgroundWarning', ''],
  ['notificationActionHover', ''],
];

const TAG_HUES = ['gray', 'coolGray', 'warmGray', 'red', 'magenta', 'purple', 'blue', 'cyan', 'teal', 'green'];

const componentTokens = Object.assign(
  {},
  themes.buttonTokens,
  themes.notificationTokens,
  themes.tagTokens,
  themes.contentSwitcherTokens,
);

function resolve(themeKey, componentKey, role) {
  const fromTheme = themes[themeKey][role];
  if (fromTheme !== undefined) return fromTheme;
  const token = componentTokens[role];
  if (token) {
    const v = token[componentKey] ?? token.fallback;
    if (v !== undefined) return v;
    // notificationActionHover is defined for light themes only; Carbon falls
    // back to layer01 hover on dark themes.
    if (role === 'notificationActionHover') return themes[themeKey].layerHover01;
  }
  throw new Error(`unresolved token ${role} for ${themeKey}`);
}

function dartColor(value) {
  const v = String(value).trim();
  let m = v.match(/^#([0-9a-f]{6})$/i);
  if (m) return `Color(0xFF${m[1].toUpperCase()})`;
  m = v.match(/^rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*(?:,\s*([\d.]+)\s*)?\)$/i);
  if (m) {
    const a = m[4] === undefined ? 1 : parseFloat(m[4]);
    const hex = (n) => Number(n).toString(16).padStart(2, '0').toUpperCase();
    return `Color(0x${hex(Math.round(a * 255))}${hex(m[1])}${hex(m[2])}${hex(m[3])})`;
  }
  throw new Error(`unparseable color ${v}`);
}

const cap = (s) => s[0].toUpperCase() + s.slice(1);
const out = [];
const w = (s = '') => out.push(s);

w('// GENERATED by tool/generate_colors.cjs from @carbon/themes ' + version + '. Do not edit.');
w();
w("part of 'colors.dart';");
w();
w(`/// The @carbon/themes release the built-in palettes were generated from.`);
w(`const String carbonThemesVersion = '${version}';`);
w();
w('const List<String> _roleNames = <String>[');
for (const [role] of ROLES) w(`  '${role}',`);
w('];');
w();
for (const [dartName, themeKey, componentKey] of THEMES) {
  w(`const CarbonColors _${dartName} = CarbonColors(`);
  for (const [role] of ROLES) w(`  ${role}: ${dartColor(resolve(themeKey, componentKey, role))},`);
  for (const hue of TAG_HUES) {
    const H = cap(hue);
    w(`  tag${H}: CarbonTagColors(`);
    w(`    background: ${dartColor(resolve(themeKey, componentKey, 'tagBackground' + H))},`);
    w(`    foreground: ${dartColor(resolve(themeKey, componentKey, 'tagColor' + H))},`);
    w(`    hover: ${dartColor(resolve(themeKey, componentKey, 'tagHover' + H))},`);
    w(`    border: ${dartColor(resolve(themeKey, componentKey, 'tagBorder' + H))},`);
    w('  ),');
  }
  w(');');
  w();
}
process.stdout.write(out.join('\n') + '\n');

// The class itself is generated too, so a new role is one edit to ROLES rather
// than five hand-kept lists (fields, constructor, copyWith, ==, hashCode).
const cls = [];
const c = (s = '') => cls.push(s);
c('// GENERATED by tool/generate_colors.cjs from @carbon/themes ' + version + '. Do not edit.');
c();
c("import 'package:flutter/painting.dart';");
c("import 'package:flutter/foundation.dart';");
c();
c("part 'colors.g.dart';");
c();
c('/// Background, foreground, hover and border for one Carbon tag hue.');
c('@immutable');
c('class CarbonTagColors {');
c('  const CarbonTagColors({required this.background, required this.foreground, required this.hover, required this.border});');
c('  final Color background;');
c('  final Color foreground;');
c('  final Color hover;');
c('  final Color border;');
c();
c('  @override');
c('  bool operator ==(Object other) =>');
c('      other is CarbonTagColors && other.background == background && other.foreground == foreground && other.hover == hover && other.border == border;');
c();
c('  @override');
c('  int get hashCode => Object.hash(background, foreground, hover, border);');
c('}');
c();
c('/// Carbon semantic color roles, separate from the theme values assigned to');
c('/// them. Use the role that matches the meaning, never a color that merely');
c('/// looks right: a custom theme overrides values, not meanings.');
c('@immutable');
c('class CarbonColors {');
c('  const CarbonColors({');
for (const [role] of ROLES) c(`    required this.${role},`);
for (const hue of TAG_HUES) c(`    required this.tag${cap(hue)},`);
c('  });');
c();
c('  /// Carbon White.');
c('  static const CarbonColors white = _white;');
c('  /// Carbon Gray 10.');
c('  static const CarbonColors gray10 = _gray10;');
c('  /// Carbon Gray 90.');
c('  static const CarbonColors gray90 = _gray90;');
c('  /// Carbon Gray 100.');
c('  static const CarbonColors gray100 = _gray100;');
c();
c('  /// Every role name, in declaration order. Used by contrast validation.');
c('  static List<String> get roleNames => _roleNames;');
c();
for (const [role, doc] of ROLES) {
  if (doc) c(`  /// ${doc}`);
  c(`  final Color ${role};`);
}
for (const hue of TAG_HUES) c(`  final CarbonTagColors tag${cap(hue)};`);
c();
c('  /// Looks a role up by its Carbon name; null when unknown.');
c('  Color? role(String name) => switch (name) {');
for (const [role] of ROLES) c(`        '${role}' => ${role},`);
c('        _ => null,');
c('      };');
c();
c('  CarbonColors copyWith({');
for (const [role] of ROLES) c(`    Color? ${role},`);
for (const hue of TAG_HUES) c(`    CarbonTagColors? tag${cap(hue)},`);
c('  }) {');
c('    return CarbonColors(');
for (const [role] of ROLES) c(`      ${role}: ${role} ?? this.${role},`);
for (const hue of TAG_HUES) c(`      tag${cap(hue)}: tag${cap(hue)} ?? this.tag${cap(hue)},`);
c('    );');
c('  }');
c();
c('  @override');
c('  bool operator ==(Object other) {');
c('    if (identical(this, other)) return true;');
c('    return other is CarbonColors &&');
for (const [role] of ROLES) c(`        other.${role} == ${role} &&`);
c(TAG_HUES.map((h) => `        other.tag${cap(h)} == tag${cap(h)}`).join(' &&\n') + ';');
c('  }');
c();
c('  @override');
c('  int get hashCode => Object.hashAll(<Object>[');
for (const [role] of ROLES) c(`        ${role},`);
for (const hue of TAG_HUES) c(`        tag${cap(hue)},`);
c('      ]);');
c('}');
require('fs').writeFileSync(process.argv[3] || 'colors.dart', cls.join('\n') + '\n');
