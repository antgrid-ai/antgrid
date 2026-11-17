import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

/// Type-to-confirm account deletion. A Carbon modal with the deletion copy and
/// a `DELETE` confirm word; resolves `true` only when the user types the word
/// and presses the destructive button.
///
/// [context] must sit under a Carbon scope: the modal route takes its theme and
/// density from the presenting context.
class DeleteAccountDialog {
  const DeleteAccountDialog._();

  static const confirmWord = 'DELETE';

  static Future<bool> show(BuildContext context) async {
    final confirmed = await showCarbonModal<bool>(
      context,
      builder: (_) => const _DeleteAccountModal(),
    );
    return confirmed ?? false;
  }
}

class _DeleteAccountModal extends StatefulWidget {
  const _DeleteAccountModal();

  @override
  State<_DeleteAccountModal> createState() => _DeleteAccountModalState();
}

class _DeleteAccountModalState extends State<_DeleteAccountModal> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _typed => _controller.text.trim() == DeleteAccountDialog.confirmWord;

  void _answer(bool value) => Navigator.of(context).pop(value);

  @override
  Widget build(BuildContext context) {
    final t = CarbonTheme.of(context);
    return CarbonModal(
      size: CarbonModalSize.xs,
      title: 'Delete account?',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'This permanently deletes your account, sessions, connected '
            'devices, and sign-in credentials. This cannot be undone.',
            style: t.typography.body.copyWith(color: t.colors.textPrimary),
          ),
          const SizedBox(height: CarbonSpacing.spacing05),
          CarbonTextInput(
            controller: _controller,
            label: 'Type ${DeleteAccountDialog.confirmWord} to confirm',
            // The field takes initial focus rather than Cancel: the button
            // stays disabled until the word is typed, so Cancel is not what a
            // keyboard user needs first.
            autofocus: true,
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
      actions: [
        CarbonModalAction(
          label: 'Cancel',
          kind: CarbonButtonKind.secondary,
          onPressed: () => _answer(false),
        ),
        CarbonModalAction(
          label: 'Delete account',
          kind: CarbonButtonKind.danger,
          onPressed: _typed ? () => _answer(true) : null,
        ),
      ],
    );
  }
}
