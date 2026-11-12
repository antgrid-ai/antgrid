import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/services.dart' show TextInputType;
import 'package:flutter/widgets.dart';

import '../gallery_scaffold.dart';

const String _longLabel =
    'Name of the project as it should appear to everyone you invite';

Widget _cell(Widget field) => SizedBox(width: 280, child: field);

class TextInputPage extends StatefulWidget {
  const TextInputPage({super.key});

  @override
  State<TextInputPage> createState() => _TextInputPageState();
}

class _TextInputPageState extends State<TextInputPage> {
  late final TextEditingController _clearable = TextEditingController(
    text: 'Clear me',
  );
  late final TextEditingController _password = TextEditingController(
    text: 'hunter2',
  );
  late final TextEditingController _counted = TextEditingController(
    text: 'Short',
  );
  late final TextEditingController _multiline = TextEditingController(
    text: 'First line\nSecond line',
  );
  late final TextEditingController _selected = TextEditingController(
    text: 'Select part of this text, then switch density',
  );

  @override
  void dispose() {
    _clearable.dispose();
    _password.dispose();
    _counted.dispose();
    _multiline.dispose();
    _selected.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GalleryPage(
      title: 'Text input',
      summary:
          'Single-line, password and multi-line editing on Flutter\'s own '
          'text machinery, so selection, IME composition, autofill and the '
          'clipboard behave natively. Validation text comes from the host.',
      children: <Widget>[
        GallerySection(
          title: 'Variants',
          description: 'Height follows density; text and helper wrap.',
          children: <Widget>[
            GalleryStateGrid(
              cells: <GalleryStateCell>[
                GalleryStateCell(
                  'single line',
                  _cell(
                    const CarbonTextInput(
                      label: 'Name',
                      placeholder: 'Ada Lovelace',
                      helperText: 'As it appears on your badge',
                    ),
                  ),
                ),
                GalleryStateCell(
                  'password',
                  _cell(
                    CarbonTextInput(
                      controller: _password,
                      label: 'Password',
                      variant: CarbonTextInputVariant.password,
                      helperText: 'The eye button shows or hides it',
                    ),
                  ),
                ),
                GalleryStateCell(
                  'multi-line',
                  _cell(
                    CarbonTextInput(
                      controller: _multiline,
                      label: 'Notes',
                      variant: CarbonTextInputVariant.multiline,
                      placeholder: 'Anything else',
                    ),
                  ),
                ),
                GalleryStateCell(
                  'clearable',
                  _cell(
                    CarbonTextInput(
                      controller: _clearable,
                      label: 'Nickname',
                      clearable: true,
                    ),
                  ),
                ),
                GalleryStateCell(
                  'password + clear',
                  _cell(
                    CarbonTextInput(
                      controller: _password,
                      label: 'Password',
                      variant: CarbonTextInputVariant.password,
                      clearable: true,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        GallerySection(
          title: 'States',
          description:
              'Error and warning are text plus an icon, never color alone. '
              'Read-only keeps selection and copy; disabled is inert.',
          children: <Widget>[
            GalleryStateGrid(
              cells: <GalleryStateCell>[
                GalleryStateCell(
                  'required',
                  _cell(const CarbonTextInput(label: 'Email', required: true)),
                ),
                GalleryStateCell(
                  'optional marker',
                  _cell(
                    const CarbonTextInput(
                      label: 'Nickname',
                      showOptional: true,
                    ),
                  ),
                ),
                GalleryStateCell(
                  'invalid',
                  _cell(
                    const CarbonTextInput(
                      label: 'Email',
                      required: true,
                      errorText: 'Enter an address like name@example.com',
                    ),
                  ),
                ),
                GalleryStateCell(
                  'invalid + focused',
                  _cell(
                    const CarbonTextInput(
                      label: 'Email',
                      autofocus: true,
                      errorText: 'Enter an address like name@example.com',
                    ),
                  ),
                ),
                GalleryStateCell(
                  'warning',
                  _cell(
                    const CarbonTextInput(
                      label: 'Display name',
                      warnText: 'This name is already used by someone else',
                    ),
                  ),
                ),
                GalleryStateCell(
                  'read-only',
                  _cell(
                    CarbonTextInput(
                      controller: TextEditingController(text: 'abc-123'),
                      label: 'Token',
                      readOnly: true,
                      helperText: 'Select and copy it',
                    ),
                  ),
                ),
                GalleryStateCell(
                  'disabled',
                  _cell(
                    const CarbonTextInput(
                      label: 'Team',
                      placeholder: 'Locked',
                      enabled: false,
                      helperText: 'Ask an admin to change this',
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        GallerySection(
          title: 'Prefix, suffix and counter',
          children: <Widget>[
            GalleryStateGrid(
              cells: <GalleryStateCell>[
                GalleryStateCell(
                  'prefix and suffix',
                  _cell(
                    CarbonTextInput(
                      label: 'Price',
                      prefix: Text(
                        '\$',
                        style: CarbonTheme.of(context).typography.control,
                      ),
                      suffix: Text(
                        'USD',
                        style: CarbonTheme.of(context).typography.helper,
                      ),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ),
                GalleryStateCell(
                  'counter',
                  _cell(
                    CarbonTextInput(
                      controller: _counted,
                      label: 'Short bio',
                      maxLength: 24,
                      showCounter: true,
                    ),
                  ),
                ),
                GalleryStateCell(
                  'counter, multi-line',
                  _cell(
                    const CarbonTextInput(
                      label: 'Summary',
                      variant: CarbonTextInputVariant.multiline,
                      maxLength: 120,
                      showCounter: true,
                      minLines: 2,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        GallerySection(
          title: 'Long labels and enlarged text',
          description:
              'Labels, helpers and errors wrap and the column grows. Try 200% '
              'text and the narrow width.',
          children: <Widget>[
            const CarbonTextInput(
              label: _longLabel,
              helperText:
                  'Helper text that is long enough to need more than one line '
                  'at narrow widths',
              errorText:
                  'An error that also has quite a lot to say so it wraps too',
              required: true,
            ),
          ],
        ),
        GallerySection(
          title: 'Live changes',
          description:
              'Select part of the text and switch theme, density or '
              'direction in the toolbar: text, selection and focus stay.',
          children: <Widget>[
            CarbonTextInput(
              controller: _selected,
              label: 'Selection survives',
              clearable: true,
            ),
          ],
        ),
        const GalleryNote(
          useWhen:
              'Collecting one value of free text: a name, email, token or '
              'note. Use Search for filtering and Select or Dropdown for '
              'fixed choices.',
          keyboard:
              'Tab moves between the field, its clear action and its reveal '
              'action. Enter and Space activate the actions. Enter submits '
              'single-line fields and inserts a new line in multi-line ones.',
          accessibility:
              'The label, required marker, helper and error are announced on '
              'the editable itself. Clear and reveal have localized names '
              'and 32 (compact) / 48 (touch) targets.',
          carbonReference: 'Text input, Password input and Text area',
        ),
      ],
    );
  }
}
