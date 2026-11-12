import 'dart:async';

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../gallery_scaffold.dart';

const String _longText =
    'Modal content that runs long scrolls inside the dialog while the title '
    'and the actions stay in view, at any text size and window height.';

class ModalPage extends StatelessWidget {
  const ModalPage({super.key});

  @override
  Widget build(BuildContext context) {
    return GalleryPage(
      title: 'Modal',
      summary:
          'Informational, confirmation and form dialogs presented as a route. '
          'Theme, density and direction stay live while one is open, focus '
          'stays inside and returns to the trigger, and the host decides '
          'when a dialog may be dismissed.',
      children: [
        const GallerySection(
          title: 'Open a dialog',
          description:
              'Presented from this page, so the scrim covers the whole window. '
              'Change theme or density in the settings bar while one is open: '
              'it updates in place and keeps typed text.',
          children: [_Launchers()],
        ),
        GallerySection(
          title: 'Anatomy',
          description:
              'Static previews of the same surface, so the settings bar '
              'applies to them directly.',
          children: [
            _Preview(
              child: CarbonModal.informational(
                label: 'About',
                title: 'Antgrid for desktop',
                body: const Text('Version 1.0.0. Released this week.'),
                onClose: () {},
              ),
            ),
            _Preview(
              child: CarbonModal.confirmation(
                title: 'Delete project?',
                danger: true,
                body: const Text(
                  'The project and its sessions are removed from this '
                  'machine. This cannot be undone.',
                ),
                primary: CarbonModalAction(label: 'Delete', onPressed: () {}),
                secondary: CarbonModalAction(label: 'Cancel', onPressed: () {}),
                onClose: () {},
              ),
            ),
            _Preview(
              child: CarbonModal.confirmation(
                title: 'Saving changes',
                body: const Text('The host marks the primary action busy.'),
                primary: const CarbonModalAction(label: 'Save', busy: true),
                secondary: CarbonModalAction(label: 'Cancel', onPressed: () {}),
                onClose: () {},
              ),
            ),
          ],
        ),
        GallerySection(
          title: 'Long content',
          description:
              'Capped height: the body scrolls, the header and actions stay.',
          children: [
            SizedBox(
              height: MediaQuery.textScalerOf(context).scale(560),
              child: _Preview(
                child: CarbonModal.confirmation(
                  label: 'Release notes',
                  title: 'A title that is long enough to wrap on narrow screens',
                  body: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var i = 0; i < 12; i++)
                        Padding(
                          padding: const EdgeInsets.only(
                            bottom: CarbonSpacing.spacing03,
                          ),
                          child: Text(_longText),
                        ),
                    ],
                  ),
                  primary: CarbonModalAction(label: 'Continue', onPressed: () {}),
                  secondary: CarbonModalAction(label: 'Back', onPressed: () {}),
                  onClose: () {},
                ),
              ),
            ),
          ],
        ),
        const GalleryNote(
          useWhen:
              'Informational dialogs for passive detail, confirmation for a '
              'decision that interrupts, form dialogs for short input. Avoid '
              'a dialog when inline content would do.',
          keyboard:
              'Tab and Shift+Tab cycle inside the dialog. Escape and system '
              'back close it when the host allows; the scrim closes it only '
              'when barrierDismissible. Closing returns focus to the '
              'trigger.',
          accessibility:
              'Announced as a dialog named by its title; the close button is '
              'named from the localizations. A busy primary action announces '
              '"Loading" and cannot be activated twice. Narrow screens use '
              'the full-screen presentation, and a host can supply its own '
              '(bottom sheet, side panel) with the same dismissal and focus '
              'rules.',
          carbonReference: 'Carbon v11 Modal (passive, transactional, danger).',
        ),
      ],
    );
  }
}

/// A bordered stage so a dialog previewed inline reads as a surface.
class _Preview extends StatelessWidget {
  const _Preview({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colors.overlay,
        border: Border.all(color: theme.borderSubtle(1)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(CarbonSpacing.spacing04),
        child: Align(alignment: Alignment.topCenter, child: child),
      ),
    );
  }
}

class _Launchers extends StatefulWidget {
  const _Launchers();

  @override
  State<_Launchers> createState() => _LaunchersState();
}

class _LaunchersState extends State<_Launchers> {
  String _last = 'Nothing opened yet';

