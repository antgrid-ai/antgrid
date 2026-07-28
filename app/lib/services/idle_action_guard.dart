import 'dart:async';

/// Bounds a STREAMING tier-2 action by INACTIVITY, never by wall-clock.
///
/// A streamed operation (file:search) emits N result frames then a terminal
/// `*-done`; the UI flag it sets is cleared only by that done. If the send is
/// dropped (keyless relay window) or the session goes down mid-stream, the done
/// never arrives and the flag strands forever. A wall-clock cap is wrong here —
/// a large search legitimately streams for a while — so bound on SILENCE
/// instead: [poke] on every activity frame resets the idle clock, [settle] on
/// the terminal frame (or a supersede / dispose) ends [done] cleanly, and an
/// idle gap ends [done] with a [TimeoutException] so the caller's catch clears
/// the flag. The gap means "the reply that clears the flag is never coming",
/// not "the operation is taking too long".
class IdleActionGuard {
  final Duration idle;
  final _completer = Completer<void>();
  Timer? _timer;

  IdleActionGuard(this.idle) {
    _arm();
  }

  /// Completes normally on [settle]; completes with [TimeoutException] on an
  /// idle gap. Never both (guarded by the completer).
  Future<void> get done => _completer.future;

  /// Activity observed — reset the idle clock. No-op once ended.
  void poke() {
    if (_completer.isCompleted) return;
    _arm();
  }

  /// End cleanly: the terminal frame arrived, or the action was superseded /
  /// disposed. NOT a strand, so [done] resolves without error.
  void settle() {
    if (_completer.isCompleted) return;
    _timer?.cancel();
    _completer.complete();
  }

  void _arm() {
    _timer?.cancel();
    _timer = Timer(idle, () {
      if (_completer.isCompleted) return;
      _completer.completeError(
        TimeoutException('streaming action idle-timed out', idle),
      );
    });
  }
}
