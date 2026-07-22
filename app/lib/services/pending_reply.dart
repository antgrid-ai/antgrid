import 'dart:async';

/// One in-flight request/reply pair, bounded by a hard timeout.
///
/// Every service that sends a wire message and awaits a matching reply needs
/// the same three guarantees: a lost reply (silent transport drop
/// pre-establish, agent gone mid-request) fails the pending future instead of
/// hanging the awaiting UI forever; [onTimeout] runs BEFORE the failure so the
/// owning field/map is de-registered and a late reply can't complete a dead
/// entry; and teardown can [fail] whatever is still pending. One implementation
/// is what stops the next request path from shipping with no timer at all.
class PendingReply<T> {
  final Completer<T> _completer = Completer<T>();
  late final Timer _timer;

  /// [timeoutError] overrides the failure value for services with a typed
  /// error contract (e.g. upload's `UploadException`); the default is a
  /// [TimeoutException].
  PendingReply({
    required Duration timeout,
    void Function()? onTimeout,
    Object Function()? timeoutError,
  }) {
    _timer = Timer(timeout, () {
      if (_completer.isCompleted) return;
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
    _completer.completeError(error);
  }
}
