// The agent bar's fifth control: the menu into the workspace views.
//
// It renders off a published WorkspaceMenuControl rather than reading panel
// state directly, so these pump the button against a hand-made control — the
// shell's end of that contract is covered in
// test/screens/workspace_floating_card_test.dart.
import 'package:antgrid/design/widgets/ab_icon_button.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/providers/visible_surface.dart';
import 'package:antgrid/widgets/new_session/environment_menu.dart' show PanelRow;
import 'package:antgrid/widgets/workspace_menu_button.dart';
import 'package:antgrid/widgets/workspace_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required WorkspaceMenuControl? control,
  Map<WorkspaceView, int> badges = const {},
  Widget? behind,
}) async {
  final container = ProviderContainer(
    overrides: [
      workspaceMenuControlProvider.overrideWith(() => ValueController(control)),
      workspaceBadgesProvider.overrideWith((ref) => badges),
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

void main() {
  testWidgets('renders nothing when no workspace is published', (tester) async {
    await _pump(tester, control: null);

    expect(find.byKey(WorkspaceMenuButton.buttonKey), findsNothing);
  });

  // Open from the first frame a workspace exists — no click to get here.
  testWidgets('lists every workspace view, unprompted', (tester) async {
    await _pump(tester, control: (active: null, reveal: (_) {}));

    expect(_button(tester).selected, isTrue);
    for (final view in WorkspaceView.values) {
      expect(find.text(view.label), findsOneWidget, reason: view.label);
    }
  });

  // The menu is pinned: the icon that opened it is the only thing that shuts
  // it, so picking a view leaves it standing and the user can pick again.
  testWidgets('picking a view reveals it and leaves the menu up', (
    tester,
  ) async {
    final revealed = <WorkspaceView>[];
    await _pump(
      tester,
      control: (active: null, reveal: revealed.add),
    );

    await tester.tap(find.text('Git'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Files'));
    await tester.pumpAndSettle();

    expect(revealed, [WorkspaceView.git, WorkspaceView.files]);
    expect(find.text('Terminals'), findsOneWidget);
  });

  // The whole point of dropping the popup ROUTE: a click meant for the agent
  // beneath the menu has to reach it, and take nothing away on the way past.
  testWidgets('a click outside neither closes the menu nor is swallowed', (
    tester,
  ) async {
    var behindTaps = 0;
    await _pump(
      tester,
      control: (active: null, reveal: (_) {}),
      behind: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => behindTaps++,
        child: const SizedBox.expand(),
      ),
    );

    // Bottom-left corner: clear of both the trailing icon and the panel it
    // drops beneath it.
    await tester.tapAt(const Offset(20, 560));
    await tester.pumpAndSettle();

    expect(behindTaps, 1);
    expect(find.text('Terminals'), findsOneWidget);
  });

  testWidgets('the icon is the only thing that shuts it, and shows it is on', (
    tester,
  ) async {
    await _pump(tester, control: (active: null, reveal: (_) {}));

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

  // Revealing a view replaces the agent panel, which unmounts this button —
  // exactly the round trip that used to lose the menu. It has to come back with
  // it, still open, or every use of the menu quietly closes it.
  testWidgets('the menu returns with the button that carries it', (
    tester,
  ) async {
    final container = await _pump(
      tester,
      control: (active: null, reveal: (_) {}),
    );

    container.read(workspaceMenuControlProvider.notifier).set(null);
    await tester.pumpAndSettle();
    expect(find.text('Terminals'), findsNothing);

    container
        .read(workspaceMenuControlProvider.notifier)
        .set((active: null, reveal: (_) {}));
    await tester.pumpAndSettle();

    expect(find.text('Terminals'), findsOneWidget);
    expect(_button(tester).selected, isTrue);
  });

  // ...but a menu the user closed stays closed through the same round trip.
  testWidgets('a closed menu is not reopened by the round trip', (
    tester,
  ) async {
    final container = await _pump(
      tester,
      control: (active: null, reveal: (_) {}),
    );

    await tester.tap(find.byKey(WorkspaceMenuButton.buttonKey));
    await tester.pumpAndSettle();

    container.read(workspaceMenuControlProvider.notifier).set(null);
    await tester.pumpAndSettle();
    container
        .read(workspaceMenuControlProvider.notifier)
        .set((active: null, reveal: (_) {}));
    await tester.pumpAndSettle();

    expect(find.text('Terminals'), findsNothing);
    expect(_button(tester).selected, isFalse);
  });

  testWidgets('marks the view already on screen', (tester) async {
    await _pump(
      tester,
      control: (active: WorkspaceView.preview, reveal: (_) {}),
    );

    expect(
      find.byWidgetPredicate((w) => w is PanelRow && w.selected),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (w) => w is PanelRow && w.selected && w.label == 'Preview',
      ),
      findsOneWidget,
    );
  });

  // The menu and the tab strip both count the same things; a menu that stayed
  // silent about three changed files would send the user to the panel to find
  // out whether there was anything there.
  testWidgets('carries the same badge counts as the tab strip', (tester) async {
    await _pump(
      tester,
      control: (active: null, reveal: (_) {}),
      badges: const {WorkspaceView.git: 3, WorkspaceView.handler: 120},
    );

    expect(find.text('3'), findsOneWidget);
    // Capped exactly as WorkspaceTabBar caps it.
    expect(find.text('99+'), findsOneWidget);
  });
}
