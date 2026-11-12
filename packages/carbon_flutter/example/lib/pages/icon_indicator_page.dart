import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../gallery_scaffold.dart';

String _words(CarbonIconIndicatorKind kind) {
  final spaced = kind.name.replaceAllMapped(
    RegExp('[A-Z]'),
    (m) => ' ${m[0]!.toLowerCase()}',
  );
  return spaced[0].toUpperCase() + spaced.substring(1);
}

/// Gallery page for [CarbonIconIndicator].
class IconIndicatorPage extends StatelessWidget {
  const IconIndicatorPage({super.key});

  @override
  Widget build(BuildContext context) {
    return GalleryPage(
      title: 'Icon indicator',
      summary:
          'A status glyph in its status colour with a label, for data '
          'tables, task lists and dashboards. Every kind is the same size.',
      children: [
        GallerySection(
          title: 'Kinds',
          children: [
            Wrap(
              spacing: CarbonSpacing.spacing06,
              runSpacing: CarbonSpacing.spacing04,
              children: [
                for (final kind in CarbonIconIndicatorKind.values)
                  CarbonIconIndicator(kind: kind, label: _words(kind)),
              ],
            ),
          ],
        ),
        GallerySection(
          title: 'Compact',
          description: 'The label moves to a tooltip and the accessible name.',
          children: [
            Wrap(
              spacing: CarbonSpacing.spacing04,
              children: [
                for (final kind in CarbonIconIndicatorKind.values)
                  CarbonIconIndicator(
                    kind: kind,
                    label: _words(kind),
                    compact: true,
                  ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}
