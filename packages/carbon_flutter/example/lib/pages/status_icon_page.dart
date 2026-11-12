import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../gallery_scaffold.dart';

/// Gallery page for [CarbonStatusIcon].
class StatusIconPage extends StatelessWidget {
  const StatusIconPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final label = theme.typography.control.copyWith(
      color: theme.colors.textPrimary,
    );
    return GalleryPage(
      title: 'Status icon',
      summary:
          'The filled error, warning, success and information glyphs that '
          'notifications lead with, for status beside other content. Give it '
          'a label when it is the only carrier of the state.',
      children: [
        GallerySection(
          title: 'Kinds',
          children: [
            Wrap(
              spacing: CarbonSpacing.spacing06,
              runSpacing: CarbonSpacing.spacing04,
              children: [
                for (final kind in CarbonStatusKind.values)
                  Wrap(
                    spacing: CarbonSpacing.spacing03,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      CarbonStatusIcon(kind),
                      Text(kind.name, style: label),
                    ],
                  ),
              ],
            ),
          ],
        ),
        GallerySection(
          title: 'Sizes',
          children: [
            Wrap(
              spacing: CarbonSpacing.spacing05,
              runSpacing: CarbonSpacing.spacing04,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final size in const [16.0, 20.0, 24.0, 32.0])
                  CarbonStatusIcon(CarbonStatusKind.warning, size: size),
              ],
            ),
          ],
        ),
        GallerySection(
          title: 'Labelled',
          description: 'Announced as an image; unlabelled icons are skipped.',
          children: [
            Wrap(
              spacing: CarbonSpacing.spacing03,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const CarbonStatusIcon(
                  CarbonStatusKind.error,
                  semanticLabel: 'Failed',
                ),
                Text('Last run', style: label),
              ],
            ),
          ],
        ),
      ],
    );
  }
}
