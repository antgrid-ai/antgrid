import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../../gallery_scaffold.dart';

/// A combo box over a long option list with loading, empty and unavailable
/// states.
class SearchablePickerComposition extends StatefulWidget {
  const SearchablePickerComposition({super.key});

  @override
  State<SearchablePickerComposition> createState() =>
      _SearchablePickerCompositionState();
}

class _SearchablePickerCompositionState
    extends State<SearchablePickerComposition> {
  static const int _count = 3000;
  static const List<String> _regions = ['eu-central', 'us-east', 'ap-south'];

  // Built once: the list length costs memory here but the combo box only
  // builds the rows that are visible, so it never costs frames.
  static final List<CarbonOption<int>> _options = <CarbonOption<int>>[
    for (var i = 0; i < _count; i++)
      CarbonOption<int>(
        value: i,
        label:
            'antgrid-service-${i.toString().padLeft(4, '0')} in '
            '${_regions[i % 3]}',
        enabled: i % 50 != 7,
        description: i % 50 == 7 ? 'Archived' : null,
      ),
  ];

  int? _value;
  bool _loading = false;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final value = _value;
    return GalleryPage(
      title: 'Searchable picker',
      summary:
          'Type to filter thousands of options; the list shows loading and '
          'empty states without moving the field.',
      children: [
        GallerySection(
          title: 'Choose a service',
          children: [
            CarbonComboBox<int>(
              key: const ValueKey('picker-combo'),
              label: 'Deploy target',
              placeholder: 'Search by service name or region',
              helperText: 'Archived services cannot be selected.',
              options: _options,
              value: value,
              loading: _loading,
              emptyText: 'No service matches your search.',
              onChanged: (v) => setState(() => _value = v),
            ),
            CarbonToggle(
              value: _loading,
              labelText: 'Simulate loading options',
              onChanged: (v) => setState(() => _loading = v),
            ),
            Text(
              value == null
                  ? 'Nothing selected.'
                  : 'Selected: ${_options[value].label}',
              key: const ValueKey('picker-result'),
              style: theme.typography.helper.copyWith(
                color: theme.colors.textSecondary,
              ),
            ),
          ],
        ),
        const GalleryNote(
          useWhen:
              'Choosing one item from a list too long to scan, where typing '
              'narrows it quickly.',
          keyboard:
              'Typing filters; Arrow keys move the highlight; Enter picks; '
              'Escape closes the list and keeps the text.',
          accessibility:
              'Exposed as a combo box; the highlighted option and result '
              'count are announced; unavailable options say why.',
          carbonReference: 'Carbon Combo box.',
        ),
      ],
    );
  }
}
