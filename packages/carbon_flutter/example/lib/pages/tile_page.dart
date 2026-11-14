import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../gallery_scaffold.dart';

class TilePage extends StatefulWidget {
  const TilePage({super.key});

  @override
  State<TilePage> createState() => _TilePageState();
}

class _TilePageState extends State<TilePage> {
  String _last = 'none';

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    return GalleryPage(
      title: 'Tile',
      summary:
          'A clickable tile is a whole-surface action. It darkens on hover and '
          'press, shows a focus outline from the keyboard and carries '
          "Carbon's trailing arrow.",
      children: [
        GallerySection(
          title: 'Clickable',
          children: [
            CarbonClickableTile(
              onPressed: () => setState(() => _last = 'clickable'),
              child: const Text('Open the project overview'),
            ),
            CarbonClickableTile(
              semanticLabel: 'Read the setup guide',
              onPressed: () => setState(() => _last = 'long'),
              child: const Text(
                'A longer tile wraps its text and keeps clear of the arrow in '
                'the bottom corner, however narrow the column is.',
              ),
            ),
          ],
        ),
        GallerySection(
          title: 'Layered',
          description: 'A tile steps up a layer inside a layered surface.',
          children: [
            CarbonLayerSurface(
              padding: const EdgeInsets.all(CarbonSpacing.spacing05),
              child: CarbonClickableTile(
                onPressed: () => setState(() => _last = 'layered'),
                child: const Text('Tile on layer two'),
              ),
            ),
          ],
        ),
        GallerySection(
          title: 'Disabled',
          children: [
            const CarbonClickableTile(child: Text('Unavailable tile')),
            Text(
              'Last pressed: $_last',
              style: theme.typography.helper.copyWith(
                color: theme.colors.textSecondary,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
