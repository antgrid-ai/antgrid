import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../gallery_scaffold.dart';

/// Gallery page for [CarbonSideNav] and its rows.
class SideNavPage extends StatefulWidget {
  const SideNavPage({super.key});

  @override
  State<SideNavPage> createState() => _SideNavPageState();
}

class _SideNavPageState extends State<SideNavPage> {
  String _current = 'overview';
  bool _expanded = true;
  bool _swapChevron = false;

  Widget _frame(Widget nav) => SizedBox(width: 288, child: nav);

  @override
  Widget build(BuildContext context) {
    return GalleryPage(
      title: 'Side nav',
      summary:
          'A vertical navigation rail of links, expandable menus and '
          'dividers. The host owns which link is current and which menu is '
          'open; rows can carry status marks and per-row actions.',
      children: [
        GallerySection(
          title: 'Links',
          description:
              'The current link shows a selected fill and a start bar and is '
              'announced as selected. Disabled links ignore input.',
          children: [
            _frame(
              CarbonSideNav(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final entry in const {
                      'overview': ('Overview', CarbonIcons.star),
                      'sessions': ('Sessions', CarbonIcons.folder),
                      'account': ('Account', CarbonIcons.user),
                    }.entries)
                      CarbonSideNavLink(
                        label: entry.value.$1,
                        icon: entry.value.$2,
                        current: _current == entry.key,
                        onPressed: () => setState(() => _current = entry.key),
                      ),
                    const CarbonSideNavDivider(),
                    const CarbonSideNavLink(
                      label: 'Archived',
                      icon: CarbonIcons.folder,
                      disabled: true,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        GallerySection(
          title: 'Expandable menu',
          description:
              'Expansion is host-owned. The swapping chevron appears in the '
              'icon slot only under pointer hover.',
          children: [
            CarbonToggle(
              labelText: 'Chevron swaps the icon on hover',
              value: _swapChevron,
              onChanged: (value) => setState(() => _swapChevron = value),
            ),
            const SizedBox(height: CarbonSpacing.spacing04),
            _frame(
              CarbonSideNav(
                child: CarbonSideNavMenu(
                  title: 'Projects',
                  icon: CarbonIcons.folder,
                  expanded: _expanded,
                  onExpandedChanged: (value) =>
                      setState(() => _expanded = value),
                  chevron: _swapChevron
                      ? CarbonSideNavChevron.swapsIcon
                      : CarbonSideNavChevron.end,
                  children: [
                    CarbonSideNavLink(
                      label: 'Docs site',
                      icon: CarbonIcons.folder,
                      onPressed: () {},
                    ),
                    CarbonSideNavLink(
                      label: 'Mobile app',
                      icon: CarbonIcons.folder,
                      onPressed: () {},
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        GallerySection(
          title: 'Trailing marks and actions',
          description:
              'Swap mode shows the actions in place of the marks on hover or '
              'focus; reserved mode keeps a slot for each.',
          children: [
            for (final mode in CarbonSideNavActions.values) ...[
              _frame(
                CarbonSideNav(
                  child: CarbonSideNavLink(
                    label: 'Nightly build (${mode.name})',
                    icon: CarbonIcons.play,
                    actionsMode: mode,
                    onPressed: () {},
                    trailing: const [CarbonTag(label: 'Running')],
                    actions: [
                      CarbonOverflowMenu(
                        semanticLabel: 'Actions for nightly build',
                        entries: [
                          CarbonMenuItem(label: 'Rename', onPressed: () {}),
                          CarbonMenuItem(label: 'Delete', onPressed: () {}),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: CarbonSpacing.spacing04),
            ],
          ],
        ),
        GallerySection(
          title: 'Large rows and edge',
          children: [
            _frame(
              const CarbonSideNav(
                endBorder: true,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CarbonSideNavLink(
                      label: 'Large link',
                      icon: CarbonIcons.settings,
                      large: true,
                      current: true,
                    ),
                    CarbonSideNavLink(
                      label: 'Large link',
                      icon: CarbonIcons.settings,
                      large: true,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
