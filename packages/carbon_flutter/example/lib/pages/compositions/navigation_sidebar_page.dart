import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../../gallery_scaffold.dart';

/// A navigation rail with links, a header row, two expandable menus with
/// nested items, trailing status tags and per-row actions.
class NavigationSidebarComposition extends StatefulWidget {
  const NavigationSidebarComposition({super.key});

  @override
  State<NavigationSidebarComposition> createState() =>
      _NavigationSidebarCompositionState();
}

class _NavigationSidebarCompositionState
    extends State<NavigationSidebarComposition> {
  String _current = 'overview';
  bool _projectsOpen = true;
  bool _teamsOpen = false;
  String _lastAction = 'none';

  Widget _actions(String name) => CarbonOverflowMenu(
    key: ValueKey('nav-menu-$name'),
    semanticLabel: 'Actions for $name',
    entries: [
      CarbonMenuItem(
        label: 'Rename',
        onPressed: () => setState(() => _lastAction = 'Renamed $name'),
      ),
      CarbonMenuItem(
        label: 'Archive',
        onPressed: () => setState(() => _lastAction = 'Archived $name'),
      ),
    ],
  );

  Widget _item(String id, String label, {String? tag}) {
    return CarbonSideNavLink(
      key: ValueKey('nav-$id'),
      label: label,
      icon: CarbonIcons.folder,
      current: _current == id,
      onPressed: () => setState(() => _current = id),
      trailing: [if (tag != null) CarbonTag(label: tag)],
      actions: [_actions(label)],
    );
  }

  Widget _link(String id, String label, CarbonIcons icon) {
    return CarbonSideNavLink(
      key: ValueKey('nav-$id'),
      label: label,
      icon: icon,
      current: _current == id,
      onPressed: () => setState(() => _current = id),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    return GalleryPage(
      title: 'Navigation sidebar',
      summary:
          'Links, a divider, a header row and two expandable menus. Status '
          'tags give way to row actions on hover or focus.',
      children: [
        SizedBox(
          width: 288,
          child: CarbonSideNav(
            endBorder: true,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _link('overview', 'Overview', CarbonIcons.star),
                _link('account', 'Account', CarbonIcons.user),
                _link('settings', 'Settings', CarbonIcons.settings),
                const CarbonSideNavDivider(),
                const CarbonSideNavLink(label: 'Workspaces', large: true),
                CarbonSideNavMenu(
                  key: const ValueKey('nav-projects'),
                  title: 'Projects',
                  icon: CarbonIcons.folder,
                  expanded: _projectsOpen,
                  onExpandedChanged: (value) =>
                      setState(() => _projectsOpen = value),
                  children: [
                    _item('docs', 'Docs site', tag: 'Running'),
                    _item('mobile', 'Mobile app'),
                  ],
                ),
                CarbonSideNavMenu(
                  key: const ValueKey('nav-teams'),
                  title: 'Teams',
                  icon: CarbonIcons.user,
                  expanded: _teamsOpen,
                  onExpandedChanged: (value) =>
                      setState(() => _teamsOpen = value),
                  children: [
                    _item('platform', 'Platform', tag: 'Idle'),
                    _item('design', 'Design'),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: CarbonSpacing.spacing05),
        Text(
          'Current: $_current. Last action: $_lastAction.',
          key: const ValueKey('nav-status'),
          style: theme.typography.body.copyWith(
            color: theme.colors.textSecondary,
          ),
        ),
      ],
    );
  }
}
