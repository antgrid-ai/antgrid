import 'dart:async';

import 'ab_log.dart';

/// Starts [action] detached from the caller and reports a failure instead of
/// letting it escape.
///
/// A `void` callback — a tap handler, a post-frame callback, a `ref.listen` — is
/// the one place an async failure has nowhere to go: the future is discarded, so
/// a rejection lands on `PlatformDispatcher.onError` as a FATAL crash whose
/// stack holds no in-app frames at all. That is how a 15s
/// `session reply timed out` (a dropped frame on a flaky mobile link — routine,
/// and already reconciled by the next `session:updated`) killed the app instead
/// of leaving a stale row on screen.
///
/// [component] and [what] name the site in `app.log`. Use this at every such
/// boundary rather than a bare `unawaited`, so the next one can't ship
/// unguarded; where the user is owed more than a log line, catch the failure
/// inside [action] and say so in the UI.
void detached(String component, String what, Future<void> Function() action) {
  // Future.sync so a synchronous throw inside [action] is caught too — the
  // caller has no try/catch either.
  unawaited(
    Future<void>.sync(action).catchError((Object error, StackTrace stack) {
      // The stack is the only thing that names WHICH await inside [action]
      // failed — a detached action typically has several, and the log line
      // otherwise carries no site beyond [component].
      AbLog.error(
        component,
        what,
        fields: {'error': '$error', 'stack': '$stack'},
      );
    }),
  );
}
