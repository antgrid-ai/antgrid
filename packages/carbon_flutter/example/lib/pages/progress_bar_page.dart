import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../gallery_scaffold.dart';

/// Gallery page for [CarbonProgressBar].
class ProgressBarPage extends StatelessWidget {
  const ProgressBarPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const GalleryPage(
      title: 'Progress bar',
      summary:
          'A horizontal bar for a task with a known fraction complete, or an '
          'indeterminate band while the amount is unknown.',
      children: [
        GallerySection(
          title: 'Determinate',
          children: [
            CarbonProgressBar(
              value: 0.4,
              label: 'Uploading logs',
              helperText: 'Optional helper text',
            ),
            SizedBox(height: CarbonSpacing.spacing05),
            CarbonProgressBar(
              value: 0.7,
              size: CarbonProgressBarSize.small,
              label: 'Small bar',
            ),
          ],
        ),
        GallerySection(
          title: 'Indeterminate',
          description:
              'Static under reduced motion or when animation is turned off.',
          children: [
            CarbonProgressBar(label: 'Scanning files'),
            SizedBox(height: CarbonSpacing.spacing05),
            CarbonProgressBar(
              animateIndeterminate: false,
              label: 'Static band',
            ),
          ],
        ),
        GallerySection(
          title: 'Status',
          children: [
            CarbonProgressBar(
              value: 1,
              status: CarbonProgressBarStatus.finished,
              label: 'Export finished',
            ),
            SizedBox(height: CarbonSpacing.spacing05),
            CarbonProgressBar(
              value: 0.3,
              status: CarbonProgressBarStatus.error,
              label: 'Export failed',
              helperText: 'The connection was lost.',
            ),
            SizedBox(height: CarbonSpacing.spacing05),
            CarbonProgressBar(value: 0.5, hideLabel: true, label: 'Hidden label'),
          ],
        ),
      ],
    );
  }
}
