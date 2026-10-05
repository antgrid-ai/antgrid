import 'dart:async';

/// Runs [request], then completes once [updates] has gone quiet — the reply to
/// a fire-and-forget refresh arrives as a burst of state changes, and the
/// pull-to-refresh spinner should last exactly that long.
///
/// Held for at least [minWait] so a refresh answered from cache does not flash
/// the spinner, and never beyond [maxWait] so a dropped reply cannot strand it.
/// [quiet] counts from the last update seen, or from the request itself while
/// none has arrived.
Future<void> settleAfter<T>(
  Stream<T> updates,
  void Function() request, {
  Duration minWait = const Duration(milliseconds: 300),
  Duration quiet = const Duration(milliseconds: 250),
  Duration maxWait = const Duration(seconds: 5),
}) {
  final done = Completer<void>();
  final started = Stopwatch()..start();
  Timer? quietTimer;
  late final StreamSubscription<T> sub;

  void finish() {
    if (done.isCompleted) return;
    quietTimer?.cancel();
    unawaited(sub.cancel());
    done.complete();
  }

  void armQuiet() {
    quietTimer?.cancel();
    final remainingMin = minWait - started.elapsed;
    final wait = remainingMin > quiet ? remainingMin : quiet;
    quietTimer = Timer(wait, finish);
  }

  sub = updates.listen((_) => armQuiet());
  Timer(maxWait, finish);
  armQuiet();
  request();
  return done.future;
}
