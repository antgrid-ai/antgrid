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
import 'package:antgrid/design/widgets/ab_diff_stat.dart';
import 'package:antgrid/design/widgets/ab_icon.dart';
import 'package:antgrid/design/widgets/ab_icon_button.dart';
import 'package:antgrid/design/widgets/ab_menu.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/providers/visible_surface.dart';
import 'package:antgrid/widgets/workspace_menu_button.dart';
import 'package:antgrid/widgets/workspace_tab_bar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
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

AbIconButton _button(WidgetTester tester) =>
    tester.widget<AbIconButton>(find.byKey(WorkspaceMenuButton.buttonKey));

/// Parks a mouse pointer over the rail and waits out its hover-intent delay,
/// which is what brings it forward from its resting, receded look. Nothing
/// about the rail's LAYOUT depends on this — every label is on screen either
/// way — so only the tests that assert its weight need it.
Future<void> _hoverRail(WidgetTester tester) async {
  final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await pointer.addPointer(location: Offset.zero);
  addTearDown(pointer.removePointer);
  await pointer.moveTo(tester.getCenter(find.byType(WorkspaceMenuPanel)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 150));
  await tester.pumpAndSettle();
}

/// How far the rail has receded: 1 at rest, 0 once it has come forward.
double _quiet(WidgetTester tester) => tester
    .widget<AbPopupSurface>(
      find.descendant(
        of: find.byType(WorkspaceMenuPanel),
        matching: find.byType(AbPopupSurface),
      ),
    )
    .quiet;

/// Where a view's glyph sits on screen.
Rect _iconRect(WidgetTester tester, WorkspaceView view) => tester.getRect(
  find
      .descendant(
        of: find.byType(WorkspaceMenuPanel),
        matching: find.byType(AbIcon),
      )
      .at(WorkspaceView.values.indexOf(view)),
);

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
        await _pump(tester, control: _control());

        expect(_button(tester).selected, isTrue);
        for (final view in WorkspaceView.values) {
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

    // The resting state, and the reason the rail may sit pinned over a
    // transcript at all: receded to a translucent, flat surface — but with
    // every label still on it, which is the whole job.
    testWidgets('rests receded and comes forward under the pointer', (
      tester,
    ) async {
      await runDesktop(tester, () async {
        await _pump(tester, control: _control());

        expect(_quiet(tester), 1);
        for (final view in WorkspaceView.values) {
          expect(find.text(view.label), findsOneWidget, reason: view.label);
        }

        await _hoverRail(tester);
        expect(_quiet(tester), 0);
      });
    });

    // Coming forward is a change of weight, never of size or shape. An earlier
    // version furled to an icon column, which moved every row under the
    // pointer and hid the labels until one was asked for.
    testWidgets('coming forward moves nothing', (tester) async {
      await runDesktop(tester, () async {
        await _pump(tester, control: _control());

        final resting = tester.getRect(find.byType(WorkspaceMenuPanel));
        final rows = {
          for (final view in WorkspaceView.values)
            view: _iconRect(tester, view),
        };

        await _hoverRail(tester);

        expect(tester.getRect(find.byType(WorkspaceMenuPanel)), resting);
        for (final view in WorkspaceView.values) {
          expect(_iconRect(tester, view), rows[view], reason: view.label);
        }
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
        expect(panel.right - longest.right, lessThan(20));
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
    // so the label and the selected state are stated on the wrapper or they
    // are stated nowhere.
    testWidgets('marks the view already on screen', (tester) async {
      await runDesktop(tester, () async {
        await _pump(tester, control: _control(active: WorkspaceView.preview));

        expect(
          find.byWidgetPredicate(
            (w) => w is Semantics && (w.properties.selected ?? false),
          ),
          findsOneWidget,
        );
        expect(
          find.byWidgetPredicate(
            (w) =>
                w is Semantics &&
                (w.properties.selected ?? false) &&
                w.properties.label == 'Preview',
          ),
          findsOneWidget,
        );
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
        expect(find.text('-494'), findsOneWidget);
        expect(find.text('3'), findsNothing);
        // Every other view keeps its plain count.
        expect(find.text('2'), findsOneWidget);
      });
    });

    // Both figures sit in the same trailing column, so they have to read as
    // the same rank of thing. AbDiffStat's own default is set for the dense
    // per-file badge in the changed-file tree and is a size smaller.
    testWidgets('the Git +/- is the same size as a plain count', (
      tester,
    ) async {
      await runDesktop(tester, () async {
        await _pump(
          tester,
          control: _control(),
          badges: const {WorkspaceView.handler: 2},
          gitTotals: (additions: 4, deletions: 3),
        );

        double sizeOf(String text) =>
            tester.widget<Text>(find.text(text)).style!.fontSize!;
        expect(sizeOf('+4'), sizeOf('2'));
      });
    });

    // A receded rail dims its labels by taking the muted foreground, which a
    // green `+4` and a bordered badge cannot do — left alone they end up the
    // loudest thing on a surface nobody has reached for.
    testWidgets('the counts recede with the rail and come back with it', (
      tester,
    ) async {
      await runDesktop(tester, () async {
        await _pump(
          tester,
          control: _control(),
          gitTotals: (additions: 4, deletions: 3),
        );

        double figureOpacity() => tester
            .widget<Opacity>(
              find
                  .ancestor(
                    of: find.byType(AbDiffStat),
                    matching: find.byType(Opacity),
                  )
                  .first,
            )
            .opacity;

        expect(figureOpacity(), lessThan(1));
        // ...and never to nothing: it is the one fact worth reading at rest.
        expect(figureOpacity(), greaterThan(0.4));

        await _hoverRail(tester);
        expect(figureOpacity(), 1);
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

    // Receding is a trade: the rail hands the transcript back some of its
    // weight and takes a hover to get it again. A touch platform has no hover
    // to pay with, so it is never charged — the rail arrives forward and
    // stays there.
    testWidgets('never recedes where there is no hover to undo it', (
      tester,
    ) async {
      await runTouch(tester, () async {
        await _pump(tester, control: _control());

        expect(_quiet(tester), 0);
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
}
