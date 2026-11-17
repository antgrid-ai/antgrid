import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../../gallery_scaffold.dart';

/// Nested layer surfaces with the field token each level selects.
class LayersPage extends StatelessWidget {
  const LayersPage({super.key});

  @override
  Widget build(BuildContext context) {
    return GalleryPage(
      title: 'Layers',
      summary:
          'A surface paints the current layer and raises its children one '
          'level, so a field inside always contrasts with what it sits on.',
      children: [
        GallerySection(
          title: 'Nested surfaces',
          children: [
            const _FieldSample(label: 'Page background'),
            CarbonLayerSurface(
              border: true,
              padding: const EdgeInsets.all(CarbonSpacing.spacing05),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _SurfaceLabel('layer01'),
                  const _FieldSample(label: 'Inside layer 01'),
                  const SizedBox(height: CarbonSpacing.spacing05),
                  CarbonLayerSurface(
                    border: true,
                    padding: const EdgeInsets.all(CarbonSpacing.spacing05),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const _SurfaceLabel('layer02'),
                        const _FieldSample(label: 'Inside layer 02'),
                        const SizedBox(height: CarbonSpacing.spacing05),
                        CarbonLayerSurface(
                          border: true,
                          padding: const EdgeInsets.all(CarbonSpacing.spacing05),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const _SurfaceLabel('layer03'),
                              const _FieldSample(label: 'Inside layer 03'),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const GalleryNote(
          useWhen:
              'Placing fields, tiles or panels on a surface that is not the '
              'page background.',
          keyboard: 'Not interactive.',
          accessibility:
              'Layer contrast is a fill difference plus a subtle border, so '
              'edges stay visible in every theme.',
          carbonReference: 'Layering: background, layer, field, border tokens.',
        ),
      ],
    );
  }
}

class _SurfaceLabel extends StatelessWidget {
  const _SurfaceLabel(this.name);

  final String name;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: CarbonSpacing.spacing03),
      child: Text(
        'Surface $name',
        style: theme.typography.heading.copyWith(
          color: theme.colors.textPrimary,
        ),
      ),
    );
  }
}

class _FieldSample extends StatelessWidget {
  const _FieldSample({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final level = CarbonLayer.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.field(level),
        border: Border(
          bottom: BorderSide(color: theme.borderStrong(level)),
        ),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: theme.controlHeight),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: theme.controlPaddingX,
            vertical: CarbonSpacing.spacing02,
          ),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text(
              '$label: field0$level',
              style: theme.typography.control.copyWith(
                color: theme.colors.textPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
