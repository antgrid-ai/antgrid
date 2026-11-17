import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../gallery_scaffold.dart';

const List<CarbonOption<String>> _views = <CarbonOption<String>>[
  CarbonOption(value: 'list', label: 'List'),
  CarbonOption(value: 'grid', label: 'Grid'),
  CarbonOption(value: 'map', label: 'Map'),
];

const List<CarbonOption<String>> _withDisabled = <CarbonOption<String>>[
  CarbonOption(value: 'day', label: 'Day'),
  CarbonOption(value: 'week', label: 'Week', enabled: false),
  CarbonOption(value: 'month', label: 'Month'),
];

const List<CarbonOption<String>> _withIcons = <CarbonOption<String>>[
  CarbonOption(
    value: 'list',
    label: 'List',
    icon: CarbonIcon(CarbonIcons.view),
  ),
  CarbonOption(
    value: 'filter',
    label: 'Filter',
    icon: CarbonIcon(CarbonIcons.filter),
  ),
  CarbonOption(
    value: 'settings',
    label: 'Settings',
    icon: CarbonIcon(CarbonIcons.settings),
  ),
];

const List<CarbonOption<String>> _iconOnly = <CarbonOption<String>>[
  CarbonOption(
    value: 'list',
    label: 'List view',
    icon: CarbonIcon(CarbonIcons.view),
  ),
  CarbonOption(
    value: 'filter',
    label: 'Filter view',
    icon: CarbonIcon(CarbonIcons.filter),
  ),
  CarbonOption(
    value: 'settings',
    label: 'Settings view',
    icon: CarbonIcon(CarbonIcons.settings),
  ),
];

const List<CarbonOption<String>> _long = <CarbonOption<String>>[
  CarbonOption(value: 'a', label: 'Terminal output'),
  CarbonOption(value: 'b', label: 'Changed files and diffs'),
  CarbonOption(value: 'c', label: 'Browser preview'),
];

/// Gallery page for [CarbonContentSwitcher].
class ContentSwitcherPage extends StatelessWidget {
  const ContentSwitcherPage({super.key});

  @override
  Widget build(BuildContext context) {
    return GalleryPage(
      title: 'Content switcher',
      summary:
          'A segmented control with exactly one selected option. Segments '
          'share the widest natural width and wrap under large text instead '
          'of clipping.',
      children: [
        const GallerySection(
          title: 'Sizes',
          description:
              'Compact heights are 32, 40 and 48; touch density is 48 for all.',
          children: [
            _Labelled(
              'Small',
              _Demo(size: CarbonContentSwitcherSize.small),
            ),
            _Labelled(
              'Medium',
              _Demo(size: CarbonContentSwitcherSize.medium),
            ),
            _Labelled(
              'Large',
              _Demo(size: CarbonContentSwitcherSize.large),
            ),
            _Labelled('Fills the width', _Demo(expand: true)),
          ],
        ),
        const GallerySection(
          title: 'Content',
          children: [
            _Labelled('Text and icon', _Demo(options: _withIcons)),
            _Labelled(
              'Icon only (labels are the accessible names)',
              _Demo(options: _iconOnly, iconOnly: true),
            ),
            _Labelled('Disabled option', _Demo(options: _withDisabled)),
            _Labelled(
              'Selected and disabled',
              _Demo(options: _withDisabled, initial: 'week'),
            ),
            _Labelled(
              'Long labels wrap',
              _Demo(options: _long, expand: true),
            ),
          ],
        ),
        const GallerySection(
          title: 'Activation',
          description:
              'Manual: arrows move focus only, Enter or Space selects. '
              'Selection (inverse fill) stays distinct from focus (ring).',
          children: [
            _Labelled(
              'Manual',
              _Demo(activation: CarbonActivationMode.manual),
            ),
          ],
        ),
        const GalleryNote(
          useWhen:
              'Choosing between two to five related views of the same data, '
              'where the change is immediate. For navigation between '
              'sections use tabs.',
          keyboard:
              'One tab stop. Left/Right move (mirrored in RTL) and wrap; '
              'Home/End jump; disabled options are skipped. Automatic mode '
              'selects as focus moves.',
          accessibility:
              'A tab bar of tabs with a selected state and one selection '
              'always. Icon-only options announce their label. Selection is '
              'shown by inverse fill and text, never by hover or focus.',
          carbonReference: 'Content switcher.',
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
      crossAxisAlignment: CrossAxisAlignment.start,
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
    this.options = _views,
    this.initial,
    this.size = CarbonContentSwitcherSize.medium,
    this.iconOnly = false,
    this.expand = false,
    this.activation = CarbonActivationMode.automatic,
  });

  final List<CarbonOption<String>> options;
  final String? initial;
  final CarbonContentSwitcherSize size;
  final bool iconOnly;
  final bool expand;
  final CarbonActivationMode activation;

  @override
  State<_Demo> createState() => _DemoState();
}

class _DemoState extends State<_Demo> {
  late String _value = widget.initial ?? widget.options.first.value;

  @override
  Widget build(BuildContext context) {
    final switcher = CarbonContentSwitcher<String>(
      options: widget.options,
      value: _value,
      size: widget.size,
      iconOnly: widget.iconOnly,
      expand: widget.expand,
      activation: widget.activation,
      onChanged: (v) => setState(() => _value = v),
    );
    return widget.expand
        ? SizedBox(width: double.infinity, child: switcher)
        : switcher;
  }
}
