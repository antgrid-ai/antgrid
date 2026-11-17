import 'dart:async';

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../../gallery_scaffold.dart';

/// A host-validated settings form: sections, text fields, a select, a
/// checkbox, a toggle and a button set with a busy submit.
class SettingsFormComposition extends StatefulWidget {
  const SettingsFormComposition({super.key});

  @override
  State<SettingsFormComposition> createState() =>
      _SettingsFormCompositionState();
}

class _SettingsFormCompositionState extends State<SettingsFormComposition> {
  static const List<CarbonOption<String>> _regions = <CarbonOption<String>>[
    CarbonOption(
      value: 'eu-central',
      label: 'Europe (Frankfurt), lowest latency from the Berlin office',
    ),
    CarbonOption(value: 'us-east', label: 'US East (N. Virginia)'),
    CarbonOption(
      value: 'ap-south',
      label: 'Asia Pacific (Mumbai)',
      enabled: false,
      description: 'Not available on your plan',
    ),
  ];

  final CarbonFormController _form = CarbonFormController();
  final TextEditingController _name = TextEditingController();
  final TextEditingController _email = TextEditingController();
  final TextEditingController _workspace = TextEditingController(
    text: r'C:\Users\Casey Ramanathan-Whitfield\Documents\Repos\antgrid-public',
  );
  final FocusNode _regionFocus = FocusNode();

  String? _region;
  bool _notify = true;
  bool _autoUpdate = false;
  bool _submitted = false;
  bool _busy = false;
  bool _saved = false;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    _name.dispose();
    _email.dispose();
    _workspace.dispose();
    _regionFocus.dispose();
    super.dispose();
  }

  String? get _nameError => _submitted && _name.text.trim().isEmpty
      ? 'Enter your display name.'
      : null;

  String? get _emailError {
    if (!_submitted) return null;
    final text = _email.text.trim();
    if (text.isEmpty) return 'Enter an email address for build notifications.';
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(text)) {
      return 'Enter an address like name@example.com.';
    }
    return null;
  }

  String? get _regionError =>
      _submitted && _region == null ? 'Choose where sessions should run.' : null;

  bool get _valid =>
      _nameError == null && _emailError == null && _regionError == null;

  void _submit() {
    if (_busy) return;
    setState(() {
      _submitted = true;
      _saved = false;
    });
    if (!_valid) {
      // Fields report invalid only after this frame builds, and the form
      // picks its focus target from the fields that report it.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _form.focusFirstInvalid();
      });
      return;
    }
    setState(() => _busy = true);
    _timer = Timer(const Duration(milliseconds: 1200), () {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _saved = true;
      });
    });
  }

  void _reset() {
    _timer?.cancel();
    _name.clear();
    _email.clear();
    setState(() {
      _region = null;
      _notify = true;
      _autoUpdate = false;
      _submitted = false;
      _busy = false;
      _saved = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return GalleryPage(
      title: 'Settings form',
      summary:
          'Validation lives in the host: the form only collects fields, '
          'reports which are invalid and moves focus to the first one.',
      children: [
        GallerySection(
          title: 'Account settings',
          description:
              'Submit while empty to see errors and focus the first invalid '
              'field.',
          children: [
            if (_saved)
              CarbonNotification(
                key: const ValueKey('settings-saved'),
                kind: CarbonNotificationKind.success,
                title: 'Settings saved',
                subtitle: 'Your changes apply to new sessions immediately.',
                onClose: () => setState(() => _saved = false),
              ),
            CarbonForm(
              key: const ValueKey('settings-form'),
              controller: _form,
              requiredNote: 'Required fields are marked.',
              children: [
                CarbonFormSection(
                  title: 'Profile',
                  description: 'Shown to teammates in shared sessions.',
                  children: [
                    CarbonTextInput(
                      key: const ValueKey('settings-name'),
                      controller: _name,
                      label: 'Display name',
                      placeholder: 'Casey Ramanathan-Whitfield',
                      required: true,
                      errorText: _nameError,
                      onChanged: (_) => setState(() {}),
                    ),
                    CarbonTextInput(
                      key: const ValueKey('settings-email'),
                      controller: _email,
                      label: 'Notification email',
                      placeholder: 'casey@example.com',
                      helperText: 'Build and approval requests are sent here.',
                      required: true,
                      errorText: _emailError,
                      keyboardType: TextInputType.emailAddress,
                      onChanged: (_) => setState(() {}),
                    ),
                  ],
                ),
                CarbonFormSection(
                  title: 'Workspace',
                  children: [
                    CarbonTextInput(
                      controller: _workspace,
                      label: 'Default project folder',
                      helperText:
                          'New sessions start in this folder unless you pick '
                          'another.',
                      clearable: true,
                    ),
                    CarbonFormFieldRegistrar(
                      invalid: _regionError != null,
                      focusNode: _regionFocus,
                      child: CarbonSelect<String>(
                        key: const ValueKey('settings-region'),
                        focusNode: _regionFocus,
                        label: 'Session region',
                        placeholder: 'Choose a region',
                        required: true,
                        options: _regions,
                        value: _region,
                        errorText: _regionError,
                        onChanged: (v) => setState(() => _region = v),
                      ),
                    ),
                  ],
                ),
                CarbonFormSection(
                  title: 'Notifications and updates',
                  children: [
                    CarbonCheckbox(
                      value: _notify,
                      labelText:
                          'Notify me when an agent session finishes or is '
                          'waiting for approval',
                      helperText:
                          'Applies to every device signed in to this account.',
                      onChanged: (v) => setState(() => _notify = v ?? false),
                    ),
                    CarbonToggle(
                      value: _autoUpdate,
                      labelText: 'Install updates automatically',
                      onChanged: (v) => setState(() => _autoUpdate = v),
                    ),
                  ],
                ),
                CarbonFormActions(
                  children: [
                    CarbonButton(
                      label: 'Reset',
                      kind: CarbonButtonKind.secondary,
                      onPressed: _reset,
                    ),
                    CarbonButton(
                      key: const ValueKey('settings-submit'),
                      label: 'Save settings',
                      busy: _busy,
                      onPressed: _busy ? null : _submit,
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
        const GalleryNote(
          useWhen:
              'Collecting several related preferences that are saved together.',
          keyboard:
              'Tab moves through fields in visual order; Enter on the primary '
              'button submits; focus lands on the first invalid field.',
          accessibility:
              'Errors are text plus icon, tied to their field; required '
              'fields announce as required; the busy button cannot be '
              'activated twice.',
          carbonReference: 'Carbon Form, Text input, Select, Checkbox, Toggle.',
        ),
      ],
    );
  }
}
