import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../gallery_scaffold.dart';

class LoadingPage extends StatefulWidget {
  const LoadingPage({super.key});

  @override
  State<LoadingPage> createState() => _LoadingPageState();
}

class _LoadingPageState extends State<LoadingPage> {
  bool _loading = true;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    return GalleryPage(
      title: 'Loading',
      summary:
          'Indeterminate progress for a region or a view. Reduced motion '
          'switches to a static arc; hidden panes stop animating.',
      children: [
        const GallerySection(
          title: 'Sizes',
          children: [
            GalleryStateGrid(
              cells: [
                GalleryStateCell('Large (88)', CarbonLoading()),
                GalleryStateCell(
                  'Small (16)',
                  CarbonLoading(size: CarbonLoadingSize.small),
                ),
                GalleryStateCell('Spinner (24)', CarbonSpinner(size: 24)),
              ],
            ),
          ],
        ),
        const GallerySection(
          title: 'With a message',
          children: [
            CarbonLoading(message: 'Loading the file tree for this project...'),
            CarbonLoading(
              size: CarbonLoadingSize.small,
              message: 'Connecting to your machine',
            ),
          ],
        ),
        const GallerySection(
          title: 'Static (paused)',
          description: 'An inactive spinner does not tick.',
          children: [
            GalleryStateGrid(
              cells: [
                GalleryStateCell(
                  'active: false',
                  CarbonLoading(size: CarbonLoadingSize.small, active: false),
                ),
              ],
            ),
          ],
        ),
        GallerySection(
          title: 'Region overlay',
          description:
              'Only the box that hosts the overlay is covered. The button '
              'below is unaffected.',
          children: [
            SizedBox(
              height: 220,
              child: CarbonLoadingOverlay(
                loading: _loading,
                message: 'Refreshing',
                child: CarbonLayerSurface(
                  border: true,
                  padding: const EdgeInsets.all(CarbonSpacing.spacing05),
                  child: Text(
                    'Content that is unavailable while the host works. '
                    'The scrim and the spinner cover this region only.',
                    style: theme.typography.body,
                  ),
                ),
              ),
            ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: CarbonButton(
                label: _loading ? 'Stop loading' : 'Start loading',
                kind: CarbonButtonKind.tertiary,
                onPressed: () => setState(() => _loading = !_loading),
              ),
            ),
          ],
        ),
        const GalleryNote(
          useWhen:
              'A region or view has no content yet or is being replaced. '
              'For a pending action, prefer inline loading or a busy button.',
          keyboard:
              'Not focusable. The overlay removes the covered controls '
              'from keyboard focus while it is shown.',
          accessibility:
              'A live region announces the message (or "Loading") once; '
              'the animation is silent. Reduced motion draws a static arc.',
          carbonReference:
              'Carbon v11 Loading. Deviations: an optional visible message '
              'under the spinner, which Carbon Loading lacks; the arc is '
              'painted rather than an SVG dash animation; the overlay '
              'covers its own region and also hides it from assistive '
              'technology.',
        ),
      ],
    );
  }
}
