import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../gallery_scaffold.dart';

/// Gallery page for [CarbonDataTable].
class DataTablePage extends StatefulWidget {
  const DataTablePage({super.key});

  @override
  State<DataTablePage> createState() => _DataTablePageState();
}

class _DataTablePageState extends State<DataTablePage> {
  int? _selected = 0;
  final Set<int> _open = <int>{1};

  static const _columns = <CarbonDataTableColumn>[
    CarbonDataTableColumn(label: 'Name', flex: 2),
    CarbonDataTableColumn(label: 'Status'),
    CarbonDataTableColumn(label: 'Runs', align: CarbonDataTableAlign.end),
  ];

  static const _names = ['Nightly build', 'Dependency audit', 'Release notes'];

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
          title: 'Selected row',
          description:
              'The host owns selection; tap a row name to move it. The '
              'selected row fills with the selected layer colour.',
          children: [
            CarbonDataTable(
              columns: const [
                CarbonDataTableColumn(label: 'Name', flex: 2),
                CarbonDataTableColumn(label: 'Status'),
              ],
              rows: [
                for (var i = 0; i < _names.length; i++)
                  CarbonDataTableRow(
                    selected: _selected == i,
                    cells: [
                      CarbonLink(
                        label: _names[i],
                        onPressed: () => setState(() => _selected = i),
                      ),
                      const Text('Active'),
                    ],
                  ),
              ],
            ),
          ],
        ),
        GallerySection(
          title: 'Expandable row',
          description:
              'The host owns what opens a row; the content sits below the '
              'cells inside the same row.',
          children: [
            CarbonDataTable(
              columns: const [
                CarbonDataTableColumn(label: 'Name', flex: 2),
                CarbonDataTableColumn(label: ''),
              ],
              rows: [
                for (var i = 0; i < _names.length; i++)
                  CarbonDataTableRow(
                    cells: [
                      Text(_names[i]),
                      Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: CarbonButton(
                          label: _open.contains(i) ? 'Hide' : 'Details',
                          kind: CarbonButtonKind.ghost,
                          size: CarbonButtonSize.small,
                          expanded: _open.contains(i),
                          onPressed: () => setState(() {
                            if (!_open.remove(i)) _open.add(i);
                          }),
                        ),
                      ),
                    ],
                    expansion: _open.contains(i)
                        ? Text('Last run finished without warnings (${_names[i]}).')
                        : null,
                  ),
              ],
            ),
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
