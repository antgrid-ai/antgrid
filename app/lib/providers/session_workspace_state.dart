import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/preferences_models.dart';
import '../models/workspace_view.dart';
import '../storage/session_layout_store.dart';
import '../util/detached.dart';
import 'agent_transport.dart';
import 'providers.dart';
import 'sessions.dart';

/// Overridden in `main()` with the opened store. The default remembers for the
/// launch and persists nothing — see [SessionLayoutStore.inMemory] for why this
/// one degrades where the other stores throw.
final sessionLayoutStoreProvider = Provider<SessionLayoutStore>(
  (_) => SessionLayoutStore.inMemory(),
);

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

  /// Value equality is LOAD-BEARING, not a convenience: Riverpod notifies on
  /// `previous != next`, so without it every `update` — including one that
  /// re-publishes the value already there — wakes every listener. `_buildMobile`
  /// re-publishes `mobilePage` from an unconditional post-frame callback and
  /// `WorkspaceShellState._syncSessionUi` watches this provider, which together
  /// is a rebuild that schedules its own next rebuild, forever.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionWorkspaceState &&
          other.initialized == initialized &&
          other.selectedView == selectedView &&
          other.panelMode == panelMode &&
          other.splitRatio == splitRatio &&
          other.mobilePage == mobilePage &&
          other.tabletContextOpen == tabletContextOpen &&
          other.tabletContextExpanded == tabletContextExpanded &&
          other.pinnedTerminalId == pinnedTerminalId &&
          other.pushedTerminalId == pushedTerminalId;

  @override
  int get hashCode => Object.hash(
    initialized,
    selectedView,
    panelMode,
    splitRatio,
    mobilePage,
    tabletContextOpen,
    tabletContextExpanded,
    pinnedTerminalId,
    pushedTerminalId,
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
    _store = ref.read(sessionLayoutStoreProvider);
    // What this session was last left at OUTRANKS the project seed, and needs
    // no project load to answer — so a restart restores the real layout on the
    // first frame rather than flashing the project default first.
    final remembered = _store.read(key.entryId, key.sessionId);
    if (remembered != null) return _restore(remembered);

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

  late SessionLayoutStore _store;

  /// A layout this session was left at on a previous launch. Only the fields
  /// the user arranged are stored, so everything else takes its default — see
  /// [SessionLayout].
  SessionWorkspaceState _restore(SessionLayout layout) {
    final idx = layout.workspaceViewIndex;
    return SessionWorkspaceState(
      initialized: true,
      selectedView: idx != null && idx >= 0 && idx < WorkspaceView.values.length
          ? WorkspaceView.values[idx]
          : WorkspaceView.files,
      // Not downgraded on the way out: `contextExpanded` is refused as an
      // INHERITED default, but this is the session that chose it, coming back
      // to the layout it was left in.
      panelMode: layout.panelMode,
      splitRatio: layout.splitRatio,
    );
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
    final next = change(state);
    final persistable = _layoutOf(next);
    final changed = persistable != _layoutOf(state);
    state = next;
    // A terminal pin or a mobile page turn moves `state` without moving
    // anything persisted; writing on every update would rewrite the whole map
    // for changes this store does not hold.
    if (!changed) return;
    // Fire-and-forget through `detached`: `update` is called from `setState`
    // bodies and tap handlers, which discard the future, so a rejected write
    // would otherwise reach PlatformDispatcher.onError as a fatal with no
    // in-app frames to point at.
    detached(
      'SessionWorkspaceController',
      'session layout write failed',
      () => _store.write(key.entryId, key.sessionId, persistable),
    );
  }

  static SessionLayout _layoutOf(SessionWorkspaceState s) => SessionLayout(
    panelMode: s.panelMode,
    splitRatio: s.splitRatio,
    workspaceViewIndex: s.selectedView.index,
  );
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
  // The session is gone, so its remembered layout names nothing and nothing
  // else will ever prune it — this is the only bound on the store other than
  // its cap.
  final store = ref.read(sessionLayoutStoreProvider);
  detached(
    'clearSessionWorkspaceState',
    'session layout forget failed',
    () => store.forget(entryId, sessionId),
  );
}
