import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../../gallery_scaffold.dart';

String _px(double v) => '${v.round()}px';

/// Control metrics for both densities side by side.
class DensityPage extends StatelessWidget {
  const DensityPage({super.key});

  @override
  Widget build(BuildContext context) {
    final active = CarbonTheme.of(context);
    final compact = active.copyWith(density: CarbonDensity.compact);
    final touch = active.copyWith(density: CarbonDensity.touch);
    final rows = <(String, String Function(CarbonThemeData))>[
      ('Control height', (t) => _px(t.controlHeight)),
      ('Small control', (t) => _px(t.smallControlHeight)),
      ('Large control', (t) => _px(t.largeControlHeight)),
      ('Minimum target', (t) => _px(t.minTarget)),
      ('Icon size', (t) => _px(t.iconSize)),
      ('Horizontal padding', (t) => _px(t.controlPaddingX)),
      ('Control text', (t) => _px(t.typography.control.fontSize ?? 0)),
      ('Body text', (t) => _px(t.typography.body.fontSize ?? 0)),
    ];
    return GalleryPage(
      title: 'Density',
      summary:
          'Density is chosen by the host and is never inferred from width, '
          'pointer or text scale. Heights are minimums: larger text grows '
          'a control past them.',
      children: [
        GallerySection(
          title: 'Metrics',
          children: [
            _MetricRow(
              label: '',
              compact: 'Compact',
              touch: 'Touch',
              header: true,
            ),
            for (final row in rows)
              _MetricRow(
                label: row.$1,
                compact: row.$2(compact),
                touch: row.$2(touch),
              ),
          ],
        ),
        GallerySection(
          title: 'Sample control',
          description: 'The same control at each density.',
          children: [
            GalleryStateGrid(
              cells: [
                GalleryStateCell(
                  'Compact',
                  CarbonTheme(
                    data: active,
                    density: CarbonDensity.compact,
                    child: const _MockControl(width: 200),
                  ),
                ),
                GalleryStateCell(
                  'Touch',
                  CarbonTheme(
                    data: active,
                    density: CarbonDensity.touch,
                    child: const _MockControl(width: 200),
                  ),
                ),
              ],
            ),
          ],
        ),
        GallerySection(
          title: 'Wide layout, touch density',
          description:
              'A wide surface can still be touch: the host owns the choice, '
              'so a touch-first desktop keeps 48px targets.',
          children: [
            CarbonTheme(
              data: active,
              density: CarbonDensity.touch,
              child: const _MockControl(width: double.infinity),
            ),
          ],
        ),
        const GalleryNote(
          useWhen:
              'Choosing compact for pointer and keyboard workflows and touch '
              'for finger interaction.',
          keyboard: 'Not interactive.',
          accessibility:
              'Touch keeps 48px targets; compact never drops below 24px and '
              'documents where it does.',
          carbonReference: 'Sizing: 24, 32, 40, 48 control heights.',
        ),
      ],
    );
  }
}

class _MetricRow extends StatelessWidget {
  const _MetricRow({
    required this.label,
    required this.compact,
    required this.touch,
    this.header = false,
  });

  final String label;
  final String compact;
  final String touch;
  final bool header;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final style = header
        ? theme.typography.heading
        : theme.typography.body;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: CarbonSpacing.spacing02),
      child: Row(
        children: [
          Expanded(child: Text(label, style: style)),
          SizedBox(width: 88, child: Text(compact, style: style)),
          SizedBox(width: 88, child: Text(touch, style: style)),
        ],
      ),
    );
  }
}

class _MockControl extends StatelessWidget {
  const _MockControl({required this.width});

  final double width;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final level = CarbonLayer.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final resolved = width.isFinite
            ? width.clamp(0.0, constraints.maxWidth)
            : constraints.maxWidth;
        return SizedBox(
          width: resolved,
          child: DecoratedBox(
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
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Control',
                        style: theme.typography.control.copyWith(
                          color: theme.colors.textPrimary,
                        ),
                      ),
                    ),
                    CarbonIcon(CarbonIcons.search, size: theme.iconSize),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
