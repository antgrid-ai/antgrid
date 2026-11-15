// The agent bar's fifth control: the menu into the workspace views.
//
// It renders off a published WorkspaceMenuControl rather than reading panel
// state directly, so these pump the button against a hand-made control — the
// shell's end of that contract is covered in
// test/screens/workspace_floating_card_test.dart.
//
// A mouse desktop and a touch tablet share the SAME popup, with the SAME tap
// behaviour (see the button's own doc) — the tablet's context panel is a
// docked pane beside the agent, not an overlay covering it, so the two no
// longer compete for space, and a tap never takes a side-effecting shortcut
// on the pane; it only ever shows/hides the popup, on every platform. Flutter's
// test binding defaults defaultTargetPlatform to android with no override, so
// the desktop-popup tests below pin `windows` explicitly — they are about the
// POPUP's mechanics, not the platform default — and the touch group at the
// bottom exercises the unpinned (touch) default deliberately, to confirm
// there is no platform-specific path left to regress.
import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/design/widgets/ab_icon_button.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/providers/visible_surface.dart';
import 'package:antgrid/widgets/carbon_diff_stat.dart';
import 'package:antgrid/widgets/workspace_menu_button.dart';
import 'package:antgrid/widgets/workspace_tab_bar.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required WorkspaceMenuControl? control,
  Map<WorkspaceView, int> badges = const {},
  GitDiffTotals gitTotals = (additions: 0, deletions: 0),
  Widget? behind,
}) async {
  final container = ProviderContainer(
    overrides: [
      workspaceMenuControlProvider.overrideWith(() => ValueController(control)),
      workspaceBadgesProvider.overrideWith((ref) => badges),
      // Every tab on offer: these pin the menu's rows, not which tabs a
      // session offers (see visible_workspace_views_test.dart).
      visibleWorkspaceViewsProvider.overrideWithBuild(
        (_, _) => WorkspaceView.values,
      ),
      gitDiffTotalsProvider.overrideWith((ref) => gitTotals),
      workspaceMenuOpenProvider.overrideWith(() => ValueController(true)),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              ?behind,
              const Align(
                alignment: Alignment.topRight,
                child: WorkspaceMenuButton(),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return container;
}

CarbonButton _button(WidgetTester tester) =>
    tester.widget<CarbonButton>(find.byKey(WorkspaceMenuButton.buttonKey));

/// One row's rendered height, found by its label.
double _rowHeight(WidgetTester tester, String label) => tester
    .getSize(
      find
          .ancestor(of: find.text(label), matching: find.byType(CarbonSideNavLink))
          .first,
    )
    .height;

/// A no-op `reveal`-carrying control, so every test below only has to name
/// the field it actually cares about.
WorkspaceMenuControl _control({
  WorkspaceView? active,
  void Function(WorkspaceView)? reveal,
}) => (active: active, reveal: reveal ?? (_) {});

void main() {
  // ── Mouse desktop: the popup ──────────────────────────────────────────
  group('desktop popup', () {
    Future<void> runDesktop(
      WidgetTester tester,
      Future<void> Function() body,
    ) async {
      try {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        await body();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }

    testWidgets('renders nothing when no workspace is published', (
      tester,
    ) async {
      await runDesktop(tester, () async {
        await _pump(tester, control: null);
        expect(find.byKey(WorkspaceMenuButton.buttonKey), findsNothing);
      });
    });

    // Open from the first frame a workspace exists — no click to get here.
    testWidgets('lists every workspace view, unprompted', (tester) async {
      await runDesktop(tester, () async {
        final container = await _pump(tester, control: _control());

        expect(_button(tester).selected, isTrue);
        for (final view in container.read(visibleWorkspaceViewsProvider)) {
          expect(find.text(view.label), findsOneWidget, reason: view.label);
        }
      });
    });

    // The rail is pinned: nothing in it dismisses itself, so picking a view
    // leaves it standing and the user can pick again. In the app the shell
    // takes it away as the pane it just opened arrives — but that is the
    // shell's doing, covered in test/screens/workspace_menu_docking_test.dart.
    testWidgets('picking a view reveals it and leaves the rail up', (
      tester,
    ) async {
      await runDesktop(tester, () async {
        final revealed = <WorkspaceView>[];
        await _pump(tester, control: _control(reveal: revealed.add));

        await tester.tap(find.text('Git'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Files'));
        await tester.pumpAndSettle();

        expect(revealed, [WorkspaceView.git, WorkspaceView.files]);
        expect(find.text('Terminals'), findsOneWidget);
      });
    });

    // Pinned over the transcript, so the panel must hold its own surface and
    // border.
    testWidgets('is a bordered layer surface in its own Carbon scope', (
      tester,
    ) async {
      await runDesktop(tester, () async {
        await _pump(tester, control: _control());

        expect(
          find.descendant(
            of: find.byType(WorkspaceMenuPanel),
            matching: find.byType(AbCarbonScope),
          ),
          findsOneWidget,
        );
        final surface = tester.widget<DecoratedBox>(
          find
              .descendant(
                of: find.byType(WorkspaceMenuPanel),
                matching: find.byType(DecoratedBox),
              )
              .first,
        );
        final decoration = surface.decoration as BoxDecoration;
        final theme = CarbonTheme.of(
          tester.element(find.byType(CarbonSideNavLink).first),
        );
        expect(decoration.color, theme.colors.layer01);
        expect(decoration.border, isNotNull);
      });
    });

    // Side-nav rows: 32 tall on a pointer.
    testWidgets('rows are compact on a pointer', (tester) async {
      await runDesktop(tester, () async {
        await _pump(tester, control: _control());

        expect(_rowHeight(tester, 'Git'), 32);
      });
    });

    // The rail is as wide as its longest row and no wider. It used to be laid
    // out at a width fixed for the widest row it could EVER hold — the Git
    // row's whole-worktree `+N -M` — which left two thirds of it empty every
    // other time.
    testWidgets('is as wide as its content, not a reserved width', (
      tester,
    ) async {
      await runDesktop(tester, () async {
        await _pump(tester, control: _control());

        final panel = tester.getRect(find.byType(WorkspaceMenuPanel));
        final longest = tester.getRect(find.text('Terminals'));
        expect(panel.right - longest.right, lessThan(24));
      });
    });

    // The whole point of dropping the popup ROUTE: a click meant for the
    // agent beneath the menu has to reach it, and take nothing away on the
    // way past.
    testWidgets('a click outside neither closes the menu nor is swallowed', (
      tester,
    ) async {
      await runDesktop(tester, () async {
        var behindTaps = 0;
        await _pump(
          tester,
          control: _control(),
          behind: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => behindTaps++,
            child: const SizedBox.expand(),
          ),
        );

        // Bottom-left corner: clear of both the trailing icon and the panel
        // it drops beneath it.
        await tester.tapAt(const Offset(20, 560));
        await tester.pumpAndSettle();

        expect(behindTaps, 1);
        expect(find.text('Terminals'), findsOneWidget);
      });
    });

    testWidgets(
      'the icon is the only thing that shuts it, and shows it is on',
      (tester) async {
        await runDesktop(tester, () async {
          await _pump(tester, control: _control());

          expect(find.text('Terminals'), findsOneWidget);
          expect(_button(tester).selected, isTrue);

          await tester.tap(find.byKey(WorkspaceMenuButton.buttonKey));
          await tester.pumpAndSettle();

          expect(find.text('Terminals'), findsNothing);
          expect(_button(tester).selected, isFalse);

          await tester.tap(find.byKey(WorkspaceMenuButton.buttonKey));
          await tester.pumpAndSettle();

          expect(find.text('Terminals'), findsOneWidget);
          expect(_button(tester).selected, isTrue);
        });
      },
    );

    // Revealing a view replaces the agent panel, which unmounts this button —
    // exactly the round trip that used to lose the menu. It has to come back
    // with it, still open, or every use of the menu quietly closes it.
    testWidgets('the menu returns with the button that carries it', (
      tester,
    ) async {
      await runDesktop(tester, () async {
        final container = await _pump(tester, control: _control());

        container.read(workspaceMenuControlProvider.notifier).set(null);
        await tester.pumpAndSettle();
        expect(find.text('Terminals'), findsNothing);

        container.read(workspaceMenuControlProvider.notifier).set(_control());
        await tester.pumpAndSettle();

        expect(find.text('Terminals'), findsOneWidget);
        expect(_button(tester).selected, isTrue);
      });
    });

    // ...but a menu the user closed stays closed through the same round trip.
    testWidgets('a closed menu is not reopened by the round trip', (
      tester,
    ) async {
      await runDesktop(tester, () async {
        final container = await _pump(tester, control: _control());

        await tester.tap(find.byKey(WorkspaceMenuButton.buttonKey));
        await tester.pumpAndSettle();

        container.read(workspaceMenuControlProvider.notifier).set(null);
        await tester.pumpAndSettle();
        container.read(workspaceMenuControlProvider.notifier).set(_control());
        await tester.pumpAndSettle();

        expect(find.text('Terminals'), findsNothing);
        expect(_button(tester).selected, isFalse);
      });
    });

    // Asserted through the row's semantics rather than its widget, because
    // that is the half a screen reader gets: the row excludes its own subtree,
    // so the label and the selected state are stated on the row or nowhere.
    testWidgets('marks the view already on screen', (tester) async {
      await runDesktop(tester, () async {
        final handle = tester.ensureSemantics();
        try {
          await _pump(tester, control: _control(active: WorkspaceView.preview));

          expect(
            tester.getSemantics(find.text('Preview')),
            isSemantics(label: 'Preview', isSelected: true, hasTapAction: true),
          );
          expect(
            tester.getSemantics(find.text('Git')),
            isSemantics(label: 'Git', isSelected: false, hasTapAction: true),
          );
        } finally {
          handle.dispose();
        }
      });
    });

    // The bare figure would announce as a stray digit after the name.
    testWidgets("speaks a row's count as part of its name", (tester) async {
      await runDesktop(tester, () async {
        final handle = tester.ensureSemantics();
        try {
          await _pump(
            tester,
            control: _control(),
            badges: const {WorkspaceView.handler: 2},
          );

          expect(find.bySemanticsLabel('Handler, 2'), findsOneWidget);
          expect(find.bySemanticsLabel('2'), findsNothing);
        } finally {
          handle.dispose();
        }
      });
    });

    // The menu and the tab strip both count the same things; a menu that
    // stayed silent about three changed files would send the user to the
    // panel to find out whether there was anything there.
    testWidgets('carries the same badge counts as the tab strip', (
      tester,
    ) async {
      await runDesktop(tester, () async {
        await _pump(
          tester,
          control: _control(),
          badges: const {WorkspaceView.git: 3, WorkspaceView.handler: 120},
        );

        expect(find.text('3'), findsOneWidget);
        // Capped exactly as WorkspaceTabBar caps it.
        expect(find.text('99+'), findsOneWidget);
      });
    });

    // How much changed is what the Git row is read for, and the row has space
    // for one trailing figure — so the +/- takes the count's slot rather than
    // sitting beside it.
    testWidgets('the Git row trades its count for the worktree +/-', (
      tester,
    ) async {
      await runDesktop(tester, () async {
        await _pump(
          tester,
          control: _control(),
          badges: const {WorkspaceView.git: 3, WorkspaceView.handler: 2},
          gitTotals: (additions: 2728, deletions: 494),
        );

        expect(find.text('+2,728'), findsOneWidget);
        expect(find.text('${CarbonDiffStat.minus}494'), findsOneWidget);
        expect(find.text('3'), findsNothing);
        // Every other view keeps its plain count.
        expect(find.text('2'), findsOneWidget);
      });
    });

    // The +/- is the Git row's whole answer, so the row's name carries it for
    // assistive tech instead of leaving it to read as punctuation.
    testWidgets('the Git row speaks its +/- in its name', (tester) async {
      await runDesktop(tester, () async {
        final handle = tester.ensureSemantics();
        try {
          await _pump(
            tester,
            control: _control(),
            gitTotals: (additions: 4, deletions: 3),
          );

          expect(find.bySemanticsLabel('Git, 4 added, 3 removed'), findsOneWidget);
        } finally {
          handle.dispose();
        }
      });
    });

    testWidgets('a rename-only tree keeps the file count', (tester) async {
      // Files changed, no lines did: a Git row with nothing after it would
      // read as a clean worktree.
      await runDesktop(tester, () async {
        await _pump(
          tester,
          control: _control(),
          badges: const {WorkspaceView.git: 3},
        );

        expect(find.text('3'), findsOneWidget);
      });
    });
  });

  // ── Touch tablet: same popup as desktop, no special-cased tap path ────
  group('touch tablet', () {
    Future<void> runTouch(
      WidgetTester tester,
      Future<void> Function() body,
    ) async {
      try {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        await body();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }

    // The popup starts open (see workspaceMenuOpenProvider's default) even
    // though the panel is closed — a tap must close IT, never skip past it
    // to force the panel open instead.
    testWidgets(
      'a tap while the popup is open closes it, even with the panel closed',
      (tester) async {
        await runTouch(tester, () async {
          await _pump(tester, control: _control(active: null));

          expect(find.text('Terminals'), findsOneWidget);

          await tester.tap(find.byKey(WorkspaceMenuButton.buttonKey));
          await tester.pumpAndSettle();

          expect(find.text('Terminals'), findsNothing);
          expect(_button(tester).selected, isFalse);
        });
      },
    );

    // Even with both the popup and the panel closed, a tap only ever
    // reopens the POPUP — it never takes the pane-opening shortcut the
    // button used to have. Picking a row from the (now visible) popup is
    // what un-hides the pane; the icon itself never does.
    testWidgets(
      'a tap while both the popup and the panel are closed just reopens the popup',
      (tester) async {
        await runTouch(tester, () async {
          final container = await _pump(
            tester,
            control: _control(active: null),
          );
          container.read(workspaceMenuOpenProvider.notifier).set(false);
          await tester.pumpAndSettle();
          expect(find.text('Terminals'), findsNothing);

          await tester.tap(find.byKey(WorkspaceMenuButton.buttonKey));
          await tester.pumpAndSettle();

          expect(find.text('Terminals'), findsOneWidget);
          expect(_button(tester).selected, isTrue);
        });
      },
    );

    // Once a view is on screen, the button is the exact same popup as
    // desktop — the docked pane and the popup no longer share screen space.
    testWidgets(
      'a tap while the panel is open toggles the popup, like desktop',
      (tester) async {
        await runTouch(tester, () async {
          await _pump(tester, control: _control(active: WorkspaceView.preview));

          expect(find.text('Terminals'), findsOneWidget);

          await tester.tap(find.byKey(WorkspaceMenuButton.buttonKey));
          await tester.pumpAndSettle();

          expect(find.text('Terminals'), findsNothing);

          await tester.tap(find.byKey(WorkspaceMenuButton.buttonKey));
          await tester.pumpAndSettle();

          expect(find.text('Terminals'), findsOneWidget);
        });
      },
    );

    // Touch density lifts every row to a finger-sized target.
    testWidgets('rows are finger-sized on touch', (tester) async {
      await runTouch(tester, () async {
        await _pump(tester, control: _control());

        expect(_rowHeight(tester, 'Git'), 44);
      });
    });

    // `selected` mirrors the popup, exactly as on desktop — not whether a
    // view happens to be on screen: it starts true with no active view, and
    // a tap closes the popup (and flips it false) exactly like desktop.
    testWidgets('selected tracks the popup, not the active view', (
      tester,
    ) async {
      await runTouch(tester, () async {
        await _pump(tester, control: _control(active: null));
        expect(_button(tester).selected, isTrue);

        await tester.tap(find.byKey(WorkspaceMenuButton.buttonKey));
        await tester.pumpAndSettle();
        expect(_button(tester).selected, isFalse);
      });
    });
  });

  // The trigger is Carbon chrome like the rail it opens, and scopes itself so
  // a mount outside the agent bar still finds a Carbon theme.
  group('trigger', () {
    for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
      testWidgets('is a square Carbon icon button under its own scope '
          '(${platform.name})', (tester) async {
        try {
          debugDefaultTargetPlatformOverride = platform;
          await _pump(tester, control: _control());

          final button = find.byKey(WorkspaceMenuButton.buttonKey);
          expect(tester.widget(button), isA<CarbonButton>());
          expect(find.byType(AbIconButton), findsNothing);
          final size = tester.getSize(button);
          expect(size.width, size.height);
          expect(size.height, greaterThanOrEqualTo(32));
          expect(
            find.ancestor(of: button, matching: find.byType(AbCarbonScope)),
            findsOneWidget,
          );
          await tester.pumpWidget(const SizedBox());
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }
  });
}
