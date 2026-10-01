import '../design/widgets/ab_toast.dart';
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

/// What a user is told when the bridge refuses `session:fork`.
///
/// Its own fallback rather than [sessionStartRefusalCopy]'s: a fork that never
/// happened and a session that never started are different answers, and the
/// fallback is exactly what a user reads when the refusal carries no code and
/// no sentence of its own — a bare `ok: false`, which is a bridge declining to
/// explain rather than a bridge that said nothing.
String sessionForkRefusalCopy(String? code, String? message) =>
    sessionRefusalCopy(code, message, 'Could not fork this session.');

void reportStartRefusal(
  AbToaster? toaster,
  SessionOperationException error,
) => reportSessionNotice(
  toaster,
  sessionStartRefusalCopy(error.errorCode, error.message),
);

/// Reports [message] about a session on [toaster]. Takes the toaster rather
/// than a context so a caller whose widget can be disposed mid-await captures
/// it before its first await: a session tap can dispose the row that fired it
/// (mobile pops the drawer, a cross-project switch rebuilds it), and an answer
/// the user asked for must not vanish with the widget.
void reportSessionNotice(AbToaster? toaster, String message) =>
    toaster?.showMessage(message, duration: const Duration(seconds: 8));
