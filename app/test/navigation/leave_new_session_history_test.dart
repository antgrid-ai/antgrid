// app/test/navigation/leave_new_session_history_test.dart
//
// Regression test: leaveNewSession must commit a nav-history entry ONLY when
// the surface was WorkbenchSurface.newSession at the time of the call. When
// called from session_row._showFocusedSessionSurface (which already switched to
// workspace and records its own accurate entry), the guard must skip the commit
// to avoid a phantom double-entry on cross-project taps.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/models/git_branch.dart';
import 'package:antgrid/navigation/nav_controller.dart';
import 'package:antgrid/providers/new_session_picker.dart';
import 'package:antgrid/providers/ui_attention_providers.dart';

void main() {
  // ---------------------------------------------------------------------------
  // Case 1: surface WAS newSession → leaveNewSession should commit one entry.
  // ---------------------------------------------------------------------------
  testWidgets(
    'leaveNewSession commits a workspace entry when surface was newSession',
    (tester) async {
      late WidgetRef capturedRef;

      await tester.pumpWidget(
        ProviderScope(
          child: Consumer(
            builder: (context, ref, _) {
              capturedRef = ref;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      // Surface starts at the default (workspace). Switch it to newSession.
      capturedRef
          .read(workbenchSurfaceProvider.notifier)
          .set(WorkbenchSurface.newSession);

      // Sanity: no history yet.
      expect(capturedRef.read(navControllerProvider).current, isNull);

      leaveNewSession(capturedRef.container);
      await tester.pump();

      // Surface must now be workspace.
      expect(
        capturedRef.read(workbenchSurfaceProvider),
        WorkbenchSurface.workspace,
      );
      // Exactly one history entry must have been committed.
      final navState = capturedRef.read(navControllerProvider);
      expect(navState.current, isNotNull);
      expect(navState.current!.surface, WorkbenchSurface.workspace);
    },
  );

  // ---------------------------------------------------------------------------
  // Case 2: surface was ALREADY workspace (the session_row path) → no commit.
  // ---------------------------------------------------------------------------
  testWidgets(
    'leaveNewSession skips commit when surface is already workspace',
    (tester) async {
      late WidgetRef capturedRef;

      await tester.pumpWidget(
        ProviderScope(
          child: Consumer(
            builder: (context, ref, _) {
              capturedRef = ref;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      // Surface is already workspace (default).
      expect(
        capturedRef.read(workbenchSurfaceProvider),
        WorkbenchSurface.workspace,
      );
      // No history yet.
      expect(capturedRef.read(navControllerProvider).current, isNull);

      leaveNewSession(capturedRef.container);
      await tester.pump();

      // Surface remains workspace.
      expect(
        capturedRef.read(workbenchSurfaceProvider),
        WorkbenchSurface.workspace,
      );
      // No history entry should have been recorded — current stays null.
      expect(capturedRef.read(navControllerProvider).current, isNull);
    },
  );

  testWidgets('leaveNewSession preserves the in-progress form', (tester) async {
    late WidgetRef capturedRef;

    await tester.pumpWidget(
      ProviderScope(
        child: Consumer(
          builder: (context, ref, _) {
            capturedRef = ref;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    capturedRef
        .read(workbenchSurfaceProvider.notifier)
        .set(WorkbenchSurface.newSession);
    capturedRef.read(newSessionPromptProvider.notifier).set('finish the fix');
    capturedRef.read(newSessionNameProvider.notifier).set('draft session');
    capturedRef
        .read(newSessionBranchSelectionProvider.notifier)
        .set(
          const NewSessionBranchSelection(targetId: 'project-a', branch: 'dev'),
        );

    leaveNewSession(capturedRef.container);
    await tester.pump();

    expect(capturedRef.read(newSessionPromptProvider), 'finish the fix');
    expect(capturedRef.read(newSessionNameProvider), 'draft session');
    expect(
      capturedRef.read(newSessionBranchSelectionProvider),
      const NewSessionBranchSelection(targetId: 'project-a', branch: 'dev'),
    );
  });
}
