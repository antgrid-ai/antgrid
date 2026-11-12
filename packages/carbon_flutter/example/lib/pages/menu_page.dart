import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../gallery_scaffold.dart';

const String _longLabel =
    'Export the selected range as a standalone report with every attachment';

class MenuPage extends StatelessWidget {
  const MenuPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const GalleryPage(
      title: 'Menu',
      summary:
          'A collection of commands in an anchored popup: actions, checked '
          'settings, groups and submenus. A menu runs commands; to choose a '
          'form value use Select or Dropdown.',
      children: [
        GallerySection(
          title: 'Actions',
          description:
              'Icons, shortcut hints, a disabled item and a danger item that '
              'reads as an ordinary row until hover or focus fills it with the '
              'danger role.',
          children: [_ActionsDemo()],
        ),
        GallerySection(
          title: 'Checked settings',
          description:
              'The host owns the values. The menu stays open while toggling '
              'so several settings can change in one visit.',
          children: [_CheckedDemo()],
        ),
        GallerySection(
          title: 'Submenus',
          description:
              'Open by tap, Enter or the forward arrow; no hover is needed. '
              'Escape or the back arrow returns to the parent item.',
          children: [_SubmenuDemo()],
        ),
        GallerySection(
          title: 'Context menu',
          description:
              'Right-click or long-press the area to open at the pointer; with '
              'focus inside it, the Menu key or Shift+F10 opens beside the '
              'focused widget.',
          children: [_ContextDemo()],
        ),
        GallerySection(
          title: 'Long labels',
          description: 'Rows wrap and grow; they never clip.',
          children: [_LongDemo()],
        ),
        GallerySection(
          title: 'Menu or Select',
          description:
              'Choose Menu when each row runs a command or flips a setting '
              'and the control keeps no value of its own. Choose Select or '
              'Dropdown when the rows are the options of a form field whose '
              'chosen value the control shows.',
          children: [],
        ),
        GallerySection(
          title: 'Deviations from Carbon',
          description:
              'Submenus open by tap or key, never by hovering. Checkable '
              'items close the menu unless closeOnToggle is false. A submenu '
              'without room on its trailing side opens on the leading side '
              'by comparing the space on each side with the parent row width, '
              'not by measuring the submenu. The menu panel is a single '
              'non-lazy column, so very long lists belong in a Select or '
              'a searchable list instead.',
          children: [],
        ),
        GalleryNote(
          useWhen:
              'Commands on an object or in a toolbar, and settings that are '
              'toggled in place. Not for picking a field value.',
          keyboard:
              'Up/Down move with wrap and skip disabled items; Home/End jump; '
              'Enter or Space activate; Right (Left in RTL) opens a submenu; '
              'Left (Right in RTL) or Escape closes it; Escape on the root '
              'restores focus to the trigger; Tab closes the menu and moves '
              'on from the trigger; letters jump, and repeating a letter '
              'cycles through its matches.',
          accessibility:
              'Menu with menu items, checked and radio items, an expanded '
              'state on submenu items and a 32 / 48 minimum row height.',
          carbonReference:
              'Carbon Menu and Menu button (react Menu, MenuItem; '
              'carbondesignsystem.com/components/menu/usage)',
        ),
      ],
    );
  }
}

typedef _DemoBuilder =
    Widget Function(
      BuildContext context,
      CarbonPopupController controller,
      FocusNode trigger,
      ValueChanged<String> report,
    );

class _Demo extends StatefulWidget {
  const _Demo({required this.builder});

  final _DemoBuilder builder;

  @override
  State<_Demo> createState() => _DemoState();
}

class _DemoState extends State<_Demo> {
  final CarbonPopupController _controller = CarbonPopupController();
  final FocusNode _trigger = FocusNode();
  String _last = 'Nothing chosen yet';

  @override
  void dispose() {
    _controller.dispose();
    _trigger.dispose();
    super.dispose();
  }

  void _report(String value) => setState(() => _last = value);

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        widget.builder(context, _controller, _trigger, _report),
        const SizedBox(height: CarbonSpacing.spacing03),
        Text(
          _last,
          style: theme.typography.helper.copyWith(
            color: theme.colors.textSecondary,
          ),
        ),
      ],
    );
  }
}

Widget _trigger(
  CarbonPopupController controller,
  FocusNode node, {
  String label = 'Open menu',
}) => CarbonButton(
  label: label,
  kind: CarbonButtonKind.tertiary,
  focusNode: node,
  onPressed: controller.toggle,
);

class _ActionsDemo extends StatelessWidget {
  const _ActionsDemo();

