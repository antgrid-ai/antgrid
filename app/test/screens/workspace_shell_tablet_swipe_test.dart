// A touch tablet's sidebar and context pane are docked, always-mounted panes
// (see WorkspaceShellState._buildTabletTouch), animated open/closed by swipe.
//
// Regression coverage for a bug where a swipe meant to CLOSE whichever pane
// was open instead opened the OTHER one. Each pane used to carry its own
// close-fling detector, positioned exactly over its own box, stacked above a
// full-width detector (wrapping the agent panel) that OPENS the other pane.
// Both are raw `Listener`s (deliberately, to stay out of the gesture arena),
// which only fire when something is actually PAINTED at the pointer's down
// position — so whether a swipe starting right at a pane's edge hit that
// pane's own close detector or fell through to the agent's open detector
// depended on what widget happened to occupy that exact pixel, which varies
// by Y position: near the agent bar's toolbar row (full-bleed content right
// up to the boundary) a swipe starting exactly AT the sidebar's edge fell
// through to the agent's detector and OPENED THE CONTEXT PANE instead of
// closing the sidebar; a few rows down, over the sit-empty middle of the
// agent pane, the same boundary point hit NEITHER detector and did nothing.
// Confirmed empirically pane-by-pane before this fix landed.
//
// The fix resolves the swipe's start point itself, from the same
// state/geometry the panes render with, independent of what is painted at
// the exact pixel — so the outcome can never disagree with what is on screen,
// and a pane's own edge always closes it.
//
// A second round of the same complaint followed, from the other side of that
// boundary: aiming at a pane's edge is imprecise, and a close gesture's
// down-point that lands a few pixels PAST the edge, on the agent, was read as
// a reach for the FAR pane — so the miss did the opposite of what was asked.
// The boundary now sits at the agent pane's own midpoint (the one place a
// finger aimed at a pane never lands) rather than hard against a pane's edge.
//
// Two rounds later the routing stopped being a preference at all. The far-pane
// fallback made a leftward fling at the RIGHT edge close the sidebar, at the
// opposite end of the window from the finger, so each half of the screen now
// drives only the pane on its own side. And the context pane then gave up
// swipes entirely: it is opened from WorkspaceMenuButton's popup and closed by
// its own tab bar's button, which is enough for a pane always reached
// deliberately, where a swipe that could also open it made every sideways drag
// over the agent a coin flip. What remains is one gesture — a fling on the
// sidebar's half, opening or closing the sidebar.
//
// That leaves nothing to arbitrate: the git rows' swipe tray, the tab strip
// and the code viewers all live in the context pane, whose half moves no pane
// at all, so the claim flags they used to raise are gone with it.
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/models/workspace_view.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/providers/ui_attention_providers.dart';
import 'package:antgrid/providers/visible_surface.dart';
import 'package:antgrid/widgets/projects_drawer.dart';
import 'package:antgrid/widgets/workspace_menu_button.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/workspace_shell_harness.dart';

const double _kScreenWidth = 1600;
// Mirrors AbTokens.drawerPaneWidth and WorkspaceShellState's
// `_tabletContextPanelWidth` formula at this screen width — kept local
// rather than importing, since the point is to pin the exact pane edges a
// swipe has to land on to be "on the pane", the same way a user's finger
// would.
const double _kSidebarWidth = 304;
const double _kContextPanelWidth = 400; // 1600 / 4 — the tablet's 3:1 split

SessionEntry _session() => SessionEntry(
  id: 'session-1',
  name: 'Session 1',
  createdAt: 0,
  lastUsedAt: 0,
  archived: false,
  running: true,
  mode: 'terminal',
);

