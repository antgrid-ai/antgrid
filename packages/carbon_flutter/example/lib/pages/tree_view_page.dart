import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../gallery_scaffold.dart';

class _Entry {
  const _Entry(this.name, [this.children]);

  final String name;
  final List<_Entry>? children;
}

const List<_Entry> _files = <_Entry>[
  _Entry('lib', [
    _Entry('src', [_Entry('tree_view.dart'), _Entry('side_nav.dart')]),
    _Entry('carbon_flutter.dart'),
  ]),
  _Entry('test', [_Entry('tree_view_test.dart')]),
  _Entry('pubspec.yaml'),
  _Entry('README.md'),
];

/// Gallery page for [CarbonTreeView].
class TreeViewPage extends StatefulWidget {
  const TreeViewPage({super.key});

  @override
  State<TreeViewPage> createState() => _TreeViewPageState();
}

class _TreeViewPageState extends State<TreeViewPage> {
  final Set<String> _expanded = <String>{'lib', 'lib/src'};
  String? _selected;
  String? _active;
  bool _xs = false;
  bool _badges = true;

  List<CarbonTreeNodeData> _rows() {
    final rows = <CarbonTreeNodeData>[];
    void walk(_Entry entry, String path, int depth) {
      final kids = entry.children;
      final open = _expanded.contains(path);
      rows.add(
        CarbonTreeNodeData(
          id: path,
          label: entry.name,
          depth: depth,
          isBranch: kids != null,
          expanded: open,
          selected: _selected == path,
          active: _active == path,
          leading: CarbonIcon(
            kids != null ? CarbonIcons.folder : CarbonIcons.document,
          ),
          trailing: _badges && entry.name.endsWith('.dart')
              ? const CarbonTag(label: 'M', size: CarbonTagSize.small)
              : null,
          trailingOnHover: true,
        ),
      );
      if (kids != null && open) {
        for (final kid in kids) {
          walk(kid, '$path/${kid.name}', depth + 1);
        }
      }
    }

    for (final entry in _files) {
      walk(entry, entry.name, 0);
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows();
    return GalleryPage(
      title: 'Tree view',
      summary:
          'A flat, lazily built hierarchy with one tab stop. The host owns '
          'which branches are open and which rows are selected or active; '
          'every row has the same height so scroll offsets can be computed.',
      children: [
        GallerySection(
          title: 'File tree',
          description:
              'Arrow keys move, Right and Left open and close branches, '
              'Home and End jump, and typing jumps to a label. Tapping a '
              'file activates it (start bar); trailing marks show on hover '
              'or focus.',
          children: [
            CarbonToggle(
              labelText: 'Extra small rows',
              value: _xs,
              onChanged: (v) => setState(() => _xs = v),
            ),
            CarbonToggle(
              labelText: 'Trailing marks',
              value: _badges,
              onChanged: (v) => setState(() => _badges = v),
            ),
            SizedBox(
              width: 320,
              height: 260,
              child: CarbonTreeView(
                semanticLabel: 'Project files',
                size: _xs ? CarbonTreeViewSize.xs : CarbonTreeViewSize.sm,
                itemCount: rows.length,
                itemBuilder: (context, i) => rows[i],
                onToggle: (id) => setState(() {
                  if (!_expanded.add(id as String)) _expanded.remove(id);
                }),
                onSelect: (id) => setState(() => _selected = id as String),
                onActivate: (id) => setState(() => _active = id as String),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
