import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../gallery_scaffold.dart';

/// Gallery page for [CarbonContainedList].
class ContainedListPage extends StatefulWidget {
  const ContainedListPage({super.key});

  @override
  State<ContainedListPage> createState() => _ContainedListPageState();
}

class _ContainedListPageState extends State<ContainedListPage> {
  final Set<String> _selected = <String>{'src'};
  String _single = 'b';
  String _lastAction = 'none';

  CarbonButton _deleteAction(String name) => CarbonButton.iconOnly(
    icon: const CarbonIcon(CarbonIcons.trashCan),
    semanticLabel: 'Delete $name',
    onPressed: () => setState(() => _lastAction = 'delete $name'),
  );

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    return GalleryPage(
      title: 'Contained list',
      summary:
          'Grouped rows under a header. A row and its trailing actions are '
          'separate targets, rows grow with text, and the host supplies '
          'loading, error and empty content.',
      children: [
        GallerySection(
          title: 'On page',
          description:
              'Row activation and trailing actions are independent. Last '
              'trailing action: $_lastAction.',
          children: [
            CarbonContainedList(
              label: 'Recent sessions',
              action: CarbonButton(
                label: 'New',
                kind: CarbonButtonKind.ghost,
                size: CarbonButtonSize.small,
                icon: const CarbonIcon(CarbonIcons.add),
                onPressed: () => setState(() => _lastAction = 'new'),
              ),
              children: [
                CarbonContainedListRow(
                  title: 'Fix the flaky terminal resize test',
                  secondary: 'Claude Code, 12 minutes ago',
                  leading: const CarbonIcon(CarbonIcons.checkmarkOutline),
                  onPressed: () => setState(() => _lastAction = 'open fix'),
                  actions: [_deleteAction('fix')],
                ),
                CarbonContainedListRow(
                  title: 'Review pending migration',
                  secondary:
                      'A long second line that keeps going so that it wraps '
                      'onto further lines when the row is narrow or the text '
                      'is scaled up.',
                  leading: const CarbonIcon(CarbonIcons.warning),
                  onPressed: () => setState(() => _lastAction = 'open review'),
                  actions: [
                    _deleteAction('review'),
                    CarbonButton.iconOnly(
                      icon: const CarbonIcon(CarbonIcons.overflowMenuHorizontal),
                      semanticLabel: 'More for review',
                      onPressed: () => setState(() => _lastAction = 'more'),
                    ),
                  ],
                ),
                const CarbonContainedListRow(
                  title: 'Static row without activation',
                  secondary: 'Not focusable, not a button',
                ),
                CarbonContainedListRow(
                  title: 'Disabled trailing action',
                  onPressed: () => setState(() => _lastAction = 'open static'),
                  actions: const [
                    CarbonButton.iconOnly(
                      icon: CarbonIcon(CarbonIcons.trashCan),
                      semanticLabel: 'Delete unavailable',
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
        GallerySection(
          title: 'Selection',
          description:
              'Multi-select toggles with onSelectedChanged; the single-select '
              'list styles the host-managed selection.',
          children: [
            CarbonContainedList(
              label: 'Folders (multi-select)',
              inset: true,
              children: [
                for (final name in const ['src', 'test', 'docs'])
                  CarbonContainedListRow(
                    title: name,
                    selected: _selected.contains(name),
                    onSelectedChanged: (on) => setState(
                      () => on ? _selected.add(name) : _selected.remove(name),
                    ),
                  ),
              ],
            ),
            CarbonContainedList(
              label: 'Environment (single select)',
              children: [
                for (final name in const ['a', 'b', 'c'])
                  CarbonContainedListRow(
                    title: 'Environment $name',
                    selected: _single == name,
                    onPressed: () => setState(() => _single = name),
                  ),
              ],
            ),
          ],
        ),
        GallerySection(
          title: 'Hover-revealed actions',
          description:
              'In compact density actions appear on hover or keyboard focus; '
              'in touch density they are always visible.',
          children: [
            CarbonContainedList(
              label: 'Branches',
              children: [
                for (final name in const ['main', 'development', 'fix/resize'])
                  CarbonContainedListRow(
                    title: name,
                    onPressed: () {},
                    revealActionsOnHover: true,
                    actions: [_deleteAction(name)],
                  ),
              ],
            ),
          ],
        ),
        GallerySection(
          title: 'Disclosed',
          description:
              'Unfilled, so it takes the surface of the panel it sits in.',
          children: [
            CarbonLayerSurface(
              padding: const EdgeInsets.all(CarbonSpacing.spacing05),
              child: CarbonContainedList(
                label: 'In a panel',
                variant: CarbonContainedListVariant.disclosed,
                children: [
                  CarbonContainedListRow(title: 'First', onPressed: () {}),
                  CarbonContainedListRow(title: 'Second', onPressed: () {}),
                ],
              ),
            ),
          ],
        ),
        GallerySection(
          title: 'Loading, error and empty',
          description: 'Slots are host content; each has a localized default.',
          children: [
            const CarbonContainedList(
              label: 'Loading',
              status: CarbonContainedListStatus.loading,
              children: [],
            ),
            CarbonContainedList(
              label: 'Error',
              status: CarbonContainedListStatus.error,
              action: CarbonButton(
                label: 'Retry',
                kind: CarbonButtonKind.ghost,
                size: CarbonButtonSize.small,
                onPressed: () {},
              ),
              errorContent: Text(
                'Could not load the list.',
                style: theme.typography.control.copyWith(
                  color: theme.colors.textError,
                ),
              ),
              children: const [],
            ),
            const CarbonContainedList(
              label: 'Empty',
              emptyContent: Text('Nothing to show yet.'),
              children: [],
            ),
          ],
        ),
        GallerySection(
          title: 'Large list',
          description:
              'CarbonContainedList.builder creates rows lazily; this one has '
              '10,000. CarbonContainedListSliver does the same inside a '
              'CustomScrollView.',
          children: [
            SizedBox(
              height: 240,
              child: CarbonContainedList.builder(
                label: 'Ten thousand rows',
                itemCount: 10000,
                itemBuilder: (context, i) => CarbonContainedListRow(
                  title: 'Row $i',
                  onPressed: () {},
                ),
              ),
            ),
          ],
        ),
        const GalleryNote(
          useWhen:
              'Showing a bounded group of related items with row actions or '
              'selection: sessions, branches, recent files.',
          keyboard:
              'Tab visits a row, then each of its trailing actions in order. '
              'Enter or Space activates the focused target only.',
          accessibility:
              'Selectable rows announce a selected state; actions keep their '
              'own names. Hover-only actions are revealed by keyboard focus '
              'and always shown in touch density.',
          carbonReference: 'Contained list: on-page and disclosed.',
        ),
      ],
    );
  }
}
