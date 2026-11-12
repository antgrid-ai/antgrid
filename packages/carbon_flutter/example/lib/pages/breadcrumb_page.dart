import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../gallery_scaffold.dart';

class BreadcrumbPage extends StatefulWidget {
  const BreadcrumbPage({super.key});

  @override
  State<BreadcrumbPage> createState() => _BreadcrumbPageState();
}

class _BreadcrumbPageState extends State<BreadcrumbPage> {
  String _last = 'none';

  void _go(String to) => setState(() => _last = to);

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    return GalleryPage(
      title: 'Breadcrumb',
      summary:
          'The path from a parent page to the current one. Links navigate; '
          'the current page is plain text.',
      children: [
        GallerySection(
          title: 'Page header',
          children: [
            CarbonBreadcrumb(
              items: [
                CarbonBreadcrumbItem(
                  label: 'Schedules',
                  onPressed: () => _go('Schedules'),
                ),
              ],
            ),
            Text(
              'New schedule',
              style: theme.typography.title.copyWith(
                color: theme.colors.textPrimary,
              ),
            ),
          ],
        ),
        GallerySection(
          title: 'Several steps, no trailing slash',
          children: [
            CarbonBreadcrumb(
              trailingSlash: false,
              items: [
                CarbonBreadcrumbItem(
                  label: 'Projects',
                  onPressed: () => _go('Projects'),
                ),
                CarbonBreadcrumbItem(
                  label: 'antgrid',
                  onPressed: () => _go('antgrid'),
                ),
                const CarbonBreadcrumbItem(label: 'Settings'),
              ],
            ),
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
