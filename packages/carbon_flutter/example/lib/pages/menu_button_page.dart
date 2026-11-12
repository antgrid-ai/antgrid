import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../gallery_scaffold.dart';

List<CarbonMenuEntry> _entries(ValueChanged<String> report) => [
  CarbonMenuItem(label: 'Rename', onPressed: () => report('Rename')),
  CarbonMenuItem(label: 'Duplicate', onPressed: () => report('Duplicate')),
  const CarbonMenuItem(label: 'Archive (unavailable)'),
  const CarbonMenuDivider(),
  CarbonMenuItem(
    label: 'Remove',
    kind: CarbonMenuItemKind.danger,
    onPressed: () => report('Remove'),
  ),
];

class MenuButtonPage extends StatefulWidget {
  const MenuButtonPage({super.key});

  @override
  State<MenuButtonPage> createState() => _MenuButtonPageState();
}

class _MenuButtonPageState extends State<MenuButtonPage> {
  String _last = 'Nothing chosen yet';

  void _report(String value) => setState(() => _last = value);

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    return GalleryPage(
      title: 'Menu button',
      summary:
          'The control that opens a menu: a labelled button, an overflow '
          'trigger, or a split button with its own primary action. It runs '
          'commands; it is not a form field.',
      children: [
        GallerySection(
          title: 'Menu button',
          description:
              'Primary, tertiary and ghost. The chevron flips while open and '
              'the trigger announces its expanded state.',
          children: [
            GalleryStateGrid(
              cells: [
                for (final kind in const [
                  CarbonButtonKind.primary,
                  CarbonButtonKind.tertiary,
                  CarbonButtonKind.ghost,
                ])
                  GalleryStateCell(
                    kind.name,
                    CarbonMenuButton(
                      label: 'Actions',
                      kind: kind,
                      entries: _entries(_report),
                    ),
                  ),
                GalleryStateCell(
                  'disabled',
                  CarbonMenuButton(
                    label: 'Actions',
                    enabled: false,
                    entries: _entries(_report),
                  ),
                ),
                GalleryStateCell(
                  'long label',
                  CarbonMenuButton(
                    label: 'Manage every connected workspace and its members',
                    kind: CarbonButtonKind.tertiary,
                    entries: _entries(_report),
                  ),
                ),
              ],
            ),
          ],
        ),
        GallerySection(
          title: 'Overflow menu',
          description:
              'An icon-only trigger for secondary commands, 32 compact and '
              '48 touch. A danger item is the usual place for Remove.',
          children: [
            GalleryStateGrid(
              cells: [
                GalleryStateCell(
                  'vertical',
                  CarbonOverflowMenu(entries: _entries(_report)),
                ),
                GalleryStateCell(
                  'horizontal',
                  CarbonOverflowMenu(
                    horizontal: true,
                    entries: _entries(_report),
                  ),
                ),
                GalleryStateCell(
                  'disabled',
                  CarbonOverflowMenu(
                    enabled: false,
                    entries: _entries(_report),
                  ),
                ),
                GalleryStateCell(
                  'in a row',
                  SizedBox(
                    width: 240,
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'my-project-with-a-long-name',
                            style: theme.typography.body,
                          ),
                        ),
                        CarbonOverflowMenu(
                          semanticLabel: 'my-project-with-a-long-name options',
                          entries: [
                            CarbonMenuItem(
                              label: 'Forget',
                              kind: CarbonMenuItemKind.danger,
                              onPressed: () => _report('Forget'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        GallerySection(
          title: 'Split button',
          description:
              'The action and the menu trigger are separate controls, each '
              'focusable on its own; activating one never activates the other.',
          children: [
            GalleryStateGrid(
              cells: [
                GalleryStateCell(
                  'primary',
                  CarbonSplitButton(
                    label: 'Run',
                    onPressed: () => _report('Run'),
                    entries: _entries(_report),
                  ),
                ),
                GalleryStateCell(
                  'tertiary',
                  CarbonSplitButton(
                    label: 'Run',
                    kind: CarbonButtonKind.tertiary,
                    onPressed: () => _report('Run'),
                    entries: _entries(_report),
                  ),
                ),
                GalleryStateCell(
                  'action disabled',
                  CarbonSplitButton(
                    label: 'Run',
                    onPressed: null,
                    entries: _entries(_report),
                  ),
                ),
                GalleryStateCell(
                  'menu disabled',
                  CarbonSplitButton(
                    label: 'Run',
                    onPressed: () => _report('Run'),
                    menuEnabled: false,
                    entries: _entries(_report),
                  ),
                ),
                GalleryStateCell(
                  'long label',
                  CarbonSplitButton(
                    label: 'Run the whole workspace test suite',
                    onPressed: () => _report('Run all'),
                    entries: _entries(_report),
                  ),
                ),
              ],
            ),
          ],
        ),
        Text(
          _last,
          style: theme.typography.helper.copyWith(
            color: theme.colors.textSecondary,
          ),
        ),
        const SizedBox(height: CarbonSpacing.spacing06),
        const GallerySection(
          title: 'Which control',
          description:
              'Menu button when a labelled control opens several commands. '
              'Overflow menu when the commands are secondary and the space '
              'only fits an icon. Split button when one action is the common '
              'case and the rest are alternatives. None of them holds a '
              'value: use Select or Dropdown to choose one.',
          children: [],
        ),
        const GallerySection(
          title: 'Deviations from Carbon',
          description:
              'The open menu is at least 160 and at most 320 wide rather '
              'than as wide as the trigger. Pressing the split button action '
              'while its menu is open dismisses the menu. Disabling a '
              'trigger closes its open menu.',
          children: [],
        ),
        const GalleryNote(
          useWhen:
              'A small set of related commands behind one control. Use '
              'Select or Dropdown to choose a value, and a split button when '
              'one action is the common case.',
          keyboard:
              'Enter or Space opens; focus moves to the first item. Escape '
              'closes and returns focus to the trigger. In a split button Tab '
              'moves between the action and the menu trigger.',
          accessibility:
              'The trigger is a button with an expanded state. The overflow '
              'trigger is named "Options" and the split trigger "Open menu" '
              'unless overridden; both targets are at least 32 compact and 48 '
              'touch.',
          carbonReference:
              'Carbon Menu buttons (carbondesignsystem.com/components/menu-buttons/usage)',
        ),
      ],
    );
  }
}
