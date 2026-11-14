// Pins the conflict-first ordering a top-down read depends on and which
// affordance each input device gets: hover buttons on desktop, the swipe tray
// and long-press menu on touch.
import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/models/ab_message.dart';
import 'package:antgrid/models/git_status_index.dart';
import 'package:antgrid/widgets/git_change_list.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/hover.dart';

void main() {
  Finder action(String label) => find.byWidgetPredicate(
    (w) => w is CarbonButton && (w.semanticLabel ?? w.label) == label,
    description: 'CarbonButton "$label"',
  );

  Future<void> pumpGroup(
    WidgetTester tester,
    List<GitFileStatusEntry> entries, {
    List<String>? staged,
    List<String>? discarded,
    List<String>? resolved,
    List<String>? unstaged,
    List<String>? opened,
    Widget Function(Widget list)? wrap,
  }) async {
    final list = AbCarbonScope(
      child: CustomScrollView(
        slivers: [
          GitChangeGroupSliver(
            index: GitStatusIndex(entries),
            selectedPath: null,
            onOpen: (p) => opened?.add(p),
            onStage: (p) => staged?.add(p),
            onUnstage: (p) => unstaged?.add(p),
            onDiscard: (p) => discarded?.add(p),
            onResolve: (p) => resolved?.add(p),
          ),
        ],
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: wrap == null ? list : wrap(list)),
      ),
    );
    await tester.pump();
  }

  Future<void> onDesktop(Future<void> Function() body) async {
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  const entries = [
    GitFileStatusEntry(path: 'b.dart', status: 'M', staged: false),
    GitFileStatusEntry(path: 'A.dart', status: 'M', staged: false),
    GitFileStatusEntry(path: 'lib/z.dart', status: 'A', staged: false),
    GitFileStatusEntry(path: 'c.dart', status: '!', staged: false),
  ];

  testWidgets('conflicts sort first, the rest case-insensitively by path', (
    tester,
  ) async {
    await pumpGroup(tester, entries);

    final order = [
      for (final p in ['c.dart', 'A.dart', 'b.dart', 'lib/z.dart'])
        tester.getTopLeft(find.byKey(ValueKey(p))).dy,
    ];
    expect(order, [...order]..sort());
    expect(order.toSet(), hasLength(4));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a desktop row stages and discards from its hover buttons', (
    tester,
  ) async {
    await onDesktop(() async {
      final staged = <String>[];
      final discarded = <String>[];
      await pumpGroup(
        tester,
        const [GitFileStatusEntry(path: 'a.dart', status: 'M', staged: false)],
        staged: staged,
        discarded: discarded,
      );

      await hoverRow(tester, find.byKey(const ValueKey('a.dart')));
      await tester.tap(action('Stage Changes'));
      await tester.pump();
      await tester.tap(action('Discard Changes'));
      await tester.pump();

      expect(staged, ['a.dart']);
      expect(discarded, ['a.dart']);

      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets('a conflict row offers only Resolve', (tester) async {
    await onDesktop(() async {
      await pumpGroup(tester, const [
        GitFileStatusEntry(path: 'c.dart', status: '!', staged: false),
      ]);

      await hoverRow(tester, find.byKey(const ValueKey('c.dart')));

      expect(action('Mark Resolved'), findsOneWidget);
      expect(action('Stage Changes'), findsNothing);
      expect(action('Discard Changes'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets('a touch row has no hover buttons', (tester) async {
    await pumpGroup(tester, const [
      GitFileStatusEntry(path: 'a.dart', status: 'M', staged: false),
    ]);

    expect(action('Stage Changes'), findsNothing);
    expect(action('Discard Changes'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  group('touch swipe tray', () {
    const file = [
      GitFileStatusEntry(path: 'a.dart', status: 'M', staged: false),
    ];
    Finder row() => find.text('a.dart');

    Future<void> swipe(WidgetTester tester, double dx) async {
      await tester.timedDrag(
        row(),
        Offset(dx, 0),
        const Duration(milliseconds: 300),
      );
      await tester.pumpAndSettle();
    }

    Future<void> openTray(WidgetTester tester) => swipe(tester, -120);

    testWidgets('a swipe reveals both actions and Stage runs on tap', (
      tester,
    ) async {
      final staged = <String>[];
      await pumpGroup(tester, file, staged: staged);

      await openTray(tester);
      expect(find.text('Stage'), findsOneWidget);
      expect(find.text('Discard'), findsOneWidget);

      await tester.tap(find.text('Stage'));
      await tester.pumpAndSettle();
      expect(staged, ['a.dart']);
      expect(find.text('Stage'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a staged row offers Unstage in the same slot', (tester) async {
      final unstaged = <String>[];
      await pumpGroup(tester, const [
        GitFileStatusEntry(path: 'a.dart', status: 'M', staged: true),
      ], unstaged: unstaged);

      await openTray(tester);
      expect(find.text('Stage'), findsNothing);
      await tester.tap(find.text('Unstage'));
      await tester.pumpAndSettle();

      expect(unstaged, ['a.dart']);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Discard runs from the tray', (tester) async {
      final discarded = <String>[];
      await pumpGroup(tester, file, discarded: discarded);

      await openTray(tester);
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();

      expect(discarded, ['a.dart']);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a short swipe snaps back and runs nothing', (tester) async {
      final staged = <String>[];
      final discarded = <String>[];
      await pumpGroup(tester, file, staged: staged, discarded: discarded);

      await swipe(tester, -20);

      expect(staged, isEmpty);
      expect(discarded, isEmpty);
      expect(find.text('Stage'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a full swipe stages, and never discards', (tester) async {
      final staged = <String>[];
      final discarded = <String>[];
      await pumpGroup(tester, file, staged: staged, discarded: discarded);

      await swipe(tester, -780);

      expect(staged, ['a.dart']);
      expect(discarded, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a rightward swipe does nothing', (tester) async {
      final staged = <String>[];
      await pumpGroup(tester, file, staged: staged);

      await tester.fling(row(), const Offset(500, 0), 1200);
      await tester.pumpAndSettle();

      expect(staged, isEmpty);
      expect(find.text('Stage'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an open tray takes the row tap instead of opening the file', (
      tester,
    ) async {
      final opened = <String>[];
      await pumpGroup(tester, file, opened: opened);

      await openTray(tester);
      final rect = tester.getRect(find.byKey(const ValueKey('a.dart')));
      await tester.tapAt(Offset(rect.left + 40, rect.center.dy));
      await tester.pumpAndSettle();

      expect(opened, isEmpty);
      expect(find.text('Stage'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a tap on another row closes the open tray', (tester) async {
      final opened = <String>[];
      await pumpGroup(tester, const [
        GitFileStatusEntry(path: 'a.dart', status: 'M', staged: false),
        GitFileStatusEntry(path: 'b.dart', status: 'M', staged: false),
      ], opened: opened);

      await openTray(tester);
      expect(find.text('Stage'), findsOneWidget);

      await tester.tap(find.text('b.dart'));
      await tester.pumpAndSettle();

      expect(find.text('Stage'), findsNothing);
      expect(opened, ['b.dart']);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a conflicted row trays Resolve, and only Resolve', (
      tester,
    ) async {
      final staged = <String>[];
      final discarded = <String>[];
      final resolved = <String>[];
      await pumpGroup(
        tester,
        const [GitFileStatusEntry(path: 'a.dart', status: '!', staged: false)],
        staged: staged,
        discarded: discarded,
        resolved: resolved,
      );

      await openTray(tester);
      expect(find.text('Stage'), findsNothing);
      expect(find.text('Unstage'), findsNothing);
      expect(find.text('Discard'), findsNothing);

      await tester.tap(find.text('Resolve'));
      await tester.pumpAndSettle();

      expect(resolved, ['a.dart']);
      expect(staged, isEmpty);
      expect(discarded, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a row swipe beats the PageView the phone puts it in', (
      tester,
    ) async {
      final controller = PageController();
      addTearDown(controller.dispose);
      await pumpGroup(
        tester,
        file,
        wrap: (list) => PageView(
          controller: controller,
          children: [const SizedBox.expand(), list],
        ),
      );
      controller.jumpToPage(1);
      await tester.pumpAndSettle();

      await openTray(tester);

      expect(find.text('Stage'), findsOneWidget);
      expect(controller.page, 1, reason: 'the page must not slide back');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an untracked directory keeps the path git reported', (
      tester,
    ) async {
      final opened = <String>[];
      final staged = <String>[];
      await pumpGroup(
        tester,
        const [
          GitFileStatusEntry(
            path: 'assets/',
            status: 'U',
            staged: false,
            additions: 4,
          ),
        ],
        opened: opened,
        staged: staged,
      );

      expect(find.text('assets'), findsOneWidget);
      expect(find.text('+4'), findsOneWidget);

      await tester.tap(find.text('assets'));
      await tester.pumpAndSettle();
      expect(opened, ['assets/']);

      await tester.timedDrag(
        find.text('assets'),
        const Offset(-120, 0),
        const Duration(milliseconds: 300),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Stage'));
      await tester.pumpAndSettle();
      expect(staged, ['assets/']);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('long-press menu', () {
    testWidgets('an unstaged row offers Stage, Discard and Copy path', (
      tester,
    ) async {
      await pumpGroup(tester, const [
        GitFileStatusEntry(path: 'a.dart', status: 'M', staged: false),
      ]);

      await tester.longPress(find.text('a.dart'));
      await tester.pumpAndSettle();

      expect(find.text('Stage Changes'), findsOneWidget);
      expect(find.text('Discard Changes'), findsOneWidget);
      expect(find.text('Copy path'), findsOneWidget);
      expect(find.text('Unstage Changes'), findsNothing);
      expect(find.text('Mark Resolved'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a staged row offers Unstage rather than Stage', (
      tester,
    ) async {
      await pumpGroup(tester, const [
        GitFileStatusEntry(path: 'a.dart', status: 'M', staged: true),
      ]);

      await tester.longPress(find.text('a.dart'));
      await tester.pumpAndSettle();

      expect(find.text('Unstage Changes'), findsOneWidget);
      expect(find.text('Stage Changes'), findsNothing);
      expect(find.text('Discard Changes'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a conflict row offers only Mark Resolved and Copy path', (
      tester,
    ) async {
      await pumpGroup(tester, const [
        GitFileStatusEntry(path: 'a.dart', status: '!', staged: false),
      ]);

      await tester.longPress(find.text('a.dart'));
      await tester.pumpAndSettle();

      expect(find.text('Mark Resolved'), findsOneWidget);
      expect(find.text('Copy path'), findsOneWidget);
      expect(find.text('Stage Changes'), findsNothing);
      expect(find.text('Discard Changes'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });
  });
}
