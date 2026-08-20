// The tray is the only per-file affordance on a touch device, so its guards
// carry the whole weight of "the user meant this": a slip during a scroll, a
// second row already open, a list that moves under an open one.
import 'package:antgrid/design/ab_icons.dart';
import 'package:antgrid/design/widgets/ab_swipe_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<String> invoked;

  setUp(() => invoked = []);

  AbSwipeAction action(String label, {bool destructive = false}) =>
      AbSwipeAction(
        icon: destructive ? AbIcons.revert : AbIcons.gitStage,
        label: label,
        color: const Color(0xFF00FF00),
        destructive: destructive,
        onInvoke: () => invoked.add(label),
      );

  Widget rowsUnderTest({
    int rows = 1,
    bool destructiveFirst = false,
    double width = 800,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: width,
          child: ListView(
            children: [
              for (var i = 0; i < rows; i++)
                AbSwipeActions(
                  key: ValueKey(i),
                  actions: destructiveFirst
                      ? [action('Revert', destructive: true)]
                      : [action('Stage'), action('Revert', destructive: true)],
                  child: SizedBox(height: 48, child: Text('row $i')),
                ),
              // Tall filler so the list can actually scroll.
              const SizedBox(height: 2000),
            ],
          ),
        ),
      ),
    );
  }

  testWidgets('a drag short of the threshold snaps back', (tester) async {
    await tester.pumpWidget(rowsUnderTest());

    await tester.drag(find.text('row 0'), const Offset(-24, 0));
    await tester.pumpAndSettle();

    expect(find.text('Stage'), findsNothing);
    expect(invoked, isEmpty);
  });

  testWidgets('a drag past the threshold latches the tray open', (
    tester,
  ) async {
    await tester.pumpWidget(rowsUnderTest());

    await tester.drag(find.text('row 0'), const Offset(-120, 0));
    await tester.pumpAndSettle();

    // Open, and still open — revealing actions never runs one.
    expect(find.text('Stage'), findsOneWidget);
    expect(find.text('Revert'), findsOneWidget);
    expect(invoked, isEmpty);
  });

  testWidgets('a leftward flick opens the tray without the distance', (
    tester,
  ) async {
    await tester.pumpWidget(rowsUnderTest());

    // Short of the distance threshold on purpose: only the velocity rule can
    // open the tray from here.
    await tester.fling(find.text('row 0'), const Offset(-60, 0), 2000);
    await tester.pumpAndSettle();

    expect(find.text('Stage'), findsOneWidget);
    expect(invoked, isEmpty);
  });

  // A destructive first action forfeits the shortcut: a gesture that runs off
  // the end of the row is far too easy to produce to be allowed to delete
  // anything.
  testWidgets('a full swipe never runs a destructive first action', (
    tester,
  ) async {
    await tester.pumpWidget(rowsUnderTest(destructiveFirst: true));

    await tester.drag(find.text('row 0'), const Offset(-780, 0));
    await tester.pumpAndSettle();

    expect(invoked, isEmpty);
    // It opened the tray instead, so the action is still one tap away.
    expect(find.text('Revert'), findsOneWidget);
  });

  // The git pane is a quarter of a tablet. A fixed-width tray took more of a
  // row that narrow than the full-swipe threshold did, so every attempt to
  // reveal the actions armed the shortcut instead: one stretched cell, the
  // second action unreachable, and a release that staged the file.
  testWidgets('a narrow row shows every action and arms nothing', (
    tester,
  ) async {
    await tester.pumpWidget(rowsUnderTest(width: 275));

    await tester.drag(find.text('row 0'), const Offset(-120, 0));
    await tester.pumpAndSettle();

    expect(find.text('Stage'), findsOneWidget);
    expect(find.text('Revert'), findsOneWidget);
    expect(invoked, isEmpty);
    // …and the tray still leaves the row itself readable.
    expect(
      tester.getSize(find.text('Stage')).width +
          tester.getSize(find.text('Revert')).width,
      lessThan(275 / 2),
    );
  });

  testWidgets('opening one tray closes the other', (tester) async {
    await tester.pumpWidget(rowsUnderTest(rows: 2));

    await tester.drag(find.text('row 0'), const Offset(-120, 0));
    await tester.pumpAndSettle();
    expect(find.text('Stage'), findsOneWidget);

    await tester.drag(find.text('row 1'), const Offset(-120, 0));
    await tester.pumpAndSettle();

    // One tray, not two — the second row's.
    expect(find.text('Stage'), findsOneWidget);
    expect(
      tester.getRect(find.text('row 1')).left,
      lessThan(tester.getRect(find.text('row 0')).left),
    );
  });

  testWidgets('closeAny closes the open tray', (tester) async {
    await tester.pumpWidget(rowsUnderTest());

    await tester.drag(find.text('row 0'), const Offset(-120, 0));
    await tester.pumpAndSettle();
    expect(find.text('Stage'), findsOneWidget);

    AbSwipeActions.closeAny();
    await tester.pumpAndSettle();

    expect(find.text('Stage'), findsNothing);
  });

  // [build] returns the bare child once a row has nothing left to swipe to,
  // which takes the tray's own close gestures with it — so a tray left latched
  // at that moment could never be closed again. A row's actions CAN empty
  // under an open tray: a file turning conflicted drops stage/unstage/discard
  // while its ValueKey keeps the State alive.
  testWidgets('emptying the actions releases an open tray', (tester) async {
    Widget build(List<AbSwipeAction> actions) => MaterialApp(
      home: Scaffold(
        body: AbSwipeActions(
          actions: actions,
          child: const SizedBox(height: 48, child: Text('row')),
        ),
      ),
    );

    await tester.pumpWidget(build([action('Stage')]));
    await tester.drag(find.text('row'), const Offset(-120, 0));
    await tester.pumpAndSettle();
    expect(find.text('Stage'), findsOneWidget);

    await tester.pumpWidget(build(const []));
    await tester.pumpAndSettle();

    expect(find.text('Stage'), findsNothing);
    // Undisplaced too, or the row would come back mid-swipe if its actions did.
    expect(tester.getRect(find.text('row')).left, 0);

    // And unlatched: actions coming back must not bring the tray with them.
    await tester.pumpWidget(build([action('Stage')]));
    await tester.pumpAndSettle();
    expect(find.text('Stage'), findsNothing);
    expect(tester.getRect(find.text('row')).left, 0);
  });

  // The vertical drag has to reach the list, or a tray would open every time a
  // thumb drifted sideways while scrolling.
  testWidgets('a vertical drag scrolls the list and opens nothing', (
    tester,
  ) async {
    await tester.pumpWidget(rowsUnderTest(rows: 2));
    final before = tester.getRect(find.text('row 0')).top;

    await tester.drag(find.text('row 0'), const Offset(-12, -60));
    await tester.pumpAndSettle();

    expect(find.text('Stage'), findsNothing);
    expect(tester.getRect(find.text('row 0')).top, lessThan(before));
  });
}