  @override
  Widget build(BuildContext context) {
    return _Demo(
      builder: (context, controller, node, report) => CarbonMenu(
        controller: controller,
        restoreFocus: node,
        entries: [
          CarbonMenuItem(
            label: 'Rename',
            icon: const CarbonIcon(CarbonIcons.edit),
            shortcut: 'F2',
            onPressed: () => report('Rename'),
          ),
          CarbonMenuItem(
            label: 'Copy',
            icon: const CarbonIcon(CarbonIcons.copy),
            shortcut: 'Ctrl+C',
            onPressed: () => report('Copy'),
          ),
          const CarbonMenuItem(
            label: 'Share (unavailable)',
            icon: CarbonIcon(CarbonIcons.view),
          ),
          const CarbonMenuDivider(),
          CarbonMenuItem(
            label: 'Remove',
            icon: const CarbonIcon(CarbonIcons.trashCan),
            kind: CarbonMenuItemKind.danger,
            onPressed: () => report('Remove'),
          ),
        ],
        child: _trigger(controller, node),
      ),
    );
  }
}

class _CheckedDemo extends StatefulWidget {
  const _CheckedDemo();

  @override
  State<_CheckedDemo> createState() => _CheckedDemoState();
}

class _CheckedDemoState extends State<_CheckedDemo> {
  bool _wrap = true;
  bool _minimap = false;
  String _mode = 'dark';

  @override
  Widget build(BuildContext context) {
    return _Demo(
      builder: (context, controller, node, report) => CarbonMenu(
        controller: controller,
        restoreFocus: node,
        closeOnToggle: false,
        entries: [
          CarbonMenuGroup(
            label: 'Editor',
            children: [
              CarbonMenuCheckItem(
                label: 'Word wrap',
                checked: _wrap,
                onChanged: (v) {
                  setState(() => _wrap = v);
                  report('Word wrap: $v');
                },
              ),
              CarbonMenuCheckItem(
                label: 'Minimap',
                checked: _minimap,
                onChanged: (v) {
                  setState(() => _minimap = v);
                  report('Minimap: $v');
                },
              ),
              const CarbonMenuCheckItem(label: 'Locked setting', checked: true),
            ],
          ),
          const CarbonMenuDivider(),
          CarbonMenuRadioGroup<String>(
            label: 'Color mode',
            value: _mode,
            options: const [
              CarbonOption(
                value: 'light',
                label: 'Light',
                description: 'Default',
              ),
              CarbonOption(value: 'dark', label: 'Dark'),
              CarbonOption(
                value: 'auto',
                label: 'Match system',
                enabled: false,
              ),
            ],
            onChanged: (v) {
              setState(() => _mode = v);
              report('Color mode: $v');
            },
          ),
        ],
        child: _trigger(controller, node, label: 'Settings'),
      ),
    );
  }
}

class _SubmenuDemo extends StatelessWidget {
  const _SubmenuDemo();

  @override
  Widget build(BuildContext context) {
    return _Demo(
      builder: (context, controller, node, report) => CarbonMenu(
        controller: controller,
        restoreFocus: node,
        entries: [
          CarbonMenuItem(
            label: 'New file',
            onPressed: () => report('New file'),
          ),
          CarbonMenuSubmenu(
            label: 'Open recent',
            entries: [
              CarbonMenuItem(
                label: 'notes.md',
                onPressed: () => report('notes.md'),
              ),
              CarbonMenuItem(
                label: 'plan.md',
                onPressed: () => report('plan.md'),
              ),
              CarbonMenuSubmenu(
                label: 'Older',
                entries: [
                  CarbonMenuItem(
                    label: 'archive.md',
                    onPressed: () => report('archive.md'),
                  ),
                ],
              ),
            ],
          ),
          const CarbonMenuSubmenu(
            label: 'Disabled submenu',
            enabled: false,
            entries: [],
          ),
        ],
        child: _trigger(controller, node, label: 'File'),
      ),
    );
  }
}

class _ContextDemo extends StatelessWidget {
  const _ContextDemo();

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    return CarbonContextMenu(
      entries: [
        CarbonMenuItem(label: 'Rename', onPressed: () {}),
        CarbonMenuItem(
          label: 'Remove',
          kind: CarbonMenuItemKind.danger,
          onPressed: () {},
        ),
      ],
      child: CarbonLayerSurface(
        border: true,
        padding: const EdgeInsets.all(CarbonSpacing.spacing06),
        child: Text(
          'Right-click or long-press here',
          style: theme.typography.body,
        ),
      ),
    );
  }
}

class _LongDemo extends StatelessWidget {
  const _LongDemo();

  @override
  Widget build(BuildContext context) {
    return _Demo(
      builder: (context, controller, node, report) => CarbonMenu(
        controller: controller,
        restoreFocus: node,
        entries: [
          CarbonMenuItem(
            label: _longLabel,
            shortcut: 'Ctrl+Shift+E',
            onPressed: () => report('Export'),
          ),
          CarbonMenuItem(label: 'Short', onPressed: () => report('Short')),
        ],
        child: _trigger(controller, node, label: 'Long labels'),
      ),
    );
  }
}
