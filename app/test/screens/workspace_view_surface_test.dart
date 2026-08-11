// Picking a view from the agent bar's workspace menu gives that view the whole
// workbench area — the slot the settings screen uses — with the projects drawer
// left standing beside it. The docked context panel keeps its own default.
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/providers/visible_surface.dart';
import 'package:antgrid/screens/workspace_view_surface.dart';
import 'package:antgrid/widgets/agent_panel.dart';
import 'package:antgrid/widgets/projects_drawer.dart';
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

/// Picks [label] from the agent bar's workspace menu, which is already open —
/// it opens itself with the session. Scoped to the popup: the docked panel's tab
/// strip carries the same five labels.
Future<void> _pickView(WidgetTester tester, String label) async {
  await tester.tap(
    find.descendant(
      of: find.byType(WorkspaceMenuPanel),
      matching: find.text(label),
    ),
  );
  await _settle(tester);
}

void main() {
  testWidgets('a session opens on the ordinary split, menu in reach', (
    tester,
  ) async {
    await _withShell(tester, (container) async {
      expect(find.byType(AgentPanel), findsOneWidget);
      expect(find.byType(WorkspacePanel), findsOneWidget);
      expect(find.byType(WorkspaceViewSurface), findsNothing);
      expect(find.byKey(WorkspaceMenuButton.buttonKey), findsOneWidget);
      expect(container.read(workspaceMenuControlProvider), isNotNull);
    });
  });

  testWidgets('picking a view gives it the whole workbench', (tester) async {
    await _withShell(tester, (container) async {
      await _pickView(tester, 'Git');

      expect(find.byType(WorkspaceViewSurface), findsOneWidget);
      // The agent and the docked split are replaced, not shrunk beside it.
      expect(find.byType(AgentPanel), findsNothing);
      // ...but the drawer stands, exactly as it does under the settings screen.
      expect(find.byType(ProjectsDrawer), findsOneWidget);
      expect(container.read(visibleWorkspaceViewProvider), WorkspaceView.git);
    });
  });

  // The agent bar is the surface's own casualty: it carries the session
  // controls, so the title bar has to take them back while it is gone.
  testWidgets('the surface hands the session controls to the title bar', (
    tester,
  ) async {
    await _withShell(tester, (container) async {
      expect(container.read(agentBarMountedProvider), isTrue);

      await _pickView(tester, 'Files');

      expect(container.read(agentBarMountedProvider), isFalse);
    });
  });

  testWidgets('the surface names its view and closes back to the agent', (
    tester,
  ) async {
    await _withShell(tester, (container) async {
      await _pickView(tester, 'Terminals');

      // Titled by the view it is showing, in the panel-header treatment.
      final surface = tester.widget<WorkspaceViewSurface>(
        find.byType(WorkspaceViewSurface),
      );
      expect(surface.view, WorkspaceView.terminals);
      expect(find.text('TERMINALS'), findsWidgets);
      // No tab strip: the surface shows the one view that was asked for.
      expect(find.byType(WorkspaceTabBar), findsNothing);

      await tester.tap(find.byKey(WorkspaceViewSurface.backKey));
      await _settle(tester);

      expect(find.byType(WorkspaceViewSurface), findsNothing);
      expect(find.byType(AgentPanel), findsOneWidget);
      expect(container.read(agentBarMountedProvider), isTrue);
    });
  });

  testWidgets('the close button dismisses it too', (tester) async {
    await _withShell(tester, (_) async {
      await _pickView(tester, 'Preview');
      expect(find.byType(WorkspaceViewSurface), findsOneWidget);

      await tester.tap(find.byKey(WorkspaceViewSurface.closeKey));
      await _settle(tester);

      expect(find.byType(WorkspaceViewSurface), findsNothing);
    });
  });
}
