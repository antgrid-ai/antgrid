import 'package:antgrid/models/preferences_models.dart';
import 'package:antgrid/models/workspace_view.dart';
import 'package:antgrid/providers/providers.dart' show preferencesServiceProvider;
import 'package:antgrid/providers/session_workspace_state.dart';
import 'package:antgrid/services/preferences_service.dart';
import 'package:antgrid/storage/session_layout_store.dart';
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

  group('seeding from the project layout', () {
    Future<PreferencesService> serviceFor(
      String projectId,
      ProjectPreferences prefs,
    ) async {
      final service = PreferencesService();
      // File IO is swallowed by the service, so this resolves to defaults on a
      // host with no path_provider — all it has to establish is the project id.
      await service.load(projectId);
      service.update(prefs);
      addTearDown(service.dispose);
      return service;
    }

    ProviderContainer containerFor(
      PreferencesService service, {
      SessionLayoutStore? store,
    }) {
      final container = ProviderContainer(
        overrides: [
          preferencesServiceProvider.overrideWithValue(service),
          if (store != null)
            sessionLayoutStoreProvider.overrideWithValue(store),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    // THE regression this file exists for. The shell used to seed a newly
    // selected session from a post-frame callback, so the switch's first frame
    // painted the previous session's pane geometry and the remounted agent
    // terminal pinned that stale width as its grid. Nothing is pumped here on
    // purpose: the FIRST read must already be right, because that read happens
    // during the switch's first build.
    test('the first read of a fresh session is already seeded', () async {
      final service = await serviceFor(
        'project-a',
        const ProjectPreferences(
          workspaceViewIndex: 0,
          panelMode: PanelModeNames.contextHidden,
        ),
      );
      final container = containerFor(service);

      final state = container.read(
        sessionWorkspaceStateProvider((
          entryId: 'project-a',
          sessionId: 'never-read-before',
        )),
      );

      expect(state.initialized, isTrue);
      expect(state.panelMode, PanelModeNames.contextHidden);
      expect(state.selectedView, WorkspaceView.values[0]);
    });

    // `contextExpanded` leaves no agent panel and no affordance to restore one
    // but its own toggle, so it is a choice a session makes for itself and
    // never a layout the next session inherits.
    test('contextExpanded is downgraded on the way into a new session', () async {
      final service = await serviceFor(
        'project-a',
        const ProjectPreferences(panelMode: PanelModeNames.contextExpanded),
      );
      final container = containerFor(service);

      expect(
        container
            .read(
              sessionWorkspaceStateProvider((
                entryId: 'project-a',
                sessionId: 's1',
              )),
            )
            .panelMode,
        PanelModeNames.normal,
      );
    });

    // The divider is per session, and the project value is a STARTING point
    // rather than a shared one: dragging in one session must leave every other
    // session — and the project's own seed — exactly where they were. Sharing
    // it is what made switching sessions resize the agent terminal.
    test('a drag moves one session and neither its sibling nor the seed', () async {
      final service = await serviceFor(
        'project-a',
        const ProjectPreferences(splitRatio: 0.5),
      );
      final container = containerFor(service);
      const dragged = (entryId: 'project-a', sessionId: 'dragged');
      const sibling = (entryId: 'project-a', sessionId: 'sibling');

      container
          .read(sessionWorkspaceStateProvider(dragged).notifier)
          .update((s) => s.copyWith(splitRatio: 0.8));

      expect(container.read(sessionWorkspaceStateProvider(dragged)).splitRatio, 0.8);
      expect(container.read(sessionWorkspaceStateProvider(sibling)).splitRatio, 0.5);
      expect(service.current.splitRatio, 0.5);
    });

    // A remembered layout is the one the user themselves arranged, so it beats
    // the project seed outright — and it has to be readable SYNCHRONOUSLY, or
    // the restart flashes the project default before correcting, which is the
    // same one-frame lag the switch used to have.
    test('a remembered layout outranks the project seed', () async {
      final service = await serviceFor(
        'project-a',
        const ProjectPreferences(
          splitRatio: 0.5,
          panelMode: PanelModeNames.normal,
        ),
      );
      final store = SessionLayoutStore.inMemory();
      await store.write(
        'project-a',
        's1',
        const SessionLayout(
          panelMode: PanelModeNames.contextHidden,
          splitRatio: 0.72,
        ),
      );

      final state = containerFor(service, store: store).read(
        sessionWorkspaceStateProvider((entryId: 'project-a', sessionId: 's1')),
      );

      expect(state.initialized, isTrue);
      expect(state.splitRatio, 0.72);
      expect(state.panelMode, PanelModeNames.contextHidden);
    });

    // `contextExpanded` is refused as an INHERITED default (see above), but a
    // session coming back to the layout it was itself left in is not
    // inheriting anything.
    test('a session restores its own contextExpanded', () async {
      final service = await serviceFor('project-a', const ProjectPreferences());
      final store = SessionLayoutStore.inMemory();
      await store.write(
        'project-a',
        's1',
        const SessionLayout(panelMode: PanelModeNames.contextExpanded),
      );

      expect(
        containerFor(service, store: store)
            .read(
              sessionWorkspaceStateProvider((
                entryId: 'project-a',
                sessionId: 's1',
              )),
            )
            .panelMode,
        PanelModeNames.contextExpanded,
      );
    });

    // Nothing else walks this store against a live session list, so a delete
    // that does not prune leaks an entry that can never be matched again.
    test('deleting a session forgets its stored layout', () async {
      final service = await serviceFor('project-a', const ProjectPreferences());
      final store = SessionLayoutStore.inMemory();
      await store.write(
        'project-a',
        'doomed',
        const SessionLayout(splitRatio: 0.3),
      );
      final container = containerFor(service, store: store);

      clearSessionWorkspaceState(container, 'project-a', 'doomed');
      await pumpEventQueue();

      expect(store.read('project-a', 'doomed'), isNull);
    });

    // A session is selected while its own project's preference load is still in
    // flight often enough to matter; seeding it from whatever project the
    // service currently holds would copy the PREVIOUS project's layout in.
    test('a session from another project is left unseeded', () async {
      final service = await serviceFor(
        'project-a',
        const ProjectPreferences(panelMode: PanelModeNames.contextHidden),
      );
      final container = containerFor(service);

      final state = container.read(
        sessionWorkspaceStateProvider((
          entryId: 'project-b',
          sessionId: 's1',
        )),
      );

      expect(state.initialized, isFalse);
      expect(state.panelMode, isNull);
    });
  });
}
