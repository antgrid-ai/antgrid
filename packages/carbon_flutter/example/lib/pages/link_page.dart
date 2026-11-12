import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../gallery_scaffold.dart';

class LinkPage extends StatefulWidget {
  const LinkPage({super.key});

  @override
  State<LinkPage> createState() => _LinkPageState();
}

class _LinkPageState extends State<LinkPage> {
  String _last = 'none';

  void _go(String to) => setState(() => _last = to);

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final body = theme.typography.control.copyWith(
      color: theme.colors.textPrimary,
    );
    return GalleryPage(
      title: 'Link',
      summary:
          'A text action that navigates. Hover, press and keyboard focus '
          'underline it; inline links are always underlined.',
      children: [
        GallerySection(
          title: 'Sizes',
          children: [
            for (final size in CarbonLinkSize.values)
              CarbonLink(
                label: 'Carbon link (${size.name})',
                size: size,
                onPressed: () => _go(size.name),
              ),
          ],
        ),
        GallerySection(
          title: 'With icon',
          children: [
            CarbonLink(
              label: 'Open documentation',
              icon: const CarbonIcon(CarbonIcons.launch),
              onPressed: () => _go('documentation'),
            ),
          ],
        ),
        GallerySection(
          title: 'Inline',
          children: [
            Wrap(
              spacing: CarbonSpacing.spacing03,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('Read the', style: body),
                CarbonLink(
                  label: 'guidelines',
                  inline: true,
                  onPressed: () => _go('guidelines'),
                ),
                Text('before you start.', style: body),
              ],
            ),
          ],
        ),
        GallerySection(
          title: 'Disabled',
          children: [
            const CarbonLink(label: 'Unavailable link'),
            const CarbonLink(label: 'Unavailable inline link', inline: true),
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
