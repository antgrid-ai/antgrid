import 'package:flutter/widgets.dart';

import '../design/widgets/ab_snack_bar.dart';
import '../services/sessions_service.dart';
import 'ab_status_helpers.dart';

/// What a user is told when the bridge refuses `session:start`.
///
/// The WORKTREE_MISSING remedy sentence lives here and not in
/// [friendlyErrorCopy]'s arm for that code because the arm is shared with the
/// delete ladder, where three of the code's five producers fire — telling a user
/// mid-delete to delete is advice they have already taken. On the start path,
/// restoring the folder by hand or deleting the session is the whole of what can
/// be done: the bridge exposes no repair verb, so nothing here may read as
/// "Antgrid will fix it".
String sessionStartRefusalCopy(String? code, String? message) {
  if (code == 'WORKTREE_MISSING') {
    return '${friendlyErrorCopy(code)!} Restore its folder on that machine, or '
        'delete the session.';
  }
  return sessionRefusalCopy(code, message, 'Could not start this session.');
}

/// Reports [error] on the root navigator's context rather than [context]'s own:
/// a session tap can dispose the row that fired it (mobile pops the drawer, a
/// cross-project switch rebuilds it), and a message the user asked for must not
/// vanish with the widget. Same reason `recent_session_row_widget.dart`'s onTap
/// hands `openRecentSession` the navigator's context. Falls back to [context]
/// where there is no Navigator (widget tests).
void reportStartRefusal(BuildContext context, SessionOperationException error) {
  final host =
      Navigator.maybeOf(context, rootNavigator: true)?.context ?? context;
  if (!host.mounted) return;
  showAbSnackBar(
    host,
    sessionStartRefusalCopy(error.errorCode, error.message),
    duration: const Duration(seconds: 8),
  );
}
