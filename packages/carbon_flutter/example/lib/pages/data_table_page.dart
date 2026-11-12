import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../gallery_scaffold.dart';

/// Gallery page for [CarbonDataTable].
class DataTablePage extends StatelessWidget {
  const DataTablePage({super.key});

  static const _columns = <CarbonDataTableColumn>[
    CarbonDataTableColumn(label: 'Name', flex: 2),
    CarbonDataTableColumn(label: 'Status'),
    CarbonDataTableColumn(label: 'Runs', align: CarbonDataTableAlign.end),
  ];

  static List<CarbonDataTableRow> _rows() => const [
    CarbonDataTableRow(cells: [Text('Nightly build'), Text('Active'), Text('412')]),
    CarbonDataTableRow(cells: [Text('Dependency audit'), Text('Paused'), Text('38')]),
    CarbonDataTableRow(cells: [Text('Release notes'), Text('Active'), Text('1,204')]),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    return GalleryPage(
      title: 'Data table',
      summary:
          'Static rows under a header row. Columns share one layout, rows '
          'grow with wrapped text and the hovered row is highlighted.',
      children: [
        GallerySection(
          title: 'Basic',
          children: [
            CarbonDataTable(
              title: 'Schedules',
              description: 'Runs the agent starts on its own.',
              columns: _columns,
              rows: _rows(),
            ),
          ],
        ),
        GallerySection(
          title: 'Sizes',
          description: 'Extra small, small, medium, large and extra large.',
          children: [
            for (final size in CarbonDataTableSize.values) ...[
              Text(
                size.name,
                style: theme.typography.helper.copyWith(
                  color: theme.colors.textSecondary,
                ),
              ),
              CarbonDataTable(size: size, columns: _columns, rows: _rows()),
            ],
          ],
        ),
        GallerySection(
          title: 'Wrapping cell',
          description: 'A tall cell grows its row; the others stay centred.',
          children: [
            CarbonDataTable(
              columns: _columns,
              rows: const [
                CarbonDataTableRow(
                  cells: [
                    Text(
                      'Review every open pull request, comment on anything '
                      'that changes behaviour and summarise the rest.',
                    ),
                    Text('Active'),
                    Text('7'),
                  ],
                ),
                CarbonDataTableRow(
                  cells: [Text('Cleanup'), Text('Paused'), Text('0')],
                ),
              ],
            ),
          ],
        ),
        GallerySection(
          title: 'Empty',
          children: [
            CarbonDataTable(
              columns: _columns,
              rows: const [],
              emptyState: Text(
                'No schedules yet',
                style: theme.typography.control.copyWith(
                  color: theme.colors.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
