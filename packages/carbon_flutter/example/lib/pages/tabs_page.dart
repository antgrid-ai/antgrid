import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../gallery_scaffold.dart';

const List<CarbonOption<String>> _basic = <CarbonOption<String>>[
  CarbonOption(value: 'terminal', label: 'Terminal'),
  CarbonOption(value: 'files', label: 'Files'),
  CarbonOption(value: 'git', label: 'Git'),
];

const List<CarbonOption<String>> _withIcons = <CarbonOption<String>>[
  CarbonOption(
    value: 'search',
    label: 'Search',
    icon: CarbonIcon(CarbonIcons.search),
  ),
  CarbonOption(
    value: 'settings',
    label: 'Settings',
    icon: CarbonIcon(CarbonIcons.settings),
  ),
  CarbonOption(
    value: 'review',
    label: 'Review',
    icon: CarbonIcon(CarbonIcons.view),
  ),
];

const List<CarbonOption<String>> _withDisabled = <CarbonOption<String>>[
  CarbonOption(value: 'a', label: 'Overview'),
  CarbonOption(value: 'b', label: 'Deploys', enabled: false),
  CarbonOption(value: 'c', label: 'Logs'),
  CarbonOption(value: 'd', label: 'Archive', enabled: false),
];

const List<CarbonOption<String>> _longLabels = <CarbonOption<String>>[
  CarbonOption(
    value: 'a',
    label: 'Pending review comments from the last agent run',
  ),
  CarbonOption(value: 'b', label: 'Resolved'),
];

final List<CarbonOption<String>> _many = <CarbonOption<String>>[
  for (var i = 1; i <= 14; i++)
    CarbonOption(value: 'session$i', label: 'Session $i'),
];

/// Gallery page for [CarbonTabs] and [CarbonTabPanels].
class TabsPage extends StatelessWidget {
  const TabsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return GalleryPage(
      title: 'Tabs',
      summary:
          'A single row of tabs with a roving tab stop. Only the list is '
          'provided; CarbonTabPanels composes content so hidden panes keep '
          'their state without animating or taking focus.',
      children: [
        const GallerySection(
          title: 'Line with panels',
          description:
              'Automatic activation: arrow keys move and select. The counter '
              'and spinner live in panes that stay mounted when hidden.',
          children: [_PanelsDemo()],
        ),
        const GallerySection(
          title: 'Variants',
          children: [
            _Labelled('Line', _Demo(variant: CarbonTabsVariant.line)),
            _Labelled('Contained', _Demo(variant: CarbonTabsVariant.contained)),
          ],
        ),
        const GallerySection(
          title: 'Activation',
          description:
              'Manual activation moves focus with the arrows and selects with '
              'Enter or Space. Use it when selecting loads content.',
          children: [
            _Labelled(
              'Manual',
              _Demo(activation: CarbonActivationMode.manual),
            ),
          ],
        ),
        const GallerySection(
          title: 'Icons and disabled tabs',
          description: 'Disabled tabs are skipped by the arrow keys.',
          children: [
            _Labelled('With icons', _Demo(tabs: _withIcons)),
            _Labelled('Disabled', _Demo(tabs: _withDisabled)),
            _Labelled(
              'Contained, disabled',
              _Demo(
                tabs: _withDisabled,
                variant: CarbonTabsVariant.contained,
              ),
            ),
            _Labelled(
              'Selected and disabled',
              _Demo(tabs: _withDisabled, initial: 'b'),
            ),
            _Labelled(
              'Contained, selected and disabled',
              _Demo(
                tabs: _withDisabled,
                initial: 'b',
                variant: CarbonTabsVariant.contained,
              ),
            ),
          ],
        ),
        GallerySection(
          title: 'Overflow',
          description:
              'Tabs that do not fit scroll, with buttons at the ends. The '
              'focused tab is kept in view.',
          children: [
            _Labelled('Line', _Demo(tabs: _many, initial: 'session9')),
            _Labelled(
              'Contained',
              _Demo(
                tabs: _many,
                initial: 'session2',
                variant: CarbonTabsVariant.contained,
              ),
            ),
          ],
        ),
        const GallerySection(
          title: 'Long labels',
          description: 'A label wider than the list wraps inside its tab.',
          children: [_Demo(tabs: _longLabels)],
        ),
        const GalleryNote(
          useWhen:
              'Switching between peer views of one subject that the user '
              'moves between often, such as terminal, files and git.',
          keyboard:
              'Tab enters the list once, on the selected tab. Left/Right move '
              '(mirrored in RTL) and wrap; Home/End jump. Automatic mode '
              'selects as focus moves; manual mode selects on Enter/Space.',
          accessibility:
              'Exposed as a tab bar of tabs with selected state; disabled '
              'tabs are announced as unavailable. The scroll buttons are '
              'labelled but are not tab stops.',
          carbonReference: 'Tabs: line and contained variants.',
        ),
      ],
    );
  }
}

