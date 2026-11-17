import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../../gallery_scaffold.dart';
import 'color_roles.dart';

String _hex(Color c) {
  String part(double v) =>
      (v * 255).round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
  final alpha = (c.a * 255).round();
  final rgb = '#${part(c.r)}${part(c.g)}${part(c.b)}'.toUpperCase();
  return alpha == 255 ? rgb : '$rgb @ ${(c.a * 100).round()}%';
}

/// Every role of the active palette, grouped, plus the tag hues.
class ColorsPage extends StatelessWidget {
  const ColorsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    return GalleryPage(
      title: 'Colors',
      summary:
          'Semantic roles of the ${theme.scheme.name} palette. Components '
          'pick the role that matches the meaning, never a lookalike value.',
      children: [
        for (final group in colorRoleGroups.entries)
          GallerySection(
            title: group.key,
            children: [
              for (final role in group.value)
                _SwatchRow(name: role.name, color: role.read(theme.colors)),
            ],
          ),
        GallerySection(
          title: 'Tag hues',
          description:
              'Each hue carries background, foreground, hover and border. '
              'Text on a tag is never the only carrier of meaning.',
          children: [
            for (final tag in tagRoles)
              _TagRow(name: tag.name, tag: tag.read(theme.colors)),
          ],
        ),
        const GalleryNote(
          useWhen:
              'Choosing the token for a surface, text, icon, border or state.',
          keyboard: 'Not interactive.',
          accessibility:
              'Swatches are labelled with role name and value; meaning is '
              'never carried by color alone.',
          carbonReference: 'Color tokens, core themes White, G10, G90, G100.',
        ),
      ],
    );
  }
}

class _SwatchRow extends StatelessWidget {
  const _SwatchRow({required this.name, required this.color});

  final String name;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final value = _hex(color);
    return Semantics(
      container: true,
      excludeSemantics: true,
      label: '$name $value',
      child: Row(
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: theme.colors.background,
              border: Border.all(color: theme.colors.borderStrong01),
            ),
            child: SizedBox.square(
              dimension: 32,
              child: ColoredBox(color: color),
            ),
          ),
          const SizedBox(width: CarbonSpacing.spacing04),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: theme.typography.code),
                Text(
                  value,
                  style: theme.typography.helper.copyWith(
                    color: theme.colors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TagRow extends StatelessWidget {
  const _TagRow({required this.name, required this.tag});

  final String name;
  final CarbonTagColors tag;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    Widget pill(String text, Color background) => DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        border: Border.all(color: tag.border),
        borderRadius: const BorderRadius.all(CarbonShape.pill),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: CarbonSpacing.spacing03,
          vertical: CarbonSpacing.spacing01,
        ),
        child: Text(
          text,
          style: theme.typography.label.copyWith(color: tag.foreground),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(name, style: theme.typography.code),
        const SizedBox(height: CarbonSpacing.spacing02),
        Wrap(
          spacing: CarbonSpacing.spacing03,
          runSpacing: CarbonSpacing.spacing02,
          children: [
            pill('Rest', tag.background),
            pill('Hover', tag.hover),
          ],
        ),
      ],
    );
  }
}
