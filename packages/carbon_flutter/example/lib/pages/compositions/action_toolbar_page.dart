import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../../gallery_scaffold.dart';

/// A toolbar of search, view switcher, buttons, a split button and an
/// overflow menu that absorbs secondary actions on narrow widths.
class ActionToolbarComposition extends StatefulWidget {
  const ActionToolbarComposition({super.key});

  @override
  State<ActionToolbarComposition> createState() =>
      _ActionToolbarCompositionState();
}

class _ActionToolbarCompositionState extends State<ActionToolbarComposition> {
  static const double _compactBelow = 640;

  final TextEditingController _search = TextEditingController();
  String _view = 'list';
  String _last = 'No action yet.';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _did(String what) => setState(() => _last = what);

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    return GalleryPage(
      title: 'Action toolbar',
      summary:
          'Primary actions stay visible; secondary ones move into the overflow '
          'menu when the row runs out of room.',
      children: [
        GallerySection(
          title: 'Session toolbar',
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                final compact = width < _compactBelow;
                final fieldWidth = compact ? width : 280.0;
                final switcherWidth = width < 300 ? width : 280.0;
                return Wrap(
                  spacing: CarbonSpacing.spacing03,
                  runSpacing: CarbonSpacing.spacing03,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(
                      width: fieldWidth,
                      child: CarbonSearch(
                        key: const ValueKey('toolbar-search'),
                        controller: _search,
                        placeholder: 'Search sessions, branches and files',
                        onChanged: (v) => _did('Searching for "$v".'),
                      ),
                    ),
                    SizedBox(
                      width: switcherWidth,
                      child: CarbonContentSwitcher<String>(
                        semanticLabel: 'Session layout',
                        expand: true,
                        value: _view,
                        options: const [
                          CarbonOption(value: 'list', label: 'List'),
                          CarbonOption(value: 'grid', label: 'Grid'),
                          CarbonOption(value: 'board', label: 'Board'),
                        ],
                        onChanged: (v) {
                          setState(() => _view = v);
                          _did('Switched to the $v layout.');
                        },
                      ),
                    ),
                    if (!compact) ...[
                      CarbonButton(
                        label: 'Filter',
                        kind: CarbonButtonKind.ghost,
                        icon: const CarbonIcon(CarbonIcons.filter),
                        onPressed: () => _did('Opened filters.'),
                      ),
                      CarbonButton(
                        label: 'Export selected sessions as CSV',
                        kind: CarbonButtonKind.tertiary,
                        onPressed: () => _did('Exported sessions.'),
                      ),
                    ],
                    CarbonSplitButton(
                      label: 'New session',
                      onPressed: () => _did('Created a session.'),
                      entries: [
                        CarbonMenuItem(
                          label: 'New isolated session from a branch',
                          onPressed: () => _did('Created an isolated session.'),
                        ),
                        CarbonMenuItem(
                          label: 'Resume the last session',
                          onPressed: () => _did('Resumed the last session.'),
                        ),
                      ],
                    ),
                    CarbonOverflowMenu(
                      key: const ValueKey('toolbar-overflow'),
                      semanticLabel: 'More toolbar actions',
                      entries: [
                        if (compact) ...[
                          CarbonMenuItem(
                            label: 'Filter',
                            icon: const CarbonIcon(CarbonIcons.filter),
                            onPressed: () => _did('Opened filters.'),
                          ),
                          CarbonMenuItem(
                            label: 'Export selected sessions as CSV',
                            onPressed: () => _did('Exported sessions.'),
                          ),
                          const CarbonMenuDivider(),
                        ],
                        CarbonMenuItem(
                          label: 'Archive finished sessions',
                          onPressed: () => _did('Archived finished sessions.'),
                        ),
                        CarbonMenuItem(
                          label: 'Delete all archived sessions',
                          kind: CarbonMenuItemKind.danger,
                          onPressed: () => _did('Deleted archived sessions.'),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
            Semantics(
              liveRegion: true,
              child: Text(
                _last,
                key: const ValueKey('toolbar-last'),
                style: theme.typography.helper.copyWith(
                  color: theme.colors.textSecondary,
                ),
              ),
            ),
          ],
        ),
        const GalleryNote(
          useWhen:
              'A row of related commands above a collection, where some '
              'commands matter less than others.',
          keyboard:
              'Tab visits each control; arrow keys move inside the switcher '
              'and menus; Escape closes a menu and returns focus to its '
              'trigger.',
          accessibility:
              'The icon-only overflow trigger carries a label; the last '
              'action is announced through a live region.',
          carbonReference:
              'Carbon Search, Content switcher, Menu button, Overflow menu, '
              'Button.',
        ),
      ],
    );
  }
}
