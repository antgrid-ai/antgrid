// A location that names a workspace tab reaches the shell as pending state, not
// as a call: the nav layer has no reveal callback to use (none is published on
// mobile, and none exists at all before the shell mounts). WorkspaceShell is the
// only thing that can act on it, so it drains the provider on mount and on
// change — and on mobile it has to move the PageView as well, or the tab it
// switched sits on a page the user is not looking at.
import 'package:antgrid/models/pending_nav.dart';
import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/models/workspace_view.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/providers/ui_attention_providers.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/providers/visible_surface.dart';
import 'package:antgrid/widgets/agent_panel.dart';
import 'package:antgrid/widgets/mobile_bottom_nav.dart';
import 'package:antgrid/widgets/workspace_panel.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Riverpod 3 keeps `Override` out of the main barrel.
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../helpers/workspace_shell_harness.dart';

/// Bounded pumps rather than `pumpAndSettle`: the shell always has something
/// animating (connection pulse, terminal cursor), so it never settles. Long
/// enough to cover the 300ms page animation.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

/// The platform override must be cleared inside the test body — the binding
/// asserts every foundation debug variable is unset before tearDown runs. It has
/// to stay set for the whole body because the shell's default panel mode reads
/// the platform, and the test default is Android.
Future<void> _withShell(
  WidgetTester tester, {
  required TargetPlatform platform,
  required Size size,
  List<Override> extraOverrides = const [],
  required Future<void> Function(ProviderContainer container) body,
}) async {
  try {
    debugDefaultTargetPlatformOverride = platform;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final container = await pumpWorkspaceShell(
      tester,
      extraOverrides: extraOverrides,
    );
    await _settle(tester);
    await body(container);
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

Future<void> _withDesktopShell(
  WidgetTester tester,
  Future<void> Function(ProviderContainer container) body, {
  List<Override> extraOverrides = const [],
}) => _withShell(
  tester,
  platform: TargetPlatform.windows,
  size: const Size(1400, 900),
  extraOverrides: extraOverrides,
  body: body,
);

Future<void> _withMobileShell(
  WidgetTester tester,
  Future<void> Function(ProviderContainer container) body, {
  List<Override> extraOverrides = const [],
}) => _withShell(
  tester,
  platform: TargetPlatform.android,
  size: const Size(400, 800),
  extraOverrides: extraOverrides,
  body: body,
);

/// A touch tablet: mobile PLATFORM at desktop WIDTH, which is its own layout
/// (`_buildTabletTouch`) and the one where "the agent panel is the default
/// zone" needs the most care — the context pane is a dock there, not an
/// overlay.
Future<void> _withTabletShell(
  WidgetTester tester,
  Future<void> Function(ProviderContainer container) body,
) => _withShell(
  tester,
  platform: TargetPlatform.android,
  size: const Size(1400, 900),
  body: body,
);

/// The harness leaves the selected target at its default, so a value the shell
/// should honour carries that same stamp; anything else names a project this
/// route is not.
PendingNav<WorkspaceView> _pending(WorkspaceView view) =>
    (target: null, value: view);

/// The agent page carries no value of its own — the request IS the value — so
/// the stamp is the whole of it.
const PendingNav<bool> _pendingAgentPage = (target: null, value: true);

void main() {
  testWidgets('a view pending on desktop docks it beside the agent', (
    tester,
  ) async {
    await _withDesktopShell(tester, (container) async {
      expect(find.byType(AgentPanel), findsOneWidget);
      expect(find.byType(WorkspacePanel), findsOneWidget);
      expect(container.read(visibleWorkspaceViewProvider), WorkspaceView.files);

      container
          .read(pendingWorkspaceViewProvider.notifier)
          .set(_pending(WorkspaceView.git));
      await _settle(tester);

      // Still side-by-side with the agent — a pending nav docks the view the
      // same way the workspace menu does, it does not take the whole route.
      expect(find.byType(AgentPanel), findsOneWidget);
      expect(find.byType(WorkspacePanel), findsOneWidget);
      expect(container.read(visibleWorkspaceViewProvider), WorkspaceView.git);
      // Spent on consumption, so a later mount can't replay the link.
      expect(container.read(pendingWorkspaceViewProvider), isNull);
    });
  });

  // A link can arrive before this shell exists, so the value is already there by
  // the time it mounts and no change notification is coming.
  testWidgets('a view pending before mount is drained on mount', (
    tester,
  ) async {
    await _withDesktopShell(
      tester,
      extraOverrides: [
        pendingWorkspaceViewProvider.overrideWith(
          () => ValueController(_pending(WorkspaceView.terminals)),
        ),
      ],
      (container) async {
        expect(find.byType(AgentPanel), findsOneWidget);
        expect(find.byType(WorkspacePanel), findsOneWidget);
        expect(
          container.read(visibleWorkspaceViewProvider),
          WorkspaceView.terminals,
        );
        expect(container.read(pendingWorkspaceViewProvider), isNull);
      },
    );
  });

  // The mobile mirror of the case above, and the one that used to be lost: the
  // shell's first build is its boot status, which has no PageView to move — so
  // the value has to survive until one exists rather than be spent against it.
  testWidgets('a view pending before mount is drained on mobile too', (
    tester,
  ) async {
    await _withMobileShell(
      tester,
      extraOverrides: [
        pendingWorkspaceViewProvider.overrideWith(
          () => ValueController(_pending(WorkspaceView.git)),
        ),
      ],
      (container) async {
        expect(container.read(visibleWorkspaceViewProvider), WorkspaceView.git);
        expect(container.read(agentSurfaceVisibleProvider), isFalse);
        expect(find.byType(AgentPanel), findsNothing);
        expect(tester.getTopLeft(find.byType(MobileBottomNav)).dx, 0);
        expect(container.read(pendingWorkspaceViewProvider), isNull);
      },
    );
  });

  // The other route with no PageView to move: mobile behind a workbench
  // surface. The link is not refused, it waits — and lands the moment the
  // surface it was overlaid by goes away.
  testWidgets('a view pending behind a mobile workbench surface waits', (
    tester,
  ) async {
    await _withMobileShell(
      tester,
      extraOverrides: [
        workbenchSurfaceProvider.overrideWith(
          () => ValueController(WorkbenchSurface.appSettings),
        ),
        pendingWorkspaceViewProvider.overrideWith(
          () => ValueController(_pending(WorkspaceView.git)),
        ),
      ],
      (container) async {
        expect(
          container.read(pendingWorkspaceViewProvider)?.value,
          WorkspaceView.git,
        );

        container
            .read(workbenchSurfaceProvider.notifier)
            .set(WorkbenchSurface.workspace);
        await _settle(tester);

        expect(container.read(visibleWorkspaceViewProvider), WorkspaceView.git);
        expect(container.read(pendingWorkspaceViewProvider), isNull);
      },
    );
  });

  // Nothing rewrites the provider when the user leaves through the drawer, so a
  // value the destination never took must not be honoured by the next project's
  // shell.
  testWidgets('a view pending for another project is dropped, not shown', (
    tester,
  ) async {
    await _withDesktopShell(
      tester,
      extraOverrides: [
        pendingWorkspaceViewProvider.overrideWith(
          () => ValueController((
            target: const LocalProject('somewhere-else'),
            value: WorkspaceView.git,
          )),
        ),
      ],
      (container) async {
        // Never docked: the panel stays on its default view, not git.
        expect(
          container.read(visibleWorkspaceViewProvider),
          WorkspaceView.files,
        );
        expect(container.read(pendingWorkspaceViewProvider), isNull);
      },
    );
  });

  // Null is what a location naming no view writes; it must leave the route
  // exactly as it found it.
  testWidgets('a null pending view opens nothing', (tester) async {
    await _withDesktopShell(tester, (container) async {
      container.read(pendingWorkspaceViewProvider.notifier).set(null);
      await _settle(tester);

      expect(container.read(visibleWorkspaceViewProvider), WorkspaceView.files);
      expect(find.byType(AgentPanel), findsOneWidget);
      expect(find.byType(WorkspacePanel), findsOneWidget);
    });
  });

  // The half that is easy to miss: selecting the tab alone leaves it on the
  // workspace page while the user is still looking at the agent page.
  testWidgets('a view pending on mobile selects the tab AND moves the page', (
    tester,
  ) async {
    await _withMobileShell(tester, (container) async {
      expect(container.read(agentSurfaceVisibleProvider), isTrue);

      container
          .read(pendingWorkspaceViewProvider.notifier)
          .set(_pending(WorkspaceView.git));
      await _settle(tester);

      expect(container.read(visibleWorkspaceViewProvider), WorkspaceView.git);
      expect(container.read(agentSurfaceVisibleProvider), isFalse);
      // The workspace page is the one in the viewport, not merely the one
      // marked visible: the PageView unbuilds the agent page behind it, and the
      // bottom nav (workspace page only) is sitting at the leading edge.
      expect(find.byType(AgentPanel), findsNothing);
      expect(tester.getTopLeft(find.byType(MobileBottomNav)).dx, 0);
      expect(container.read(pendingWorkspaceViewProvider), isNull);
    });
  });

  // The transcript is not a workspace tab, so a route that wants it hands over
  // this provider instead — and on mobile that means moving the PageView back,
  // which is the whole request when the user is looking at the workspace page.
  testWidgets('an agent page pending on mobile moves the PageView back', (
    tester,
  ) async {
    await _withMobileShell(tester, (container) async {
      container
          .read(pendingWorkspaceViewProvider.notifier)
          .set(_pending(WorkspaceView.git));
      await _settle(tester);
      expect(container.read(agentSurfaceVisibleProvider), isFalse);

      container.read(pendingAgentPageProvider.notifier).set(_pendingAgentPage);
      await _settle(tester);

      expect(container.read(agentSurfaceVisibleProvider), isTrue);
      expect(find.byType(AgentPanel), findsOneWidget);
      expect(container.read(pendingAgentPageProvider), isNull);
    });
  });

  // Same self-invalidation as the pending view: nothing rewrites the provider
  // when the user leaves through the drawer instead.
  testWidgets('an agent page pending for another project is spent unshown', (
    tester,
  ) async {
    await _withMobileShell(tester, (container) async {
      container
          .read(pendingWorkspaceViewProvider.notifier)
          .set(_pending(WorkspaceView.git));
      await _settle(tester);
      expect(container.read(agentSurfaceVisibleProvider), isFalse);

      container
          .read(pendingAgentPageProvider.notifier)
          .set((target: const LocalProject('somewhere-else'), value: true));
      await _settle(tester);

      expect(container.read(agentSurfaceVisibleProvider), isFalse);
      expect(container.read(pendingAgentPageProvider), isNull);
    });
  });

  // Desktop in its ordinary split already has the agent panel on screen, so
  // the request is honoured by spending it and moving nothing.
  testWidgets('an agent page pending on desktop is spent, changing nothing', (
    tester,
  ) async {
    await _withDesktopShell(tester, (container) async {
      container.read(pendingAgentPageProvider.notifier).set(_pendingAgentPage);
      await _settle(tester);

      expect(find.byType(AgentPanel), findsOneWidget);
      expect(container.read(visibleWorkspaceViewProvider), WorkspaceView.files);
      expect(container.read(pendingAgentPageProvider), isNull);
    });
  });

  // "The agent panel is the default desktop zone" is false in the mode that
  // drops it from the layout entirely — and the mode is per-session and
  // restored on focus, so a route into a session the user left expanded would
  // otherwise reveal nothing and spend the request doing it.
  testWidgets('an agent page pending restores an expanded context panel', (
    tester,
  ) async {
    await _withDesktopShell(tester, (container) async {
      // The panel's own tab-bar control, called rather than hunted for: which
      // icon carries it is not what this test is about.
      tester
          .widget<WorkspacePanel>(find.byType(WorkspacePanel))
          .onToggleExpand!();
      await _settle(tester);
      expect(find.byType(AgentPanel), findsNothing);

      container.read(pendingAgentPageProvider.notifier).set(_pendingAgentPage);
      await _settle(tester);

      expect(find.byType(AgentPanel), findsOneWidget);
      expect(container.read(pendingAgentPageProvider), isNull);
    });
  });

  // The touch tablet's context pane is a DOCK, not an overlay: open at a
  // quarter of the width it leaves the transcript the other three, which is
  // why `agentSurfaceVisibleProvider` reads that state as the agent being on
  // screen. So the request has nothing to do, and closing the pane would take
  // away the file or diff the user deliberately opened.
  testWidgets('an agent page pending leaves an open tablet pane alone', (
    tester,
  ) async {
    await _withTabletShell(tester, (container) async {
      container
          .read(pendingWorkspaceViewProvider.notifier)
          .set(_pending(WorkspaceView.git));
      await _settle(tester);
      expect(container.read(visibleWorkspaceViewProvider), WorkspaceView.git);
      expect(container.read(agentSurfaceVisibleProvider), isTrue);

      container.read(pendingAgentPageProvider.notifier).set(_pendingAgentPage);
      await _settle(tester);

      expect(container.read(visibleWorkspaceViewProvider), WorkspaceView.git);
      expect(container.read(agentSurfaceVisibleProvider), isTrue);
      expect(container.read(pendingAgentPageProvider), isNull);
    });
  });

  // The one tablet state that does hide the transcript, and the mirror of the
  // mouse desktop's contextExpanded → normal: un-expanded, never closed.
  testWidgets('an agent page pending un-expands a tablet pane', (tester) async {
    await _withTabletShell(tester, (container) async {
      container
          .read(pendingWorkspaceViewProvider.notifier)
          .set(_pending(WorkspaceView.git));
      await _settle(tester);
      tester
          .widget<WorkspacePanel>(find.byType(WorkspacePanel))
          .onToggleExpand!();
      await _settle(tester);
      // Squeezing the agent pane to nothing leaves `AgentBar`'s row narrower
      // than its own content, which the framework reports as an overflow. That
      // is a property of the expanded tablet state itself — it is why
      // `agentSurfaceVisibleProvider` calls the transcript off screen there —
      // and not of the reveal this test is about.
      expect(tester.takeException(), isA<FlutterError>());
      expect(container.read(agentSurfaceVisibleProvider), isFalse);

      container.read(pendingAgentPageProvider.notifier).set(_pendingAgentPage);
      await _settle(tester);

      expect(container.read(agentSurfaceVisibleProvider), isTrue);
      expect(
        tester.widget<WorkspacePanel>(find.byType(WorkspacePanel)).isExpanded,
        isFalse,
      );
      // Still open on the view the user picked — only the width gave way.
      expect(container.read(visibleWorkspaceViewProvider), WorkspaceView.git);
      expect(container.read(pendingAgentPageProvider), isNull);
    });
  });

  // The cross-project applier seeds the queued session id, activates, and
  // stamps this request all before the new project's list has landed. Spending
  // it there spends it on the OLD session's layout: the per-session restore the
  // resolution arms re-applies the target's own saved panel mode a frame later
  // and hides the panel again, with the request already gone.
  testWidgets('an agent page pending waits for a queued session id', (
    tester,
  ) async {
    await _withDesktopShell(tester, (container) async {
      tester
          .widget<WorkspacePanel>(find.byType(WorkspacePanel))
          .onToggleExpand!();
      await _settle(tester);
      expect(find.byType(AgentPanel), findsNothing);

      container
          .read(pendingActiveSessionIdProvider.notifier)
          .set('not-resolved-yet');
      container.read(pendingAgentPageProvider.notifier).set(_pendingAgentPage);
      await _settle(tester);

      expect(find.byType(AgentPanel), findsNothing);
      expect(
        container.read(pendingAgentPageProvider),
        isNotNull,
        reason: 'unspent, so a later rebuild can still honour it',
      );

      // The list lands and the bootstrap consumes the queued id. The rebuild
      // that follows is what retries the drain — here a pending view stands in
      // for the per-session restore's own setState.
      container.read(pendingActiveSessionIdProvider.notifier).set(null);
      container
          .read(pendingWorkspaceViewProvider.notifier)
          .set(_pending(WorkspaceView.files));
      await _settle(tester);

      expect(find.byType(AgentPanel), findsOneWidget);
      expect(container.read(pendingAgentPageProvider), isNull);
    });
  });

  // Both halves of the handover written in ONE synchronous block, which is the
  // state a drain sees when a navigation stamps a tab while an earlier agent
  // request is still pending: neither may eat the other.
  testWidgets('a view and an agent page pending together are both drained', (
    tester,
  ) async {
    await _withMobileShell(tester, (container) async {
      container
          .read(pendingWorkspaceViewProvider.notifier)
          .set(_pending(WorkspaceView.git));
      container.read(pendingAgentPageProvider.notifier).set(_pendingAgentPage);
      await _settle(tester);

      expect(container.read(pendingWorkspaceViewProvider), isNull);
      expect(container.read(pendingAgentPageProvider), isNull);
      // The agent drain runs last, so the page it asked for is where the user
      // lands — and mobile publishes no workspace view from the agent page.
      expect(container.read(agentSurfaceVisibleProvider), isTrue);
      expect(container.read(visibleWorkspaceViewProvider), isNull);
    });
  });
}
