import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../gallery_scaffold.dart';

const List<CarbonOption<String>> _portModes = [
  CarbonOption(value: 'auto', label: 'Detect automatically'),
  CarbonOption(value: 'manual', label: 'Manual list only'),
  CarbonOption(value: 'off', label: 'Never scan', enabled: false),
  CarbonOption(
    value: 'verbose',
    label: 'Scan every interface, including virtual adapters and containers',
  ),
];

class SelectPage extends StatefulWidget {
  const SelectPage({super.key});

  @override
  State<SelectPage> createState() => _SelectPageState();
}

class _SelectPageState extends State<SelectPage> {
  String? _mode = 'auto';
  String? _empty;
  String? _invalid;
  String? _missing = 'gone';
  String? _described = 'b';

  @override
  Widget build(BuildContext context) {
    return GalleryPage(
      title: 'Select',
      summary:
          'A labeled form field that holds one value from a short list. The '
          'host owns the committed value; the field only reports a choice.',
      children: [
        GallerySection(
          title: 'Basic',
          children: [
            CarbonSelect<String>(
              label: 'Port detection',
              helperText: 'How the preview finds your dev server',
              options: _portModes,
              value: _mode,
              onChanged: (v) => setState(() => _mode = v),
            ),
            Text('Committed: ${_mode ?? 'none'}'),
          ],
        ),
        GallerySection(
          title: 'States',
          description:
              'Disabled and read-only keep their value. Errors and warnings '
              'are text plus an icon, never color alone.',
          children: [
            GalleryStateGrid(
              cells: [
                GalleryStateCell(
                  'placeholder',
                  _w(
                    CarbonSelect<String>(
                      label: 'Port detection',
                      options: _portModes,
                      value: _empty,
                      onChanged: (v) => setState(() => _empty = v),
                    ),
                  ),
                ),
                GalleryStateCell(
                  'invalid',
                  _w(
                    CarbonSelect<String>(
                      label: 'Port detection',
                      errorText: 'Choose how ports are detected',
                      options: _portModes,
                      value: _invalid,
                      onChanged: (v) => setState(() => _invalid = v),
                    ),
                  ),
                ),
                GalleryStateCell(
                  'warning',
                  _w(
                    CarbonSelect<String>(
                      label: 'Port detection',
                      warnText: 'Manual lists can go stale',
                      options: _portModes,
                      value: 'manual',
                      onChanged: (_) {},
                    ),
                  ),
                ),
                GalleryStateCell(
                  'disabled',
                  _w(
                    CarbonSelect<String>(
                      label: 'Port detection',
                      options: _portModes,
                      value: 'auto',
                      onChanged: null,
                    ),
                  ),
                ),
                GalleryStateCell(
                  'read-only',
                  _w(
                    CarbonSelect<String>(
                      label: 'Port detection',
                      readOnly: true,
                      options: _portModes,
                      value: 'auto',
                      onChanged: (_) {},
                    ),
                  ),
                ),
                GalleryStateCell(
                  'required',
                  _w(
                    CarbonSelect<String>(
                      label: 'Port detection',
                      required: true,
                      options: _portModes,
                      value: null,
                      onChanged: (_) {},
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        GallerySection(
          title: 'Unavailable value and empty options',
          description:
              'A value the list no longer offers is shown as unavailable and '
              'is never swapped for another option. An empty list says so.',
          children: [
            GalleryStateGrid(
              cells: [
                GalleryStateCell(
                  'value not in options',
                  _w(
                    CarbonSelect<String>(
                      label: 'Port detection',
                      options: _portModes,
                      value: _missing,
                      onChanged: (v) => setState(() => _missing = v),
                    ),
                  ),
                ),
                GalleryStateCell(
                  'no options',
                  _w(
                    CarbonSelect<String>(
                      label: 'Environment',
                      options: const <CarbonOption<String>>[],
                      value: null,
                      onChanged: (_) {},
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        GallerySection(
          title: 'Descriptions',
          children: [
            CarbonSelect<String>(
              label: 'Shell',
              options: const [
                CarbonOption(
                  value: 'a',
                  label: 'PowerShell',
                  description: 'Windows default',
                ),
                CarbonOption(
                  value: 'b',
                  label: 'bash',
                  description: 'Git Bash or WSL',
                ),
                CarbonOption(
                  value: 'c',
                  label: 'zsh',
                  description: 'macOS default',
                ),
              ],
              value: _described,
              onChanged: (v) => setState(() => _described = v),
            ),
          ],
        ),
        const GalleryNote(
          useWhen:
              'A single value in a form or settings list, such as a '
              'preference with a handful of choices. Use Dropdown or the '
              'combo box for long or searchable lists and a Menu for '
              'commands.',
          keyboard:
              'Enter, Space, Alt+Down or Up/Down open the list. Up/Down, '
              'Home and End move the highlight past disabled options; typing '
              'a prefix jumps to a match. Enter or Space commits; Escape '
              'closes without committing. Focus stays on the field.',
          accessibility:
              'The field is a button announcing its label, value, required '
              'and expanded state plus the helper or error text. Each option '
              'announces whether it is selected or disabled. A read-only '
              'field stays focusable.',
          carbonReference: 'Carbon v11 Select (rendered by Flutter).',
        ),
      ],
    );
  }
}

Widget _w(Widget child) => ConstrainedBox(
  constraints: const BoxConstraints(maxWidth: 320),
  child: child,
);
