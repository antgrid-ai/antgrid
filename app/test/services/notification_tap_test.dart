// The two platform gates around the OS tap entry points. Neither is reachable
// from a widget test — one registers a plugin callback, the other runs before
// the first frame — so without this they are deletable with every gate green,
// and each deletion is a silent field bug: a double-delivered Android tap, or a
// launch-details call that throws on Linux and replays itself on Windows.
import 'package:antgrid/services/notification_tap.dart';
import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the push tap is registered on iOS alone', () {
    for (final p in TargetPlatform.values) {
      expect(
        pushTapRegistrationSupported(p),
        p == TargetPlatform.iOS,
        reason: '$p',
      );
    }
  });

  test('launch details are read everywhere fln implements them', () {
    expect(launchDetailsSupported(TargetPlatform.iOS), isTrue);
    expect(launchDetailsSupported(TargetPlatform.android), isTrue);
    expect(launchDetailsSupported(TargetPlatform.macOS), isTrue);
    // The two that misbehave rather than merely lack a branch: Linux throws
    // UnimplementedError, Windows replays a tap it already delivered.
    expect(launchDetailsSupported(TargetPlatform.linux), isFalse);
    expect(launchDetailsSupported(TargetPlatform.windows), isFalse);
    expect(launchDetailsSupported(TargetPlatform.fuchsia), isFalse);
  });
}
