import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/widgets/ab_confirm_dialog.dart';
import '../providers/sign_out.dart';

/// Confirms intent, then runs the full hard sign-out (revoke this device +
/// wipe all local identity). The single entry point for every UI affordance
/// that signs the user out, so the copy and flow stay identical everywhere.
///
/// Returns `true` if the user confirmed and sign-out ran, `false` if cancelled.
Future<bool> confirmAndHardSignOut(BuildContext context, WidgetRef ref) async {
  final container = ref.container;
  final ok = await AbConfirmDialog.show(
    context: context,
    title: 'Sign out and remove this device?',
    body:
        'This signs you out AND removes this device from your account. '
        'Your phones lose access to this machine until you sign in again — '
        'there is nothing to set up a second time.',
    confirmLabel: 'Sign out',
    destructive: true,
  );
  if (!ok) return false;
  await performHardSignOut(container);
  return true;
}
