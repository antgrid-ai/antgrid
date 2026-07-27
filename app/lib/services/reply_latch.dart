import 'dart:async';

/// Bridges a single-reply verb to the tier-2 [AgentTransport.action]
/// wall-clock timeout.
///
/// A one-shot verb (git:list-branches, git:checkout, git:diff) sets a loading
/// flag on send and clears it only when its ONE terminal reply lands. If that
/// send is dropped (keyless relay window) or the session drops before the reply,
/// the reply never comes and the flag strands. Pass [done] to
/// `session.action(() => latch.done, timeout: ...)`: [settle] on the reply (or a
/// supersede / dispose) resolves it cleanly and cancels the action's timer; if
/// the timeout fires first the action future errors and the caller clears the
/// flag.
///
/// Unlike [IdleActionGuard] this is a WALL-CLOCK bound — correct here because
/// these verbs reply exactly once and quickly; they never stream N frames the
/// way file:search / command:run do.
class ReplyLatch {
  final _completer = Completer<void>();

  /// Resolves only on [settle]; the tier-2 action owns the timeout. Never
  /// completes with an error itself.
  Future<void> get done => _completer.future;

  /// The reply arrived, or the action was superseded / disposed. No-op once
  /// settled, so double-settle (reply then dispose) is safe.
  void settle() {
    if (_completer.isCompleted) return;
    _completer.complete();
  }
}