class _Labelled extends StatelessWidget {
  const _Labelled(this.label, this.child);

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          label,
          style: theme.typography.label.copyWith(
            color: theme.colors.textSecondary,
          ),
        ),
        const SizedBox(height: CarbonSpacing.spacing02),
        child,
      ],
    );
  }
}

class _Demo extends StatefulWidget {
  const _Demo({
    this.tabs = _basic,
    this.initial,
    this.variant = CarbonTabsVariant.line,
    this.activation = CarbonActivationMode.automatic,
  });

  final List<CarbonOption<String>> tabs;
  final String? initial;
  final CarbonTabsVariant variant;
  final CarbonActivationMode activation;

  @override
  State<_Demo> createState() => _DemoState();
}

class _DemoState extends State<_Demo> {
  late String _value = widget.initial ?? widget.tabs.first.value;

  @override
  Widget build(BuildContext context) {
    return CarbonTabs<String>(
      tabs: widget.tabs,
      value: _value,
      variant: widget.variant,
      activation: widget.activation,
      onChanged: (v) => setState(() => _value = v),
    );
  }
}

class _PanelsDemo extends StatefulWidget {
  const _PanelsDemo();

  @override
  State<_PanelsDemo> createState() => _PanelsDemoState();
}

class _PanelsDemoState extends State<_PanelsDemo> {
  String _value = 'terminal';

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CarbonTabs<String>(
          tabs: _basic,
          value: _value,
          variant: CarbonTabsVariant.contained,
          onChanged: (v) => setState(() => _value = v),
        ),
        CarbonLayerSurface(
          padding: const EdgeInsets.all(CarbonSpacing.spacing05),
          child: CarbonTabPanels<String>(
            value: _value,
            panels: const [
              CarbonTabPanel(value: 'terminal', child: _CounterPane()),
              CarbonTabPanel(
                value: 'files',
                child: Row(
                  children: [
                    CarbonSpinner(),
                    SizedBox(width: CarbonSpacing.spacing03),
                    Flexible(child: _PaneText('Indexing files')),
                  ],
                ),
              ),
              CarbonTabPanel(value: 'git', child: _PaneText('No changes.')),
            ],
          ),
        ),
      ],
    );
  }
}

class _PaneText extends StatelessWidget {
  const _PaneText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: CarbonTheme.of(context).typography.body);
}

class _CounterPane extends StatefulWidget {
  const _CounterPane();

  @override
  State<_CounterPane> createState() => _CounterPaneState();
}

class _CounterPaneState extends State<_CounterPane> {
  int _count = 0;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        CarbonButton(
          label: 'Count',
          kind: CarbonButtonKind.tertiary,
          onPressed: () => setState(() => _count++),
        ),
        const SizedBox(width: CarbonSpacing.spacing04),
        Flexible(child: _PaneText('Pressed $_count times; kept when hidden')),
      ],
    );
  }
}
