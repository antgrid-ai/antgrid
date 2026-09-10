// The elapsed readout beside an attaching terminal. Both cases guard a
// property the widget could lose without any visible change in the app: that
// the count comes from its own ticker, and that it refuses a clock it cannot
// trust.
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/widgets/terminal_elapsed.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(WidgetTester tester, int startedAtMs) => tester.pumpWidget(
  Directionality(
    textDirection: TextDirection.ltr,
    child: TerminalElapsed(
      startedAtMs: startedAtMs,
      color: kDefaultPalette.textMuted,
    ),
  ),
);

/// The seconds the label is showing. Under a minute `formatDuration` spells the
/// reading `45s`, which is the only range these cases run in.
int _seconds(WidgetTester tester) {
  final label = tester.widget<Text>(find.byType(Text)).data!;
  return int.parse(label.substring(0, label.length - 1));
}

void main() {
  testWidgets('the reading advances on ticks, not on the wall clock', (
    tester,
  ) async {
    // FakeAsync moves timers and leaves the wall clock where it is, so a label
    // derived from DateTime.now() in build would sit unchanged through all of
    // this. Advancing by exactly the ticks spent is the whole assertion.
    await _pump(tester, DateTime.now().millisecondsSinceEpoch - 5000);
    final before = _seconds(tester);

    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(seconds: 1));
    }

    expect(_seconds(tester), before + 3);

    // Unmounted by hand: the ticker is periodic, and a test that ends with one
    // pending fails the suite rather than this expectation.
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('says nothing about a clock it cannot trust', (tester) async {
    // The stamp can come from a remote machine. A reading that comes out
    // negative is the one shape of skew that is detectable.
    await _pump(tester, DateTime.now().millisecondsSinceEpoch + 600000);

    expect(find.byType(Text), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
