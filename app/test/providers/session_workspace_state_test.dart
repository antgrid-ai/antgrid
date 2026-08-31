import 'package:antgrid/models/workspace_view.dart';
import 'package:antgrid/providers/session_workspace_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('workspace presentation is isolated by project and session', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    const first = (entryId: 'project-a', sessionId: 'session-1');
    const second = (entryId: 'project-a', sessionId: 'session-2');
    const otherProject = (entryId: 'project-b', sessionId: 'session-1');

    container
        .read(sessionWorkspaceStateProvider(first).notifier)
        .update(
          (s) => s.copyWith(
            initialized: true,
            selectedView: WorkspaceView.terminals,
            panelMode: 'contextHidden',
            pushedTerminalId: 'terminal-1',
          ),
        );

    expect(
      container.read(sessionWorkspaceStateProvider(first)).selectedView,
      WorkspaceView.terminals,
    );
    expect(
      container.read(sessionWorkspaceStateProvider(first)).pushedTerminalId,
      'terminal-1',
    );
    expect(
      container.read(sessionWorkspaceStateProvider(second)).selectedView,
      WorkspaceView.files,
    );
    expect(
      container.read(sessionWorkspaceStateProvider(otherProject)).panelMode,
      isNull,
    );
  });

  test('clearing a deleted session does not affect its sibling', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    const removed = (entryId: 'project-a', sessionId: 'removed');
    const sibling = (entryId: 'project-a', sessionId: 'sibling');

    for (final key in [removed, sibling]) {
      container
          .read(sessionWorkspaceStateProvider(key).notifier)
          .update((s) => s.copyWith(panelMode: 'contextHidden'));
    }
    clearSessionWorkspaceState(container, removed.entryId, removed.sessionId);

    expect(
      container.read(sessionWorkspaceStateProvider(removed)).panelMode,
      isNull,
    );
    expect(
      container.read(sessionWorkspaceStateProvider(sibling)).panelMode,
      'contextHidden',
    );
  });
}
