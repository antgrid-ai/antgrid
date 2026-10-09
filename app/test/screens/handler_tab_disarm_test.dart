// Disarming the Handler hides its tab at once — and a pane that was showing it
// lands on Files instead of keeping a body no tab is marked for, until the
// Handler is armed again.
import 'dart:async';

import 'package:antgrid/models/handler_state.dart';
import 'package:antgrid/models/workspace_view.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/providers/visible_surface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Size;
import 'package:flutter_test/flutter_test.dart';

import '../helpers/workspace_shell_harness.dart';

HandlerState _armed(String terminalId) => const HandlerState.initial()
    .copyWith(
      sessions: {
        terminalId: HandlerSessionState(
          terminalId: terminalId,
          runState: HandlerRunState.watching,
          pendingEscalations: 0,
          armedAt: 1,
          goal: 'goal',
          backlog: const [],
          escalations: const [],
        ),
      },
    );

void main() {
  testWidgets('a disarm shows Files on the Handler tab until the arm returns', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final states = StreamController<HandlerState>.broadcast();
    addTearDown(states.close);
    try {
      final container = await pumpWorkspaceShell(
        tester,
        extraOverrides: [
          handlerStateProvider.overrideWith((ref) => states.stream),
        ],
      );
      container.read(activeSessionIdProvider.notifier).set('session-1');
      states.add(_armed('session-1'));
      await settleShell(tester);

      container
          .read(revealWorkspaceViewControlProvider)
          ?.call(WorkspaceView.handler);
      await settleShell(tester);
      expect(
        container.read(visibleWorkspaceViewProvider),
        WorkspaceView.handler,
      );

      states.add(const HandlerState.initial());
      await settleShell(tester);

      expect(
        container.read(visibleWorkspaceViewsProvider),
        isNot(contains(WorkspaceView.handler)),
      );
      expect(container.read(visibleWorkspaceViewProvider), WorkspaceView.files);

      // The fallback to Files must not have been saved as the user's choice.
      states.add(_armed('session-1'));
      await settleShell(tester);
      expect(
        container.read(visibleWorkspaceViewProvider),
        WorkspaceView.handler,
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
