import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../../gallery_scaffold.dart';

class _Row {
  const _Row(this.id, this.title, this.secondary);

  final int id;
  final String title;
  final String secondary;
}

/// A contained list with selection, per-row overflow menus and
/// empty/loading/error states driven by the host.
class RowActionsListComposition extends StatefulWidget {
  const RowActionsListComposition({super.key});

  @override
  State<RowActionsListComposition> createState() =>
      _RowActionsListCompositionState();
}

class _RowActionsListCompositionState extends State<RowActionsListComposition> {
  static const List<_Row> _initial = <_Row>[
    _Row(
      1,
      'Refactor the relay credit scheduler to drain per-stream queues fairly',
      'feature/relay-credit-windows, finished 12 minutes ago',
    ),
    _Row(2, 'Fix terminal resize strand', 'fix/terminal-resize, waiting'),
    _Row(
      3,
      'Investigate flaky bridge git tests under load',
      'main, running for 41 minutes',
    ),
    _Row(4, 'Draft release notes', 'docs/release-notes, idle'),
    _Row(5, 'Port scanning on Linux and macOS', 'feature/ports, failed'),
  ];

  List<_Row> _rows = List<_Row>.of(_initial);
  final Set<int> _selected = <int>{};
  CarbonContainedListStatus _status = CarbonContainedListStatus.content;
  String _state = 'content';

  void _setState(String value) {
    setState(() {
      _state = value;
      switch (value) {
        case 'loading':
          _status = CarbonContainedListStatus.loading;
        case 'error':
          _status = CarbonContainedListStatus.error;
        case 'empty':
          _rows = <_Row>[];
          _selected.clear();
          _status = CarbonContainedListStatus.content;
        default:
          _rows = List<_Row>.of(_initial);
          _status = CarbonContainedListStatus.content;
      }
    });
  }

  void _remove(_Row row) => setState(() {
    _rows = _rows.where((r) => r.id != row.id).toList();
    _selected.remove(row.id);
  });

  @override
  Widget build(BuildContext context) {
    return GalleryPage(
      title: 'List with row actions',
      summary:
          'Rows select independently of their actions; each row keeps its '
          'commands in an overflow menu so long titles never push them out.',
      children: [
        GallerySection(
          title: 'Sessions',
          children: [
            CarbonSelect<String>(
              key: const ValueKey('row-state'),
              label: 'List state',
              value: _state,
              options: const [
                CarbonOption(value: 'content', label: 'Content'),
                CarbonOption(value: 'loading', label: 'Loading'),
                CarbonOption(value: 'empty', label: 'Empty'),
                CarbonOption(value: 'error', label: 'Error'),
              ],
              onChanged: _setState,
            ),
            CarbonContainedList(
              key: const ValueKey('row-list'),
              label: 'Sessions',
              status: _status,
              action: CarbonButton.iconOnly(
                icon: const CarbonIcon(CarbonIcons.checkmark),
                semanticLabel: 'Select all sessions',
                size: CarbonButtonSize.small,
                onPressed: _rows.isEmpty
                    ? null
                    : () => setState(
                        () => _selected
                          ..clear()
                          ..addAll(_rows.map((r) => r.id)),
                      ),
              ),
              emptyContent: const Padding(
                padding: EdgeInsets.all(CarbonSpacing.spacing05),
                child: Text('No sessions match the current filters.'),
              ),
              errorContent: Padding(
                padding: const EdgeInsets.all(CarbonSpacing.spacing05),
                child: CarbonInlineLoading(
                  status: CarbonInlineLoadingStatus.error,
                  description: 'Sessions could not be loaded.',
                  onRetry: () => _setState('content'),
                ),
              ),
              children: [
                for (final row in _rows)
                  CarbonContainedListRow(
                    key: ValueKey('row-${row.id}'),
                    title: row.title,
                    secondary: row.secondary,
                    selected: _selected.contains(row.id),
                    onSelectedChanged: (v) => setState(() {
                      v ? _selected.add(row.id) : _selected.remove(row.id);
                    }),
                    actions: [
                      CarbonOverflowMenu(
                        key: ValueKey('row-menu-${row.id}'),
                        semanticLabel: 'Actions for ${row.title}',
                        entries: [
                          CarbonMenuItem(label: 'Rename', onPressed: () {}),
                          CarbonMenuItem(label: 'Duplicate', onPressed: () {}),
                          CarbonMenuItem(
                            label: 'Delete',
                            kind: CarbonMenuItemKind.danger,
                            onPressed: () => _remove(row),
                          ),
                        ],
                      ),
                    ],
                  ),
              ],
            ),
            Text(
              '${_selected.length} of ${_rows.length} selected',
              key: const ValueKey('row-selection-count'),
              style: CarbonTheme.of(context).typography.helper.copyWith(
                color: CarbonTheme.of(context).colors.textSecondary,
              ),
            ),
          ],
        ),
        const GalleryNote(
          useWhen:
              'A short collection where each item has a few commands and the '
              'user may act on several at once.',
          keyboard:
              'Arrow keys move between rows; Space toggles selection; Tab '
              "reaches a row's overflow menu.",
          accessibility:
              'Selection state is announced per row; the menu trigger is '
              'named after its row; loading and error replace the rows and '
              'announce themselves.',
          carbonReference: 'Carbon Contained list, Overflow menu.',
        ),
      ],
    );
  }
}
