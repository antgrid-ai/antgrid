/// Thins the wheel reports a touch swipe produces before they reach the PTY.
///
/// Under mouse reporting the terminal view turns every line-height of finger
/// travel into one wheel notch, but a full-screen agent scrolls several lines
/// per notch and animates each one, so the content ran ahead of the finger;
/// and since the notches cross the network, the ones still in flight kept it
/// moving after the finger stopped. Keeping one notch in [ratio] brings the
/// content back to roughly the finger's pace, and [minInterval] drops — never
/// queues — anything faster, so there is no backlog left to drain.
///
/// Only for touch-first platforms: there a wheel report comes from a swipe,
/// while on desktop it is a real wheel whose notches the user counted.
class TouchWheelLimiter {
  TouchWheelLimiter({
    this.ratio = 2,
    this.minInterval = const Duration(milliseconds: 30),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final int ratio;
  final Duration minInterval;
  final DateTime Function() _now;

  /// SGR (`CSI < b ; x ; y M|m`) and X10 (`CSI M b x y`) wheel reports. A
  /// wheel button is 64/65 plus modifier bits 4/8/16; X10 adds 32 to it.
  static final _sgr = RegExp(r'^\x1b\[<(\d+);\d+;\d+([Mm])$');
  static const _x10Prefix = '\x1b[M';

  /// A pause this long ends a swipe; the next notch starts a new one.
  static const _gestureGap = Duration(milliseconds: 250);

  bool? _lastUp;
  int _skipped = 0;
  DateTime? _lastSent;
  DateTime? _lastSeen;

  /// Whether the release paired with the last wheel press should go too.
  bool _forwardRelease = true;

  /// [data] unchanged, or null to drop it.
  String? filter(String data) {
    final wheel = _wheel(data);
    if (wheel == null) return data;
    if (!wheel.press) return _forwardRelease ? data : null;

    final now = _now();
    final seen = _lastSeen;
    _lastSeen = now;
    if (wheel.up != _lastUp ||
        seen == null ||
        now.difference(seen) >= _gestureGap) {
      // A reversal or a fresh swipe is a new intent: answer its first notch
      // at once, so the content moves the moment the finger does.
      _lastUp = wheel.up;
      _skipped = ratio - 1;
    }
    final last = _lastSent;
    final tooSoon = last != null && now.difference(last) < minInterval;
    if (++_skipped < ratio || tooSoon) {
      _forwardRelease = false;
      return null;
    }
    _skipped = 0;
    _lastSent = now;
    _forwardRelease = true;
    return data;
  }

  ({bool up, bool press})? _wheel(String data) {
    // Both report forms open with CSI; most traffic is plain keystrokes.
    if (!data.startsWith('\x1b[')) return null;
    final sgr = _sgr.firstMatch(data);
    if (sgr != null) {
      final button = int.parse(sgr.group(1)!);
      if (button & 64 == 0 || button & 128 != 0 || button & 3 > 1) return null;
      return (up: button & 1 == 0, press: sgr.group(2) == 'M');
    }
    if (data.length == 6 && data.startsWith(_x10Prefix)) {
      final button = data.codeUnitAt(3) - 32;
      if (button < 0 || button & 64 == 0 || button & 3 > 1) return null;
      // X10 reports no wheel release.
      return (up: button & 1 == 0, press: true);
    }
    return null;
  }
}
