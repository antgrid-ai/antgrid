import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/preferences_models.dart';
import '../models/workspace_view.dart';
import 'agent_transport.dart';
import 'providers.dart';
import 'sessions.dart';

typedef SessionUiKey = ({String entryId, String sessionId});

class SessionWorkspaceState {
  const SessionWorkspaceState({
    this.initialized = false,
    this.selectedView = WorkspaceView.files,
    this.panelMode,
    this.splitRatio,
    this.mobilePage = 0,
    this.tabletContextOpen = false,
    this.tabletContextExpanded = false,
    this.pinnedTerminalId,
    this.pushedTerminalId,
  });

  final bool initialized;
  final WorkspaceView selectedView;
  final String? panelMode;

  /// Where this session's desktop divider sits, as a left-pane fraction.
  ///
  /// Per session, because the context panel is per session: a width chosen with
  /// a diff open is the wrong width for a session running a full-screen TUI, and
  /// sharing one made every switch resize the agent terminal. Seeded once from
  /// `ProjectPreferences.splitRatio` and never written back — the project value
  /// is a STATIC starting point for new sessions, not a running average of the
  /// last drag anywhere.
  ///
  /// Null only while unseeded (see `SessionWorkspaceController.build()`); the
  /// shell falls back to the project value there.
  final double? splitRatio;

  final int mobilePage;
  final bool tabletContextOpen;
  final bool tabletContextExpanded;
  final String? pinnedTerminalId;
  final String? pushedTerminalId;

  SessionWorkspaceState copyWith({
    bool? initialized,
    WorkspaceView? selectedView,
    String? panelMode,
    double? splitRatio,
    int? mobilePage,
    bool? tabletContextOpen,
    bool? tabletContextExpanded,
    String? pinnedTerminalId,
    bool clearPinnedTerminalId = false,
    String? pushedTerminalId,
    bool clearPushedTerminalId = false,
  }) => SessionWorkspaceState(
    initialized: initialized ?? this.initialized,
    selectedView: selectedView ?? this.selectedView,
    panelMode: panelMode ?? this.panelMode,
    splitRatio: splitRatio ?? this.splitRatio,
    mobilePage: mobilePage ?? this.mobilePage,
    tabletContextOpen: tabletContextOpen ?? this.tabletContextOpen,
    tabletContextExpanded: tabletContextExpanded ?? this.tabletContextExpanded,
    pinnedTerminalId: clearPinnedTerminalId
        ? null
        : (pinnedTerminalId ?? this.pinnedTerminalId),
    pushedTerminalId: clearPushedTerminalId
        ? null
        : (pushedTerminalId ?? this.pushedTerminalId),
  );
}

class SessionWorkspaceController extends Notifier<SessionWorkspaceState> {
  SessionWorkspaceController(this.key);

  final SessionUiKey key;

  /// Seeds from the project's stored layout HERE rather than in the shell, so
  /// the very first read of a newly selected session already answers with its
  /// real layout.
  ///
  /// The shell used to do this from a `ref.listen` on
  /// `activeSessionUiKeyProvider`, which fires during build and so had to defer
  /// the restore to a post-frame `setState`. That left frame N painting the
  /// PREVIOUS session's pane geometry while the terminal — keyed by
  /// `terminalId`, so remounted by the switch — pinned that stale width as its
  /// grid (`_TerminalGridFreeze` in `widgets/terminal_view_wrapper.dart`) and
  /// then corrected a frame later plus a settle delay. Seeding at the provider
  /// removes the intermediate frame entirely.
  ///
  /// `ref.read`, not `ref.watch`: the service is a root singleton, and watching
  /// it would re-run `build()` and discard everything the user has since
  /// changed in this session.
  @override
  SessionWorkspaceState build() {
    final prefs = ref.read(preferencesServiceProvider);
    // Seed with a ONE-SHOT read, then listen WITHOUT fireImmediately — same
    // reason as `CollapsedDrawerIdsNotifier`: a fireImmediately callback runs
    // synchronously inside build(), and writing `state` there throws.
    ref.listen(projectPreferencesProvider, (_, next) {
      if (state.initialized) return;
      final loaded = next.value;
      if (loaded == null) return;
      // The stream carries no project id of its own, and a session key from a
      // project that is no longer focused must not be seeded with the focused
      // project's layout. `PreferencesService` holds exactly one project, so
      // its id is the tag.
      if (ref.read(preferencesServiceProvider).projectId != key.entryId) return;
      state = _seed(loaded);
    });
    // A session can be selected while its project's preference load is still in
    // flight; seeding from `current` then copies the PREVIOUS project's layout.
    // The listener above picks it up when the load lands.
    if (prefs.projectId != key.entryId) return const SessionWorkspaceState();
    return _seed(prefs.current);
  }

  SessionWorkspaceState _seed(ProjectPreferences prefs) {
    // NOTE: workspaceViewIndex is a raw WorkspaceView ordinal persisted to
    // disk, so adding/removing enum values shifts it. A stale index can restore
    // the wrong tab after an upgrade — this bounds check only prevents an
    // out-of-range crash, not a semantic mismatch (e.g. removing "Services"
    // shifted later views down by one with no migration). When Services (or any
    // view) is re-added, remap stored indices in ProjectPreferences.fromJson, or
    // switch to persisting WorkspaceView.name, rather than relying on this
    // guard. The shell clamps again on read for a view this session does not
    // currently OFFER, which is a different question from a valid ordinal.
    final idx = prefs.workspaceViewIndex;
    return SessionWorkspaceState(
      initialized: true,
      selectedView: idx >= 0 && idx < WorkspaceView.values.length
          ? WorkspaceView.values[idx]
          : WorkspaceView.files,
      panelMode: seedablePanelModeName(prefs.panelMode),
      splitRatio: prefs.splitRatio,
    );
  }

  void update(SessionWorkspaceState Function(SessionWorkspaceState) change) {
    state = change(state);
  }
}

final sessionWorkspaceStateProvider =
    NotifierProvider.family<
      SessionWorkspaceController,
      SessionWorkspaceState,
      SessionUiKey
    >(SessionWorkspaceController.new);

final activeSessionUiKeyProvider = Provider<SessionUiKey?>((ref) {
  final entryId = ref.watch(selectedRegistrationIdProvider);
  final sessionId = ref.watch(activeSessionIdProvider);
  if (entryId == null || sessionId == null) return null;
  return (entryId: entryId, sessionId: sessionId);
});

void clearSessionWorkspaceState(
  ProviderContainer ref,
  String entryId,
  String sessionId,
) {
  ref.invalidate(
    sessionWorkspaceStateProvider((entryId: entryId, sessionId: sessionId)),
  );
}
