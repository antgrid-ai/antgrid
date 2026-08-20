// app/test/navigation/mobile_page_chain_test.dart
//
// One rightward swipe means "back" everywhere on mobile: workspace → agent →
// drawer. The first step is the PageView; the second is its leading overscroll,
// which opens the drawer as a panel over the content. Reading the drawer off
// the page's own overscroll is what makes the swipe work from ANYWHERE, rather
// than from the edge strip Android's back gesture was swallowing.
import 'package:antgrid/navigation/back_intent.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/ui_attention_providers.dart';
import 'package:antgrid/providers/visible_surface.dart';
import 'package:antgrid/widgets/agent_panel.dart';
import 'package:antgrid/widgets/mobile_bottom_nav.dart';
import 'package:antgrid/widgets/projects_drawer.dart';
import 'package:antgrid/widgets/workspace_tab_bar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/workspace_shell_harness.dart';

/// The platform override must be cleared inside the test body — the binding
/// asserts every foundation debug variable is unset before tearDown runs.
Future<void> onAndroid(Future<void> Function() body) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.android;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

/// iOS scrolls with BouncingScrollPhysics, which never emits an
/// OverscrollNotification — the position simply goes negative. Anything that
/// reads "pulled past the leading edge" has to cover both.
Future<void> onIOS(Future<void> Function() body) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

/// Bounded pumps rather than `pumpAndSettle`: the shell always has something
/// animating (loading indicators, the terminal cursor), so settling never
/// terminates. Long enough to cover the 300ms page animation either way.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

/// A rightward swipe across the middle of the screen — deliberately NOT from
/// the edge, which is the whole point of the change.
Future<void> swipeRight(WidgetTester tester) async {
  await tester.drag(find.byType(PageView), const Offset(400, 0));
  await settle(tester);
}

Future<void> swipeLeft(WidgetTester tester) async {
  await tester.drag(find.byType(PageView), const Offset(-400, 0));
  await settle(tester);
}

