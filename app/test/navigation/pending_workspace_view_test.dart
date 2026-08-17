// A location that names a workspace tab reaches the shell as pending state, not
// as a call: the nav layer has no reveal callback to use (none is published on
// mobile, and none exists at all before the shell mounts). WorkspaceShell is the
// only thing that can act on it, so it drains the provider on mount and on
// change — and on mobile it has to move the PageView as well, or the tab it
// switched sits on a page the user is not looking at.
import 'package:antgrid/models/pending_nav.dart';
import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/models/workspace_view.dart';
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

/// The harness leaves the selected target at its default, so a value the shell
/// should honour carries that same stamp; anything else names a project this
/// route is not.
PendingNav<WorkspaceView> _pending(WorkspaceView view) =>
    (target: null, value: view);

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
        expect(container.read(visibleWorkspaceViewProvider), WorkspaceView.files);
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
}
