import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show TextInputAction, TextInputType;
import 'package:flutter/widgets.dart';

import '../gallery_scaffold.dart';

class FormPage extends StatefulWidget {
  const FormPage({super.key});

  @override
  State<FormPage> createState() => _FormPageState();
}

class _FormPageState extends State<FormPage> {
  final CarbonFormController _form = CarbonFormController();
  late final TextEditingController _name = TextEditingController();
  late final TextEditingController _email = TextEditingController(
    text: 'not-an-email',
  );
  late final TextEditingController _password = TextEditingController();
  late final TextEditingController _notes = TextEditingController();

  // Validation is the host's: it decides what is wrong and hands the text to
  // the fields. The form only helps the user find the first problem.
  Map<String, String> _errors = const <String, String>{};
  bool _busy = false;
  String _status = 'Nothing submitted yet.';

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    _notes.dispose();
    super.dispose();
  }

  Map<String, String> _validate() => <String, String>{
    if (_name.text.trim().isEmpty) 'name': 'Enter your name',
    if (!_email.text.contains('@')) 'email': 'Enter an address with an @',
    if (_password.text.length < 8)
      'password': 'Use at least 8 characters',
  };

  void _submit() {
    final errors = _validate();
    setState(() {
      _errors = errors;
      _status = errors.isEmpty
          ? 'Saved.'
          : '${errors.length} field(s) need attention.';
    });
    if (errors.isEmpty) return;
    // After the frame that shows the errors, so the fields are registered
    // as invalid when the form looks for the first one.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted) _form.focusFirstInvalid();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    return GalleryPage(
      title: 'Form',
      summary:
          'Consistent field grouping, required-field communication and an '
          'action row. Validation and submission stay with the host; the '
          'form can move focus to the first field showing an error.',
      children: <Widget>[
        GallerySection(
          title: 'Settings form',
          description:
              'Save validates in the host, shows errors and focuses the '
              'first invalid field, even when it is off screen.',
          children: <Widget>[
            CarbonForm(
              controller: _form,
              requiredNote: 'Fields marked required must be filled in.',
              children: <Widget>[
                CarbonFormSection(
                  title: 'Profile',
                  description: 'How you appear to the people you work with.',
                  children: <Widget>[
                    CarbonTextInput(
                      controller: _name,
                      label: 'Name',
                      required: true,
                      errorText: _errors['name'],
                      textInputAction: TextInputAction.next,
                    ),
                    CarbonTextInput(
                      controller: _email,
                      label: 'Email',
                      required: true,
                      keyboardType: TextInputType.emailAddress,
                      errorText: _errors['email'],
                      textInputAction: TextInputAction.next,
                    ),
                    CarbonTextInput(
                      controller: _notes,
                      label: 'Notes',
                      showOptional: true,
                      variant: CarbonTextInputVariant.multiline,
                      minLines: 2,
                    ),
                  ],
                ),
                CarbonFormSection(
                  title: 'Security',
                  children: <Widget>[
                    CarbonTextInput(
                      controller: _password,
                      label: 'Password',
                      required: true,
                      variant: CarbonTextInputVariant.password,
                      errorText: _errors['password'],
                      helperText: 'At least 8 characters',
                    ),
                  ],
                ),
                CarbonFormActions(
                  children: <Widget>[
                    CarbonButton(
                      label: 'Reset',
                      kind: CarbonButtonKind.secondary,
                      onPressed: () => setState(() {
                        _errors = const <String, String>{};
                        _status = 'Nothing submitted yet.';
                      }),
                    ),
                    CarbonButton(
                      label: 'Save changes',
                      busy: _busy,
                      onPressed: _submit,
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: CarbonSpacing.spacing04),
            Text(
              _status,
              style: theme.typography.helper.copyWith(
                color: theme.colors.textSecondary,
              ),
            ),
            const SizedBox(height: CarbonSpacing.spacing04),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: CarbonButton(
                label: _busy ? 'Finish submission' : 'Simulate busy submit',
                kind: CarbonButtonKind.tertiary,
                onPressed: () => setState(() => _busy = !_busy),
              ),
            ),
          ],
        ),
        GallerySection(
          title: 'Long labels and enlarged text',
          description:
              'Everything wraps and the action set stacks when the labels do '
              'not fit side by side.',
          children: <Widget>[
            CarbonForm(
              children: <Widget>[
                const CarbonTextInput(
                  label:
                      'A deliberately long field label that needs to wrap at '
                      'narrow widths',
                  required: true,
                  errorText: 'A long error message that also needs to wrap',
                ),
                CarbonFormActions(
                  children: <Widget>[
                    CarbonButton(
                      label: 'Discard all unsaved changes',
                      kind: CarbonButtonKind.secondary,
                      onPressed: () {},
                    ),
                    CarbonButton(
                      label: 'Save and close this panel',
                      onPressed: () {},
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
        const GalleryNote(
          useWhen:
              'Grouping several fields with one set of actions. The host '
              'validates and submits; the form never does.',
          keyboard:
              'Tab follows visual order. After a failed submit the host calls '
              'focusFirstInvalid, which scrolls the first field showing an '
              'error into view and focuses it.',
          accessibility:
              'The form and section titles are exposed as a form region and '
              'headings. Each field announces its label, required state and '
              'error on the field itself; focusing it reads them out.',
          carbonReference: 'Form',
        ),
      ],
    );
  }
}