void main() {
  tearDown(() {
    backIntentExit = () => Future<void>.value();
  });

  Future<ProviderContainer> pumpMobile(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final c = await pumpWorkspaceShell(tester);
    await settle(tester);
    return c;
  }

  testWidgets('opens on the agent page, between drawer and workspace', (
    tester,
  ) async {
    await onAndroid(() async {
      final c = await pumpMobile(tester);

      expect(c.read(agentSurfaceVisibleProvider), isTrue);
      // No workspace tab is on screen, so no content back handler may fire.
      expect(c.read(visibleWorkspaceViewProvider), isNull);
    });
  });

  // The headline behaviour: a swipe from the MIDDLE of the agent page, nowhere
  // near an edge, reveals the drawer.
  testWidgets('a mid-screen rightward swipe reveals the drawer', (
    tester,
  ) async {
    await onAndroid(() async {
      await pumpMobile(tester);
      expect(find.byType(ProjectsDrawer), findsNothing);

      await swipeRight(tester);

      expect(find.byType(ProjectsDrawer), findsOneWidget);
    });
  });

  // Bouncing physics returns 0 from applyBoundaryConditions, so reading only
  // OverscrollNotification left this gesture dead on every iPhone.
  testWidgets('the swipe reveals the drawer on iOS physics too', (
    tester,
  ) async {
    await onIOS(() async {
      await pumpMobile(tester);
      expect(find.byType(ProjectsDrawer), findsNothing);

      // Bouncing applies friction past the edge, so the drag has to be longer
      // than the equivalent Android one to clear the same threshold.
      await tester.drag(find.byType(PageView), const Offset(700, 0));
      await settle(tester);

      expect(find.byType(ProjectsDrawer), findsOneWidget);
    });
  });

  // The agent page is full of nested scrollables, and every one of them
  // overscrolls at its own leading edge. Without the depth gate, flicking the
  // transcript to the top opened the drawer.
  testWidgets('a nested scrollable overscrolling does not open the drawer', (
    tester,
  ) async {
    await onAndroid(() async {
      await pumpMobile(tester);

      // Dispatched from inside the PageView's viewport, so it arrives at the
      // shell's listener with depth 1 — exactly like a real inner list's.
      final inner = tester.element(find.byType(AgentPanel));
      final metrics = FixedScrollMetrics(
        minScrollExtent: 0,
        maxScrollExtent: 1000,
        pixels: 0,
        viewportDimension: 800,
        axisDirection: AxisDirection.down,
        devicePixelRatio: 1.0,
      );
      for (var i = 0; i < 5; i++) {
        OverscrollNotification(
          metrics: metrics,
          context: inner,
          overscroll: -40,
        ).dispatch(inner);
      }
      await settle(tester);

      expect(find.byType(ProjectsDrawer), findsNothing);
    });
  });

  // It must arrive as a panel over the content, not as a full-screen page —
  // 304px of a 400px-wide viewport.
  testWidgets('the drawer overlays the content rather than replacing it', (
    tester,
  ) async {
    await onAndroid(() async {
      await pumpMobile(tester);
      await swipeRight(tester);

      final width = tester.getSize(find.byType(Drawer)).width;
      expect(width, 304.0);
      expect(width, lessThan(tester.view.physicalSize.width));
      // The agent page is still mounted underneath, not swapped out.
      expect(find.byType(AgentPanel), findsOneWidget);
    });
  });

  // workspace → agent → drawer as one continuous chain, which is what makes the
  // gesture learnable: the same swipe always means "back".
  testWidgets('swipes chain workspace to agent to drawer', (tester) async {
    await onAndroid(() async {
      final c = await pumpMobile(tester);

      await swipeLeft(tester);
      expect(c.read(visibleWorkspaceViewProvider), isNotNull);
      expect(c.read(agentSurfaceVisibleProvider), isFalse);

      await swipeRight(tester);
      expect(c.read(agentSurfaceVisibleProvider), isTrue);
      expect(c.read(visibleWorkspaceViewProvider), isNull);
      expect(find.byType(ProjectsDrawer), findsNothing);

      await swipeRight(tester);
      expect(find.byType(ProjectsDrawer), findsOneWidget);
    });
  });

  // Back has to mirror the swipe, or the two ways of going back disagree about
  // where "back" is.
  testWidgets('system back walks the same chain', (tester) async {
    await onAndroid(() async {
      final c = await pumpMobile(tester);

      await swipeLeft(tester);
      expect(c.read(visibleWorkspaceViewProvider), isNotNull);

      expect(resolveBackIntent(c), isTrue);
      await settle(tester);
      expect(c.read(agentSurfaceVisibleProvider), isTrue);

      await swipeRight(tester);
      expect(find.byType(ProjectsDrawer), findsOneWidget);

      // Back closes the drawer, mirroring the swipe that opened it.
      expect(resolveBackIntent(c), isTrue);
      await settle(tester);
      expect(find.byType(ProjectsDrawer), findsNothing);
    });
  });

  // MobileBottomNav used to carry its own leading hamburger into the drawer,
  // redundant with the agent header's one page over — removed entirely
  // (no `onOpenDrawer` parameter left to wire back up). Pinned so a future
  // change doesn't quietly reintroduce it.
  testWidgets('the workspace page bottom nav carries no menu button', (
    tester,
  ) async {
    await onAndroid(() async {
      await pumpMobile(tester);

      await swipeLeft(tester);
      expect(find.byType(MobileBottomNav), findsOneWidget);
      expect(find.byTooltip('Projects'), findsNothing);
    });
  });

  testWidgets('the agent header menu button opens the drawer too', (
    tester,
  ) async {
    await onAndroid(() async {
      final c = await pumpMobile(tester);
      expect(find.byType(AgentPanel), findsOneWidget);

      // Published by the shell, consumed by AgentPanel's header — there is no
      // ScaffoldState behind the drawer any more.
      expect(c.read(openDrawerProvider), isNotNull);
      c.read(openDrawerProvider)!();
      await settle(tester);

      expect(find.byType(ProjectsDrawer), findsOneWidget);
    });
  });

  // The header hamburger is a TOGGLE, not a one-way reveal: a second tap
  // while the drawer is already open must close it again, not sit there
  // doing nothing until a swipe or the back gesture closes it instead.
  testWidgets('the agent header menu button closes the drawer too', (
    tester,
  ) async {
    await onAndroid(() async {
      final c = await pumpMobile(tester);

      c.read(openDrawerProvider)!();
      await settle(tester);
      expect(find.byType(ProjectsDrawer), findsOneWidget);

      c.read(openDrawerProvider)!();
      await settle(tester);
      expect(find.byType(ProjectsDrawer), findsNothing);
    });
  });

  // The route handoff is one frame: NewSessionScreen's deferred retraction of
  // openDrawerProvider lands AFTER the incoming shell's post-frame publish, so
  // an unconditional clear left the agent header's button rendering disabled
  // (onTap: null) for the whole workspace visit — and New Session → workspace is
  // the ONLY way in on mobile.
  testWidgets('the agent header menu button survives the New Session handoff', (
    tester,
  ) async {
    await onAndroid(() async {
      final c = await pumpMobile(tester);

      c
          .read(workbenchSurfaceProvider.notifier)
          .set(WorkbenchSurface.newSession);
      await settle(tester);
      expect(find.byType(AgentPanel), findsNothing);

      c.read(workbenchSurfaceProvider.notifier).set(WorkbenchSurface.workspace);
      await settle(tester);
      expect(find.byType(AgentPanel), findsOneWidget);

      expect(c.read(openDrawerProvider), isNotNull);
      await tester.tap(find.byTooltip('Projects'));
      await settle(tester);

      expect(find.byType(ProjectsDrawer), findsOneWidget);
    });
  });

  // The overscroll route to the drawer only fires once every horizontal
  // scrollable under the finger has run out of room, which a wide terminal never
  // does — so the agent page needs the fling as well.
  testWidgets('a fling over the agent page reveals the drawer', (tester) async {
    await onAndroid(() async {
      await pumpMobile(tester);
      expect(find.byType(ProjectsDrawer), findsNothing);

      // Deliberately shorter than _kBackOverscrollThreshold: a flick this small
      // is beneath the overscroll route, so only the fling detector can answer
      // it — which is what a wide terminal leaves the user with.
      await tester.fling(find.byType(AgentPanel), const Offset(44, 0), 1200);
      await settle(tester);

      expect(find.byType(ProjectsDrawer), findsOneWidget);
    });
  });

  // Rightward on the workspace page means "go to the agent page" — that swipe
  // must not skip a step and land on the drawer as well.
  testWidgets('a fling on the workspace page only walks back one step', (
    tester,
  ) async {
    await onAndroid(() async {
      final c = await pumpMobile(tester);

      await swipeLeft(tester);
      expect(c.read(agentSurfaceVisibleProvider), isFalse);

      await tester.fling(find.byType(PageView), const Offset(200, 0), 1200);
      await settle(tester);

      expect(c.read(agentSurfaceVisibleProvider), isTrue);
      expect(find.byType(ProjectsDrawer), findsNothing);
    });
  });

  /// A decisive rightward flick inside the open drawer — the far end of the
  /// chain, where the PageView is covered and can no longer report a step back.
  Future<void> flingInDrawer(WidgetTester tester) async {
    await tester.fling(find.byType(ProjectsDrawer), const Offset(200, 0), 1200);
    await settle(tester);
  }

  testWidgets('a fling inside the open drawer offers to close the app', (
    tester,
  ) async {
    await onAndroid(() async {
      await pumpMobile(tester);

      await swipeRight(tester);
      expect(find.byType(ProjectsDrawer), findsOneWidget);

      await flingInDrawer(tester);
      expect(find.text('Close Antgrid?'), findsOneWidget);

      // Declining leaves the app exactly where it was.
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(find.text('Close Antgrid?'), findsNothing);
      expect(find.byType(ProjectsDrawer), findsOneWidget);
    });
  });

  // The exit detector shares the open drawer with DrawerController's own
  // swipe-to-close. A GestureDetector here won that arena outright and ate the
  // leftward drag, stranding the drawer open.
  testWidgets('the open drawer can still be swiped closed', (tester) async {
    await onAndroid(() async {
      await pumpMobile(tester);
      await swipeRight(tester);
      expect(find.byType(ProjectsDrawer), findsOneWidget);

      await tester.fling(
        find.byType(ProjectsDrawer),
        const Offset(-200, 0),
        1200,
      );
      await settle(tester);

      expect(find.byType(ProjectsDrawer), findsNothing);
      expect(find.text('Close Antgrid?'), findsNothing);
    });
  });

  testWidgets('confirming the prompt exits through the shared exit path', (
    tester,
  ) async {
    await onAndroid(() async {
      var exits = 0;
      backIntentExit = () async => exits++;

      await pumpMobile(tester);
      await swipeRight(tester);
      await flingInDrawer(tester);

      await tester.tap(find.text('Close'));
      await settle(tester);

      expect(exits, 1);
    });
  });

  // A workspace tab switch must still publish, or the tab-scoped back handlers
  // (file viewer, diff, pushed terminal) all go inert.
  testWidgets('the workspace page still publishes its selected tab', (
    tester,
  ) async {
    await onAndroid(() async {
      final c = await pumpMobile(tester);

      await swipeLeft(tester);
      expect(c.read(visibleWorkspaceViewProvider), isA<WorkspaceView>());
    });
  });
}