  Future<void> _run(Future<Object?> opening, String name) async {
    final result = await opening;
    if (!mounted) return;
    setState(() => _last = '$name closed with ${result ?? 'no result'}');
  }

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: CarbonSpacing.spacing04,
          runSpacing: CarbonSpacing.spacing03,
          children: [
            CarbonButton(
              label: 'Informational',
              kind: CarbonButtonKind.tertiary,
              onPressed: () => unawaited(
                _run(
                  showCarbonModal<String>(
                    context,
                    builder: (context) => const CarbonModal.informational(
                      label: 'About',
                      title: 'Antgrid for desktop',
                      body: Text('Version 1.0.0. Released this week.'),
                    ),
                  ),
                  'Informational',
                ),
              ),
            ),
            CarbonButton(
              label: 'Confirmation',
              kind: CarbonButtonKind.tertiary,
              onPressed: () => unawaited(
                _run(
                  showCarbonModal<String>(
                    context,
                    barrierDismissible: false,
                    builder: (context) => CarbonModal.confirmation(
                      title: 'Discard draft?',
                      body: const Text('Your changes will be lost.'),
                      primary: CarbonModalAction(
                        label: 'Discard',
                        onPressed: () => Navigator.of(context).pop('Discard'),
                      ),
                      secondary: CarbonModalAction(
                        label: 'Keep editing',
                        autofocus: true,
                        onPressed: () => Navigator.of(context).pop('Keep'),
                      ),
                    ),
                  ),
                  'Confirmation',
                ),
              ),
            ),
            CarbonButton(
              label: 'Danger',
              kind: CarbonButtonKind.dangerTertiary,
              onPressed: () => unawaited(
                _run(
                  showCarbonModal<String>(
                    context,
                    barrierDismissible: false,
                    builder: (context) => CarbonModal.confirmation(
                      title: 'Delete project?',
                      danger: true,
                      body: const Text('This cannot be undone.'),
                      primary: CarbonModalAction(
                        label: 'Delete',
                        onPressed: () => Navigator.of(context).pop('Delete'),
                      ),
                      secondary: CarbonModalAction(
                        label: 'Cancel',
                        autofocus: true,
                        onPressed: () => Navigator.of(context).pop('Cancel'),
                      ),
                    ),
                  ),
                  'Danger',
                ),
              ),
            ),
            CarbonButton(
              label: 'Form',
              kind: CarbonButtonKind.tertiary,
              onPressed: () {
                final form = _FormController();
                unawaited(
                  _run(
                    showCarbonModal<String>(
                      context,
                      barrierDismissible: false,
                      canDismiss: () => !form.saving.value,
                      builder: (context) => _RenameDialog(form: form),
                    ).whenComplete(form.dispose),
                    'Form',
                  ),
                );
              },
            ),
            CarbonButton(
              label: 'Long content',
              kind: CarbonButtonKind.tertiary,
              onPressed: () => unawaited(
                _run(
                  showCarbonModal<String>(
                    context,
                    builder: (context) => CarbonModal.confirmation(
                      label: 'Terms',
                      title: 'Review the terms',
                      body: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (var i = 0; i < 24; i++)
                            Padding(
                              padding: const EdgeInsets.only(
                                bottom: CarbonSpacing.spacing03,
                              ),
                              child: Text('$i. $_longText'),
                            ),
                        ],
                      ),
                      primary: CarbonModalAction(
                        label: 'Accept',
                        onPressed: () => Navigator.of(context).pop('Accept'),
                      ),
                      secondary: CarbonModalAction(
                        label: 'Decline',
                        onPressed: () => Navigator.of(context).pop('Decline'),
                      ),
                    ),
                  ),
                  'Long content',
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: CarbonSpacing.spacing04),
        Wrap(
          spacing: CarbonSpacing.spacing04,
          runSpacing: CarbonSpacing.spacing03,
          children: [
            for (final size in CarbonModalSize.values)
              CarbonButton(
                label: 'Size ${size.name}',
                kind: CarbonButtonKind.ghost,
                onPressed: () => unawaited(
                  _run(
                    showCarbonModal<String>(
                      context,
                      builder: (context) => CarbonModal.informational(
                        title: 'Size ${size.name}',
                        size: size,
                        body: Text('Up to ${size.width.round()} logical pixels wide.'),
                      ),
                    ),
                    'Size ${size.name}',
                  ),
                ),
              ),
            CarbonButton(
              label: 'Full screen',
              kind: CarbonButtonKind.ghost,
              onPressed: () => unawaited(
                _run(
                  showCarbonModal<String>(
                    context,
                    presentation: const CarbonModalPresentation.fullScreen(),
                    builder: (context) => CarbonModal.informational(
                      title: 'Full screen',
                      body: const Text(
                        'The same dialog on the whole screen, as the default '
                        'adaptive presentation does on narrow windows.',
                      ),
                    ),
                  ),
                  'Full screen',
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: CarbonSpacing.spacing04),
        Text(
          _last,
          style: theme.typography.body.copyWith(
            color: theme.colors.textSecondary,
          ),
        ),
      ],
    );
  }
}

/// Host state for the form dialog: whether a save is in flight.
class _FormController {
  final ValueNotifier<bool> saving = ValueNotifier<bool>(false);

  void dispose() => saving.dispose();
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.form});

  final _FormController form;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  final TextEditingController _name = TextEditingController();
  Timer? _timer;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.form.saving.addListener(_onSaving);
  }

  @override
  void dispose() {
    widget.form.saving.removeListener(_onSaving);
    _timer?.cancel();
    _name.dispose();
    super.dispose();
  }

  void _onSaving() => setState(() {});

  // Stands in for the host's request: busy for two seconds, then close. The
  // dialog cannot be dismissed meanwhile because the host vetoes it.
  void _save() {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Enter a name');
      return;
    }
    setState(() => _error = null);
    widget.form.saving.value = true;
    _timer = Timer(const Duration(seconds: 2), () {
      widget.form.saving.value = false;
      if (mounted) Navigator.of(context).pop(_name.text.trim());
    });
  }

  @override
  Widget build(BuildContext context) {
    final saving = widget.form.saving.value;
    return CarbonModal(
      label: 'Project',
      title: 'Rename project',
      body: CarbonTextInput(
        controller: _name,
        label: 'Name',
        required: true,
        autofocus: true,
        enabled: !saving,
        errorText: _error,
        helperText: 'Visible in the project list.',
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
      ),
      actions: [
        CarbonModalAction(
          label: 'Cancel',
          kind: CarbonButtonKind.secondary,
          onPressed: saving ? null : () => Navigator.of(context).pop(),
        ),
        CarbonModalAction(label: 'Save', busy: saving, onPressed: _save),
      ],
    );
  }
}
