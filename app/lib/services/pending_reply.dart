import 'dart:async';

/// One in-flight request/reply pair, bounded by a hard timeout.
///
/// Every service that sends a wire message and awaits a matching reply needs
/// the same three guarantees: a lost reply (silent transport drop
/// pre-establish, agent gone mid-request) fails the pending future instead of
/// hanging the awaiting UI forever; [onAbandon] runs BEFORE the failure so the
/// owning field/map is de-registered and a late reply can't complete a dead
/// entry; and teardown can [fail] whatever is still pending. One implementation
/// is what stops the next request path from shipping with no timer at all.
class PendingReply<T> {
  final Completer<T> _completer = Completer<T>();
  late final Timer _timer;
  final void Function()? _onAbandon;

  /// [onAbandon] runs on ANY abnormal completion — a timeout, or an explicit
  /// [fail] (including one driven by `ProjectSession`'s down/up registry, not
  /// just this reply's own owner). It is normally the map/field de-registration
  /// every service needs, and must be idempotent: a caller that has already
  /// removed the entry itself (e.g. on the success path) may see it run again.
  ///
  /// [onTimeout] runs ONLY when the hard timeout elapses, strictly for a side
  /// effect that must never fire on a session-down fail — a state notifier
  /// stamping timeout-specific copy, or bookkeeping (retry counters, a cancel
  /// frame) that only makes sense against a reply nothing will ever answer, not
  /// one abandoned because the whole channel just went down.
  ///
  /// [timeoutError] overrides the failure value for services with a typed
  /// error contract (e.g. upload's `UploadException`); the default is a
  /// [TimeoutException].
  PendingReply({
    required Duration timeout,
    void Function()? onTimeout,
    void Function()? onAbandon,
    Object Function()? timeoutError,
  }) : _onAbandon = onAbandon {
    _timer = Timer(timeout, () {
      if (_completer.isCompleted) return;
      _onAbandon?.call();
      onTimeout?.call();
      _completer.completeError(
        timeoutError?.call() ??
            TimeoutException('No reply from the agent', timeout),
      );
    });
  }

  Future<T> get future => _completer.future;
  bool get isCompleted => _completer.isCompleted;

  void complete(T value) {
    if (_completer.isCompleted) return;
    _timer.cancel();
    _completer.complete(value);
  }

  void fail(Object error) {
    if (_completer.isCompleted) return;
    _timer.cancel();
    _onAbandon?.call();
    _completer.completeError(error);
  }
}

/// Raised by `ProjectSession.newPending`'s registry when the transport
/// carrying this project has gone down — a local socket close, or a relay
/// stream/machine session drop — so a tracked reply fails immediately instead
/// of waiting out its own timeout against a channel nothing will ever answer
/// on. Interpolated straight into user-facing copy (the sessions-load banner
/// in `workspace_shell.dart`), so [toString] must read as a sentence.
class SessionDownException implements Exception {
  const SessionDownException();

  @override
  String toString() => 'The connection to the machine dropped. Reconnecting.';
}