/// Pumps the real shell at tablet width on a touch platform — wide enough to
/// route through `_buildTabletTouch` (>= kCompactBreakpoint) rather than the
/// phone PageView, and wide enough that the sidebar and the (3:1-split)
/// context pane can both be open at once without the agent bar's own row
/// overflowing — a pre-existing layout issue unrelated to the swipe-routing
/// bug under test here.
Future<ProviderContainer> _withTabletShell(
  WidgetTester tester,
  Future<void> Function(ProviderContainer container) body,
) async {
  try {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(_kScreenWidth, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final container = await pumpWorkspaceShell(
      tester,
      extraOverrides: [activeSessionProvider.overrideWithValue(_session())],
    );
    await body(container);
    return container;
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

/// Bounded pumps rather than `pumpAndSettle`: the shell always has something
/// animating, so settling never terminates. Long enough to clear
/// AbTokens.motionPane (220ms).
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Picks a view from the agent bar's workspace rail. Settles first: the rail
/// is shown from a post-frame callback (see `WorkspaceMenuButton`), so it is
/// one frame behind the shell that publishes it.
///
/// Taps the label with no hover because [_withTabletShell] pins
/// `TargetPlatform.android`, where the rail never recedes and the labels are
/// laid out from the first frame. Should the rail ever recede here, this taps a
/// clipped, zero-opacity label ~200px outside the rail's box — and `tester.tap`
/// only WARNS on a miss, so the swipe-routing tests would fail as "expected
/// git, got null" and read as a bug in the fling router.
Future<void> _pickView(WidgetTester tester, String label) async {
  await _settle(tester);
  await tester.tap(
    find.descendant(
      of: find.byType(WorkspaceMenuPanel),
      matching: find.text(label),
    ),
  );
  await _settle(tester);
}

void main() {
  testWidgets('the sidebar starts open and the context pane starts closed', (
    tester,
  ) async {
    await _withTabletShell(tester, (container) async {
      expect(tester.getTopLeft(find.byType(ProjectsDrawer)).dx, 0);
      expect(container.read(visibleWorkspaceViewProvider), isNull);
    });
  });

  // The agent bar's hamburger ("Projects") is a TOGGLE, not a one-way
  // reveal — a tap while the sidebar is already open must close it, not sit
  // there doing nothing until a swipe or the back gesture closes it instead.
  testWidgets(
    'the agent bar hamburger closes the sidebar too, not just opens it',
    (tester) async {
      await _withTabletShell(tester, (container) async {
        expect(tester.getTopLeft(find.byType(ProjectsDrawer)).dx, 0);

        await tester.tap(find.byTooltip('Projects'));
        await _settle(tester);
        expect(
          tester.getTopLeft(find.byType(ProjectsDrawer)).dx,
          lessThan(0),
          reason: 'the sidebar should have closed',
        );

        await tester.tap(find.byTooltip('Projects'));
        await _settle(tester);
        expect(tester.getTopLeft(find.byType(ProjectsDrawer)).dx, 0);
      });
    },
  );

  // The down-point sits exactly at the sidebar's own trailing edge, over the
  // agent bar's toolbar row — the precise spot the old per-pane detectors
  // disagreed on. A swipe from well inside the sidebar always worked, even on
  // the old code, so this test has to start right at the boundary to mean
  // anything.
  testWidgets(
    'a leftward swipe starting right at the sidebar edge closes it, not the context pane',
    (tester) async {
      await _withTabletShell(tester, (container) async {
        expect(tester.getTopLeft(find.byType(ProjectsDrawer)).dx, 0);
        expect(container.read(visibleWorkspaceViewProvider), isNull);

        await tester.flingFrom(
          const Offset(_kSidebarWidth, 30),
          const Offset(-250, 0),
          1200,
        );
        await _settle(tester);

        expect(
          tester.getTopLeft(find.byType(ProjectsDrawer)).dx,
          lessThan(0),
          reason: 'the sidebar should have closed',
        );
        // The bug: this used to open the context pane instead.
        expect(container.read(visibleWorkspaceViewProvider), isNull);
      });
    },
  );

  // The context pane answers to buttons alone — its tab bar's close button and
  // WorkspaceMenuButton's popup — so no fling on its half of the screen may
  // move either pane. A pane a swipe could also OPEN made every sideways drag
  // over the agent a coin flip; the sidebar keeps its fling because one button
  // in the agent bar is its only other way in.
  testWidgets('the context pane ignores flings in both directions', (
    tester,
  ) async {
    await _withTabletShell(tester, (container) async {
      await _pickView(tester, 'Git');
      expect(container.read(visibleWorkspaceViewProvider), WorkspaceView.git);
      expect(tester.getTopLeft(find.byType(ProjectsDrawer)).dx, 0);

      // Over the pane's own body, below its tab strip (which owns a drag of
      // its own across the top 38px).
      await tester.flingFrom(
        const Offset(_kScreenWidth - _kContextPanelWidth / 2, 200),
        const Offset(250, 0),
        1200,
      );
      await _settle(tester);
      expect(container.read(visibleWorkspaceViewProvider), WorkspaceView.git);
      expect(tester.getTopLeft(find.byType(ProjectsDrawer)).dx, 0);

      // And from the agent's context-pane half, where the leftward "open me"
      // fling used to live.
      await tester.flingFrom(
        const Offset(_kScreenWidth - _kContextPanelWidth - 12, 200),
        const Offset(-250, 0),
        1200,
      );
      await _settle(tester);
      expect(container.read(visibleWorkspaceViewProvider), WorkspaceView.git);
      expect(tester.getTopLeft(find.byType(ProjectsDrawer)).dx, 0);
    });
  });

  testWidgets('a fling on the context pane\'s half cannot open it either', (
    tester,
  ) async {
    await _withTabletShell(tester, (container) async {
      expect(container.read(visibleWorkspaceViewProvider), isNull);

      await tester.flingFrom(
        const Offset(_kScreenWidth - 200, 200),
        const Offset(-200, 0),
        1200,
      );
      await _settle(tester);

      expect(
        container.read(visibleWorkspaceViewProvider),
        isNull,
        reason: 'the pane opens from its popup, not from a swipe',
      );
      expect(tester.getTopLeft(find.byType(ProjectsDrawer)).dx, 0);
    });
  });

  // Aiming at an open pane's edge is imprecise, and a close gesture's
  // down-point routinely lands a few pixels PAST it, on the agent. Treating
  // all of the agent as a reach for the far pane made that miss do the
  // opposite of what was asked — the sidebar stayed put and the context pane
  // flew open (and mirror-image for the context pane). The two below are that
  // miss, from either side.
  testWidgets(
    'a leftward fling just past the sidebar edge still closes the sidebar',
    (tester) async {
      await _withTabletShell(tester, (container) async {
        expect(tester.getTopLeft(find.byType(ProjectsDrawer)).dx, 0);
        expect(container.read(visibleWorkspaceViewProvider), isNull);

        await tester.flingFrom(
          const Offset(_kSidebarWidth + 12, 30),
          const Offset(-250, 0),
          1200,
        );
        await _settle(tester);

        expect(
          tester.getTopLeft(find.byType(ProjectsDrawer)).dx,
          lessThan(0),
          reason: 'the sidebar should have closed',
        );
        // The bug: this opened the context pane and left the sidebar open.
        expect(container.read(visibleWorkspaceViewProvider), isNull);
      });
    },
  );

  // The mirror of the sidebar-edge case above: a rightward fling landing a few
  // pixels off the context pane, on the agent, must not reach across and open
  // the sidebar at the other end of the window.
  testWidgets(
    'a rightward fling just past the context pane edge opens nothing',
    (tester) async {
      await _withTabletShell(tester, (container) async {
        await _pickView(tester, 'Git');
        expect(container.read(visibleWorkspaceViewProvider), WorkspaceView.git);
        await tester.tap(find.byTooltip('Projects'));
        await _settle(tester);
        expect(tester.getTopLeft(find.byType(ProjectsDrawer)).dx, lessThan(0));

        await tester.flingFrom(
          const Offset(_kScreenWidth - _kContextPanelWidth - 12, 200),
          const Offset(250, 0),
          1200,
        );
        await _settle(tester);

        expect(container.read(visibleWorkspaceViewProvider), WorkspaceView.git);
        expect(tester.getTopLeft(find.byType(ProjectsDrawer)).dx, lessThan(0));
      });
    },
  );

  // A workbench surface takes the whole route and drops the context pane from
  // the tree with its open flag still set. The pane is not a fling target
  // either way now, but the flag still ZONES the gesture — so read on its own
  // it cut the agent's half in two around a pane that is not painted, and a
  // fling landing in that phantom quarter did nothing at all while the sidebar,
  // which stays painted under the surface, was the only pane on screen.
  testWidgets(
    'a fling ignores the context pane while a surface covers the route',
    (tester) async {
      await _withTabletShell(tester, (container) async {
        await _pickView(tester, 'Git');
        expect(container.read(visibleWorkspaceViewProvider), WorkspaceView.git);

        await tester.tap(find.byTooltip('Projects'));
        await _settle(tester);
        expect(tester.getTopLeft(find.byType(ProjectsDrawer)).dx, lessThan(0));

        container
            .read(workbenchSurfaceProvider.notifier)
            .set(WorkbenchSurface.appSettings);
        await _settle(tester);

        // Past where the pane's half USED to begin, but inside the sidebar's
        // half of the full-width agent that is actually on screen.
        await tester.flingFrom(
          const Offset(700, 200),
          const Offset(250, 0),
          1200,
        );
        await _settle(tester);

        expect(
          tester.getTopLeft(find.byType(ProjectsDrawer)).dx,
          0,
          reason: 'the one pane on screen should have taken the fling',
        );
      });
    },
  );

  testWidgets('a fling with no pane to move changes nothing', (tester) async {
    await _withTabletShell(tester, (container) async {
      // Sidebar open, context pane closed: a rightward fling on the agent's
      // sidebar half has neither a pane to close nor one to open.
      expect(tester.getTopLeft(find.byType(ProjectsDrawer)).dx, 0);
      expect(container.read(visibleWorkspaceViewProvider), isNull);

      await tester.flingFrom(
        const Offset(_kSidebarWidth + 12, 30),
        const Offset(250, 0),
        1200,
      );
      await _settle(tester);

      expect(tester.getTopLeft(find.byType(ProjectsDrawer)).dx, 0);
      expect(container.read(visibleWorkspaceViewProvider), isNull);
    });
  });

  // Fifth round, and the reason the far-pane fallback above is gone: with the
  // context pane open, a LEFTWARD fling at the far right of the screen had
  // nothing left to do on its own side (the pane is already open), fell
  // through, and closed the SIDEBAR — a pane at the opposite end of the
  // window from the finger. Each half of the screen now drives only the pane
  // on its own side; doing nothing is the correct answer here.
  testWidgets('a fling never reaches the pane on the far side of the screen', (
    tester,
  ) async {
    await _withTabletShell(tester, (container) async {
      await _pickView(tester, 'Git');
      expect(container.read(visibleWorkspaceViewProvider), WorkspaceView.git);
      expect(tester.getTopLeft(find.byType(ProjectsDrawer)).dx, 0);

      // Leftward, from the right end — over the open context pane, below its
      // tab strip so the strip's own claim is not what answers.
      await tester.flingFrom(
        const Offset(_kScreenWidth - 20, 300),
        const Offset(-250, 0),
        1200,
      );
      await _settle(tester);

      expect(
        tester.getTopLeft(find.byType(ProjectsDrawer)).dx,
        0,
        reason: 'the sidebar is on the other side of the screen',
      );
      expect(container.read(visibleWorkspaceViewProvider), WorkspaceView.git);

      // Mirror image: rightward on the sidebar's half with the sidebar
      // already open must not close the context pane across the window.
      await tester.flingFrom(
        const Offset(_kSidebarWidth + 12, 300),
        const Offset(250, 0),
        1200,
      );
      await _settle(tester);

      expect(container.read(visibleWorkspaceViewProvider), WorkspaceView.git);
      expect(tester.getTopLeft(find.byType(ProjectsDrawer)).dx, 0);
    });
  });
}
