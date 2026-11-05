import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/widgets/ab_confirm_dialog.dart';
import '../design/widgets/ab_toast.dart';
import '../providers/sign_out.dart';
import '../services/sign_out_service.dart';
import '../util/ab_log.dart';

/// Confirms intent, then runs the full hard sign-out (revoke this device +
/// wipe all local identity). The single entry point for every UI affordance
/// that signs the user out, so the copy and flow stay identical everywhere.
///
/// Returns `true` if the user confirmed and sign-out completed, `false` if
/// cancelled or if the teardown could not finish.
Future<bool> confirmAndHardSignOut(BuildContext context, WidgetRef ref) async {
  final container = ref.container;
  final toaster = AbToaster.maybeOf(context);
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
  return hardSignOutFromUi(container, toaster);
}

/// [performHardSignOut] for a UI affordance, which has nowhere to send a
/// failure: menu and tap handlers drop the future, so a rethrow would land as
/// an uncaught crash.
///
/// The one failure is native teardown not confirming it released a
/// connection. The service then refuses every retry this process and the
/// account stays signed in, so the user is told rather than left watching a
/// button do nothing. [toaster] is taken before any await because the
/// affordance that started this may be gone by the time it fails.
Future<bool> hardSignOutFromUi(
  ProviderContainer container,
  AbToaster? toaster,
) async {
  try {
    await performHardSignOut(container);
    return true;
  } on SignOutCleanupIncomplete catch (e) {
    AbLog.error(
      'SignOut',
      'sign-out cleanup incomplete',
      fields: {'error': '${e.cause}'},
    );
    toaster?.showMessage(
      "Couldn't finish signing out. Restart Antgrid and try again.",
    );
    return false;
  }
}
