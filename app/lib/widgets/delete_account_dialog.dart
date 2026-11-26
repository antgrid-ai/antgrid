import 'package:flutter/widgets.dart';

import '../design/widgets/ab_confirm_dialog.dart';

/// Type-to-confirm account deletion. Thin wrapper over [AbConfirmDialog] with
/// the deletion copy and a `DELETE` confirm word — returns `true` only when the
/// user types the word and taps the destructive button.
class DeleteAccountDialog {
  const DeleteAccountDialog._();

  static Future<bool> show(BuildContext context) {
    return AbConfirmDialog.show(
      context: context,
      title: 'Delete account?',
      body:
          'This permanently deletes your account, sessions, connected '
          'devices, and sign-in credentials. This cannot be undone.',
      confirmLabel: 'Delete account',
      destructive: true,
      confirmWord: 'DELETE',
    );
  }
}
