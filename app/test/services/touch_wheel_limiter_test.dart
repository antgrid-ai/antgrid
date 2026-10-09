import 'package:antgrid/services/touch_wheel_limiter.dart';
import 'package:flutter_test/flutter_test.dart';

const _upPress = '\x1b[<64;10;5M';
const _upRelease = '\x1b[<64;10;5m';
const _downPress = '\x1b[<65;10;5M';
const _downRelease = '\x1b[<65;10;5m';

void main() {
  late DateTime clock;
  late TouchWheelLimiter limiter;

  setUp(() {
    clock = DateTime(2026);
    limiter = TouchWheelLimiter(now: () => clock);
  });

  /// One swipe's notches, [gapMs] apart; returns the presses that went out.
  int swipe(int notches, {String press = _upPress, int gapMs = 50}) {
    var sent = 0;
    final release = press == _upPress ? _upRelease : _downRelease;
    for (var i = 0; i < notches; i++) {
      if (limiter.filter(press) != null) sent++;
      limiter.filter(release);
      clock = clock.add(Duration(milliseconds: gapMs));
    }
    return sent;
  }

  test('passes everything that is not a wheel report', () {
    for (final data in ['a', '\r', '\x1b[A', '\x1b[<0;3;4M', '\x1b[<0;3;4m']) {
      expect(limiter.filter(data), data);
    }
  });

  test('answers the first notch of a swipe at once', () {
    expect(limiter.filter(_upPress), _upPress);
    expect(limiter.filter(_upRelease), _upRelease);
  });

  test('keeps one notch in two during a swipe', () {
    expect(swipe(9), 5);
  });

  test('drops the release of a dropped press', () {
    limiter.filter(_upPress);
    limiter.filter(_upRelease);
    clock = clock.add(const Duration(milliseconds: 50));
    expect(limiter.filter(_upPress), isNull);
    expect(limiter.filter(_upRelease), isNull);
  });

  test('a fast flick is capped rather than queued', () {
    // 30 notches in 150ms: the ratio alone would send 15.
    expect(swipe(30, gapMs: 5), lessThanOrEqualTo(6));
  });

  test('a reversal answers its first notch at once', () {
    swipe(2);
    expect(limiter.filter(_downPress), _downPress);
  });

  test('a pause starts a fresh swipe', () {
    swipe(2);
    clock = clock.add(const Duration(milliseconds: 300));
    expect(limiter.filter(_upPress), _upPress);
  });

  test('understands modifier bits and X10 reports', () {
    // Shift+wheel-down, SGR.
    expect(limiter.filter('\x1b[<69;1;1M'), isNotNull);
    clock = clock.add(const Duration(milliseconds: 50));
    expect(limiter.filter('\x1b[<69;1;1M'), isNull);
    // X10 wheel-up: button 64 + 32.
    final x10 = '\x1b[M${String.fromCharCode(96)}!!';
    clock = clock.add(const Duration(milliseconds: 300));
    expect(limiter.filter(x10), x10);
    clock = clock.add(const Duration(milliseconds: 50));
    expect(limiter.filter(x10), isNull);
  });
}
