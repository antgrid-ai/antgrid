import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../gallery_scaffold.dart';

class CheckboxPage extends StatefulWidget {
  const CheckboxPage({super.key});

  @override
  State<CheckboxPage> createState() => _CheckboxPageState();
}

class _CheckboxPageState extends State<CheckboxPage> {
  bool _plain = true;
  bool? _tri = false;
  bool _long = false;
  bool _invalid = false;
  Set<String> _group = {'builds'};

  @override
  Widget build(BuildContext context) {
    return GalleryPage(
      title: 'Checkbox',
      summary:
          'Selects any number of independent options. The indicator and label '
          'are one target, so a tap anywhere on the row toggles once.',
      children: [
        GallerySection(
          title: 'Interactive',
          children: [
            CarbonCheckbox(
              value: _plain,
              labelText: 'Notify me when a run finishes',
              onChanged: (v) => setState(() => _plain = v ?? false),
            ),
            CarbonCheckbox(
              value: _tri,
              tristate: true,
              labelText: 'Select all (tristate cycles to indeterminate)',
              onChanged: (v) => setState(() => _tri = v),
            ),
            CarbonCheckbox(
              value: _long,
              labelText:
                  'I have read the terms and conditions, understand them, and '
                  'agree to be bound by every clause including the long ones',
              onChanged: (v) => setState(() => _long = v ?? false),
            ),
          ],
        ),
        GallerySection(
          title: 'States',
          children: [
            GalleryStateGrid(
              cells: [
                GalleryStateCell(
                  'unchecked',
                  CarbonCheckbox(
                    value: false,
                    labelText: 'Option',
                    onChanged: (_) {},
                  ),
                ),
                GalleryStateCell(
                  'checked',
                  CarbonCheckbox(
                    value: true,
                    labelText: 'Option',
                    onChanged: (_) {},
                  ),
                ),
                GalleryStateCell(
                  'indeterminate',
                  CarbonCheckbox(
                    value: null,
                    tristate: true,
                    labelText: 'Option',
                    onChanged: (_) {},
                  ),
                ),
                const GalleryStateCell(
                  'disabled',
                  CarbonCheckbox(
                    value: false,
                    labelText: 'Option',
                    onChanged: null,
                  ),
                ),
                const GalleryStateCell(
                  'disabled checked',
                  CarbonCheckbox(
                    value: true,
                    labelText: 'Option',
                    onChanged: null,
                  ),
                ),
                GalleryStateCell(
                  'read-only checked',
                  CarbonCheckbox(
                    value: true,
                    readOnly: true,
                    labelText: 'Option',
                    onChanged: (_) {},
                  ),
                ),
                GalleryStateCell(
                  'invalid',
                  CarbonCheckbox(
                    value: _invalid,
                    labelText: 'Accept the terms',
                    errorText: _invalid ? null : 'You must accept to continue',
                    onChanged: (v) => setState(() => _invalid = v ?? false),
                  ),
                ),
                GalleryStateCell(
                  'with helper',
                  CarbonCheckbox(
                    value: false,
                    labelText: 'Send weekly digest',
                    helperText: 'Delivered on Mondays',
                    onChanged: (_) {},
                  ),
                ),
                const GalleryStateCell(
                  'no visible label',
                  CarbonCheckbox(
                    value: true,
                    semanticLabel: 'Select row',
                    onChanged: null,
                  ),
                ),
              ],
            ),
          ],
        ),
        GallerySection(
          title: 'Group',
          description: 'A legend, a vertical list and a group-level message.',
          children: [
            CarbonCheckboxGroup<String>(
              legend: 'Notify me about',
              helperText: 'Choose any that apply',
              selected: _group,
              onChanged: (next) => setState(() => _group = next),
              items: const [
                CarbonCheckboxItem(value: 'builds', label: 'Builds'),
                CarbonCheckboxItem(value: 'deploys', label: 'Deploys'),
                CarbonCheckboxItem(
                  value: 'alerts',
                  label: 'Alerts (unavailable)',
                  enabled: false,
                ),
              ],
            ),
            CarbonCheckboxGroup<String>(
              legend: 'Required group',
              errorText: 'Select at least one',
              selected: const <String>{},
              onChanged: (_) {},
              items: const [
                CarbonCheckboxItem(value: 'a', label: 'First'),
                CarbonCheckboxItem(value: 'b', label: 'Second'),
              ],
            ),
          ],
        ),
        const GalleryNote(
          useWhen:
              'Several independent yes/no choices, or a parent that summarises '
              'children (indeterminate). Use a toggle for settings that apply '
              'immediately.',
          keyboard: 'Tab to focus, Space toggles. Read-only stays focusable.',
          accessibility:
              'Announced as a checkbox with checked, unchecked or mixed state; '
              'errors are text with an icon and are read with the control.',
          carbonReference:
              'Checkbox: indicator 16px, 1px border, filled when checked.',
        ),
      ],
    );
  }
}
