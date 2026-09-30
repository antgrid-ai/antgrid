import 'package:flutter/widgets.dart';

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
  BuildContext context,
  SessionOperationException error,
) => reportSessionNotice(
  context,
  sessionStartRefusalCopy(error.errorCode, error.message),
);

/// [reportStartRefusal] for a caller holding the root navigator's
/// [OverlayState] directly — see [reportSessionNoticeOn]'s doc for why.
void reportStartRefusalOn(
  OverlayState overlay,
  SessionOperationException error,
) => reportSessionNoticeOn(
  overlay,
  sessionStartRefusalCopy(error.errorCode, error.message),
);

/// Reports [message] about a session on the root navigator's OVERLAY rather
/// than [context]'s own: a session tap can dispose the row that fired it
/// (mobile pops the drawer, a cross-project switch rebuilds it), and an answer
/// the user asked for must not vanish with the widget. Same reason
/// `recent_session_row_widget.dart`'s onTap hands `openRecentSession` the
/// navigator's context. Falls back to [context] where there is no Navigator
/// (widget tests).
void reportSessionNotice(BuildContext context, String message) {
  final overlay = Navigator.maybeOf(context, rootNavigator: true)?.overlay;
  if (overlay != null && overlay.mounted) {
    reportSessionNoticeOn(overlay, message);
    return;
  }
  if (context.mounted) {
    showAbToast(context, message, duration: const Duration(seconds: 8));
  }
}

/// [reportSessionNotice] for a caller already holding the [OverlayState].
///
/// A `NavigatorState`'s own `context` sits ABOVE the Overlay it owns (the
/// Overlay is built as the Navigator's CHILD), so `Overlay.maybeOf` on that
/// context finds nothing — this was the actual bug behind a "reported" toast
/// that never rendered. Go through the `OverlayState` itself instead, which
/// has no such ambiguity and is exactly as durable.
void reportSessionNoticeOn(OverlayState overlay, String message) {
  if (!overlay.mounted) return;
  showAbToastForOverlay(overlay, message, duration: const Duration(seconds: 8));
}
