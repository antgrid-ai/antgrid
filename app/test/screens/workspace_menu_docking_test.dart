// The agent bar's workspace menu docks the picked view into the split panel
// at half width, alongside the agent — un-hiding the panel first if the user
// had it closed. It does NOT give the view the whole workbench: that
// full-width "surface" briefly shipped and was reverted because it left the
// panel-hide toggle with nothing to act on while a view was open.
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/providers/visible_surface.dart';
import 'package:antgrid/widgets/agent_panel.dart';
import 'package:antgrid/widgets/workspace_menu_button.dart';
import 'package:antgrid/widgets/workspace_panel.dart';
import 'package:antgrid/widgets/workspace_tab_bar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/workspace_shell_harness.dart';

SessionEntry _session() => SessionEntry(
  id: 'session-1',
  name: 'Session 1',
  createdAt: 0,
  lastUsedAt: 0,
  archived: false,
  running: true,
  mode: 'terminal',
);

/// Pumps the real shell at desktop width, runs [body], then clears the platform
/// override.
///
/// The override is cleared inside the test body, not from a tearDown: the
/// binding asserts every foundation debug var is unset when the body returns,
/// which is before tearDowns run. It has to stay set for the whole body because
/// `_defaultPanelMode` reads `isMobilePlatform`, and the test default is
/// Android — which would hide the context panel for the wrong reason.
Future<void> _withShell(
  WidgetTester tester,
  Future<void> Function(ProviderContainer container) body,
) async {
  try {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final container = await pumpWorkspaceShell(
      tester,
      extraOverrides: [activeSessionProvider.overrideWithValue(_session())],
    );
    await body(container);
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

/// Settles a popup route's transition. Never `pumpAndSettle`: the shell's
/// connection status pulses forever, so nothing under it reaches a quiet frame.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// Hides the context pane the way the title bar's control does, which is what
/// brings the workspace rail back — with the pane up it has nothing to do (see
/// `WorkspaceShellState._syncMenuToContextPane`) and the shell keeps it down.
Future<void> _closePane(
  WidgetTester tester,
  ProviderContainer container,
) async {
  container.read(contextPanelControlProvider)!.toggle();
  await _settle(tester);
}

/// Picks [label] from the agent bar's workspace rail. Scoped to the rail: the
/// docked panel's tab strip carries the same five labels.
Future<void> _pickView(WidgetTester tester, String label) async {
  // Settled first: the rail is shown from a post-frame callback, so it is not
  // in the tree on the frame that mounts the button carrying it.
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
  // The rail and the pane's own tab strip list the same five views, so only
  // one of them is ever up. A mouse desktop opens onto the pane, which is why
  // the rail's first appearance is the first time the pane is closed.
  testWidgets('the rail keeps out of the way while the pane is up', (
    tester,
  ) async {
    await _withShell(tester, (container) async {
      expect(find.byType(WorkspacePanel), findsOneWidget);
      expect(find.byType(WorkspaceMenuPanel), findsNothing);
      expect(container.read(workspaceMenuOpenProvider), isFalse);

      await _closePane(tester, container);

      expect(find.byType(WorkspaceMenuPanel), findsOneWidget);
      expect(container.read(workspaceMenuOpenProvider), isTrue);
    });
  });

  // Hiding the pane takes its tab strip off screen with it, so the rail coming
  // back is the only way into the workspace from there — but not if the user
  // had already shut the rail by hand. The hand-back restores what they left.
  testWidgets('closing the pane does not reopen a rail the user had shut', (
    tester,
  ) async {
    await _withShell(tester, (container) async {
      await _closePane(tester, container);
      await tester.tap(find.byKey(WorkspaceMenuButton.buttonKey));
      await _settle(tester);
      expect(find.byType(WorkspaceMenuPanel), findsNothing);

      // Out to a view and back, so the pane opens and closes under a rail the
      // user has already dismissed.
      container.read(contextPanelControlProvider)!.toggle();
      await _settle(tester);
      await _closePane(tester, container);

      expect(find.byType(WorkspaceMenuPanel), findsNothing);
      expect(container.read(workspaceMenuOpenProvider), isFalse);
    });
  });

  testWidgets(
    'picking a view from the rail docks it beside the agent, not full width',
    (tester) async {
      await _withShell(tester, (container) async {
        await _closePane(tester, container);

        await _pickView(tester, 'Git');

        // Still side-by-side with the agent — the rail never replaces it.
        expect(find.byType(AgentPanel), findsOneWidget);
        expect(find.byType(WorkspacePanel), findsOneWidget);
        expect(container.read(visibleWorkspaceViewProvider), WorkspaceView.git);
        expect(container.read(agentBarMountedProvider), isTrue);
      });
    },
  );

  testWidgets('picking a view un-hides the panel when the user had it closed', (
    tester,
  ) async {
    await _withShell(tester, (container) async {
      await _closePane(tester, container);
      expect(find.byType(WorkspacePanel), findsNothing);

      await _pickView(tester, 'Preview');

      expect(find.byType(WorkspacePanel), findsOneWidget);
      expect(
        container.read(visibleWorkspaceViewProvider),
        WorkspaceView.preview,
      );
      // ...and the pane arriving is what takes the rail away: the strip it
      // brought with it lists the same five views.
      expect(find.byType(WorkspaceMenuPanel), findsNothing);
    });
  });
}
