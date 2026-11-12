import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../gallery_scaffold.dart';

const List<CarbonOption<String>> _branches = [
  CarbonOption(value: 'main', label: 'main'),
  CarbonOption(value: 'development', label: 'development'),
  CarbonOption(value: 'feat/carbon-flutter', label: 'feat/carbon-flutter'),
  CarbonOption(value: 'feat/session-bus', label: 'feat/session-bus'),
  CarbonOption(
    value: 'fix/terminal-readiness',
    label: 'fix/terminal-readiness',
  ),
  CarbonOption(value: 'release/1.0', label: 'release/1.0', enabled: false),
  CarbonOption(value: 'wip/scratch', label: 'wip/scratch'),
];

enum _Load { ready, loading, failed }

class DropdownPage extends StatefulWidget {
  const DropdownPage({super.key});

  @override
  State<DropdownPage> createState() => _DropdownPageState();
}

class _DropdownPageState extends State<DropdownPage> {
  String? _branch = 'main';
  String? _combo;
  String? _custom;
  String? _loadValue;
  _Load _load = _Load.ready;
  String _typed = '';
  final List<CarbonOption<String>> _extra = [];
  late final List<CarbonOption<String>> _large = [
    for (var i = 0; i < 2000; i++)
      CarbonOption(value: 'p$i', label: 'project-$i'),
  ];
  String? _largeValue;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    return GalleryPage(
      title: 'Dropdown and combo box',
      summary:
          'An option picker. The dropdown chooses from a list; the combo '
          'box adds a text input that filters it. Searching never commits.',
      children: [
        GallerySection(
          title: 'Dropdown',
          children: [
            CarbonDropdown<String>(
              label: 'Base branch',
              helperText: 'Pull requests target this branch',
              options: _branches,
              value: _branch,
              onChanged: (v) => setState(() => _branch = v),
            ),
            Text('Committed: ${_branch ?? 'none'}'),
          ],
        ),
        GallerySection(
          title: 'Combo box',
          description:
              'Type to filter, arrow keys to highlight, Enter to commit. '
              'Escape closes the list; a second Escape discards what you '
              'typed. Leaving the field restores the committed value.',
          children: [
            CarbonComboBox<String>(
              label: 'Branch',
              options: _branches,
              value: _combo,
              onChanged: (v) => setState(() => _combo = v),
            ),
            Text('Committed: ${_combo ?? 'none'}'),
          ],
        ),
        GallerySection(
          title: 'Free text',
          description:
              'Only when the host opts in. Enter with nothing highlighted '
              'hands the typed text to the host, which decides what to '
              'commit.',
          children: [
            CarbonComboBox<String>(
              label: 'Branch or new name',
              options: [..._branches, ..._extra],
              value: _custom,
              onChanged: (v) => setState(() => _custom = v),
              allowCustomValue: true,
              onCustomValue: (text) => setState(() {
                _extra.add(CarbonOption(value: text, label: text));
                _custom = text;
              }),
            ),
            Text('Committed: ${_custom ?? 'none'}'),
          ],
        ),
        GallerySection(
          title: 'Loading and error',
          description: 'The host drives the list state.',
          children: [
            Wrap(
              spacing: CarbonSpacing.spacing03,
              runSpacing: CarbonSpacing.spacing03,
              children: [
                for (final state in _Load.values)
                  CarbonButton(
                    label: state.name,
                    kind: _load == state
                        ? CarbonButtonKind.primary
                        : CarbonButtonKind.tertiary,
                    size: CarbonButtonSize.small,
                    onPressed: () => setState(() => _load = state),
                  ),
              ],
            ),
            CarbonComboBox<String>(
              label: 'Remote branch',
              options: _load == _Load.ready ? _branches : const [],
              value: _loadValue,
              loading: _load == _Load.loading,
              listErrorText: _load == _Load.failed
                  ? 'Could not reach the remote'
                  : null,
              onChanged: (v) => setState(() => _loadValue = v),
              onInputChanged: (text) => setState(() => _typed = text),
            ),
            Text(
              'Last typed: ${_typed.isEmpty ? '-' : _typed}',
              style: theme.typography.helper.copyWith(
                color: theme.colors.textSecondary,
              ),
            ),
          ],
        ),
        GallerySection(
          title: 'Large list',
          description: 'Rows are built lazily; 2,000 options.',
          children: [
            CarbonComboBox<String>(
              label: 'Project',
              options: _large,
              value: _largeValue,
              onChanged: (v) => setState(() => _largeValue = v),
            ),
          ],
        ),
        GallerySection(
          title: 'States',
          children: [
            GalleryStateGrid(
              cells: [
                GalleryStateCell(
                  'invalid',
                  _w(
                    CarbonDropdown<String>(
                      label: 'Base branch',
                      errorText: 'Pick a branch',
                      options: _branches,
                      value: null,
                      onChanged: (_) {},
                    ),
                  ),
                ),
                GalleryStateCell(
                  'disabled',
                  _w(
                    CarbonDropdown<String>(
                      label: 'Base branch',
                      options: _branches,
                      value: 'main',
                      onChanged: null,
                    ),
                  ),
                ),
                GalleryStateCell(
                  'read-only',
                  _w(
                    CarbonDropdown<String>(
                      label: 'Base branch',
                      readOnly: true,
                      options: _branches,
                      value: 'main',
                      onChanged: (_) {},
                    ),
                  ),
                ),
                GalleryStateCell(
                  'unavailable value',
                  _w(
                    CarbonDropdown<String>(
                      label: 'Base branch',
                      options: _branches,
                      value: 'deleted-branch',
                      onChanged: (_) {},
                    ),
                  ),
                ),
                GalleryStateCell(
                  'combo invalid',
                  _w(
                    CarbonComboBox<String>(
                      label: 'Branch',
                      errorText: 'Pick a branch',
                      options: _branches,
                      value: null,
                      onChanged: (_) {},
                    ),
                  ),
                ),
                GalleryStateCell(
                  'combo disabled',
                  _w(
                    CarbonComboBox<String>(
                      label: 'Branch',
                      options: _branches,
                      value: 'main',
                      onChanged: null,
                    ),
                  ),
                ),
                GalleryStateCell(
                  'combo read-only',
                  _w(
                    CarbonComboBox<String>(
                      label: 'Branch',
                      readOnly: true,
                      options: _branches,
                      value: 'main',
                      onChanged: (_) {},
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        const GalleryNote(
          useWhen:
              'Picking from a longer list such as projects or branches, '
              'especially when the user may want to search. Use Select for a '
              'short form value.',
          keyboard:
              'Dropdown: as Select. Combo box: Up/Down open and move the '
              'highlight, Enter commits it, Escape closes then discards the '
              'typed filter, Tab leaves and restores the committed value. '
              'Home and End edit the text.',
          accessibility:
              'The combo field is a text field announcing label, text and '
              'expanded state. Rows announce selected and disabled state. '
              'Loading and error rows are live regions. Touch users open the '
              'list by tapping the field.',
          carbonReference: 'Carbon v11 Dropdown and Combo box.',
        ),
      ],
    );
  }
}

Widget _w(Widget child) => ConstrainedBox(
  constraints: const BoxConstraints(maxWidth: 320),
  child: child,
);
