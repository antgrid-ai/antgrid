import 'dart:async';

import 'package:flutter/widgets.dart';

import '../design/ab_tokens.dart';
import 'transcript/format.dart';

/// How long the terminal's outstanding wait has been going, ticking once a
/// second.
///
/// Its own widget purely for the ticker: a rebuild every second is cheap in a
/// leaf and ruinous one level up, where it would reach the live terminal
/// beside it.
///
/// [startedAtMs] is stamped against whichever clock issued the pull, and for a
/// remote machine that is not ours. A reading that comes out negative is the
/// one shape of skew that is detectable, and it is answered by saying nothing
/// — an elapsed time is orientation, and a wrong one is worse than none.
class TerminalElapsed extends StatefulWidget {
  const TerminalElapsed({
    super.key,
    required this.startedAtMs,
    required this.color,
  });

  final int startedAtMs;
  final Color color;

  @override
  State<TerminalElapsed> createState() => _TerminalElapsedState();
}

class _TerminalElapsedState extends State<TerminalElapsed> {
  Timer? _timer;

  // Accumulated on ticks and seeded once from the stamp, rather than re-read
  // from DateTime.now() in build — FakeAsync advances timers but not the wall
  // clock, so a now()-derived label freezes in widget tests and proves nothing.
  late Duration _elapsed = _seed();

  Duration _seed() => Duration(
    milliseconds: DateTime.now().millisecondsSinceEpoch - widget.startedAtMs,
  );

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        final ticked = _elapsed + const Duration(seconds: 1);
        // The LARGER of the tick count and the wall clock. Timers are
        // suspended while the app is backgrounded, so ticks alone under-report
        // a wait the user sat through off screen — the "2s to someone who
        // waited forty" reading this readout exists to prevent. Not the wall
        // clock outright: FakeAsync advances timers without moving it, so a
        // now()-only value freezes in widget tests.
        final wall = _seed();
        _elapsed = wall > ticked ? wall : ticked;
      });
    });
  }

  @override
  void didUpdateWidget(TerminalElapsed oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Terminal panes mount unkeyed and reuse this State across tab swaps, so a
    // fresh stamp has to restart the count instead of inheriting the last one's.
    if (widget.startedAtMs != oldWidget.startedAtMs) {
      _elapsed = _seed();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.startedAtMs <= 0 || _elapsed.isNegative) {
      return const SizedBox.shrink();
    }
    return Text(
      // The app's one elapsed format, shared with the agent transcript's own
      // "Working for 2m 35s" — two live readouts of the same seconds must not
      // disagree about how to spell them.
      formatDuration(_elapsed),
      style: AbTokens.sansStyle(
        fontSize: AbTokens.fontXxs,
        color: widget.color,
      ),
    );
  }
}
