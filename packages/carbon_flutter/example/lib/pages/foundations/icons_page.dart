import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../../gallery_scaffold.dart';

/// Every bundled glyph at compact and touch size, and RTL mirroring.
class IconsPage extends StatelessWidget {
  const IconsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final mirrored = CarbonIcons.values.where((i) => i.mirrorsInRtl).toList();
    return GalleryPage(
      title: 'Icons',
      summary:
          '${CarbonIcons.values.length} glyphs from Carbon icons '
          '$carbonIconsVersion. Icons are decorative unless given a label; '
          'the control that owns one announces itself.',
      children: [
        GallerySection(
          title: 'All glyphs',
          description: 'Compact (16) beside touch (20).',
          children: [
            Wrap(
              spacing: CarbonSpacing.spacing03,
              runSpacing: CarbonSpacing.spacing03,
              children: [
                for (final icon in CarbonIcons.values)
                  SizedBox(
                    width: 120,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            CarbonIcon(icon, size: 16),
                            const SizedBox(width: CarbonSpacing.spacing04),
                            CarbonIcon(icon, size: 20),
                          ],
                        ),
                        const SizedBox(height: CarbonSpacing.spacing02),
                        Text(
                          icon.name,
                          style: theme.typography.helper.copyWith(
                            color: theme.colors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ),
        GallerySection(
          title: 'Right-to-left mirroring',
          description:
              'Glyphs that point along the reading direction mirror; the rest '
              'never do. Each pair is forced to LTR then RTL.',
          children: [
            for (final icon in mirrored)
              Row(
                children: [
                  for (final direction in TextDirection.values) ...[
                    Directionality(
                      textDirection: direction,
                      child: CarbonIcon(icon, size: 20),
                    ),
                    const SizedBox(width: CarbonSpacing.spacing02),
                    Text(
                      direction.name.toUpperCase(),
                      style: theme.typography.label,
                    ),
                    const SizedBox(width: CarbonSpacing.spacing05),
                  ],
                  Flexible(
                    child: Text(icon.name, style: theme.typography.code),
                  ),
                ],
              ),
          ],
        ),
        const GalleryNote(
          useWhen: 'Reinforcing a label or standing alone in a named control.',
          keyboard: 'Not interactive on its own.',
          accessibility:
              'Excluded from semantics unless a semantic label is supplied; '
              'icon-only controls label the control, not the glyph.',
          carbonReference: 'Iconography: 32-unit grid, 16 and 20 in controls.',
        ),
      ],
    );
  }
}
