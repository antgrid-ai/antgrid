// app/lib/navigation/nav_controller.dart
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/agent_transport.dart';
import '../providers/new_session_picker.dart';
import '../providers/sessions.dart';
import '../providers/ui_attention_providers.dart';
import '../providers/visible_surface.dart';
import 'nav_location.dart';

/// Upper bound on retained history entries. Oldest `past` entries are dropped
/// past this; back/forward are within-session affordances, not an audit log.
const int kNavHistoryCap = 50;

@immutable
class NavState {
  final List<NavLocation> past; // oldest -> newest
  final NavLocation? current;
  final List<NavLocation> future; // for redo after back()

  const NavState({this.past = const [], this.current, this.future = const []});

  NavState copyWith({
    List<NavLocation>? past,
    NavLocation? current,
    List<NavLocation>? future,
  }) => NavState(
    past: past ?? this.past,
    current: current ?? this.current,
    future: future ?? this.future,
  );

  bool get canBack => past.isNotEmpty;
  bool get canForward => future.isNotEmpty;
}

class NavController extends Notifier<NavState> {
  @override
  NavState build() {
    // Fill the CURRENT entry's session ONLY when it has none yet — the
    // post-switch async-resolution case `commit` records as null (the project's
    // active session is chosen later by _bootstrapSessions). This edits current
    // only — never pushes/pops, so system-driven session changes can't pollute
    // history.
    //
    // The `cur.sessionId != null` guard is load-bearing: a same-project session
    // tap sets activeSessionIdProvider BEFORE its session-switch `commit` runs
    // (session_row's _activate → _showFocusedSessionSurface). If this listener
    // overwrote a session already present, that commit's location would equal
    // `current` and dedupe to a no-op — losing the session-switch history entry
    // and the spec's "each session switch = an entry" guarantee. We only ever
    // FILL a null, never overwrite or clear.
    ref.listen<String?>(activeSessionIdProvider, (_, next) {
      final cur = state.current;
      if (cur == null || cur.sessionId != null || next == null) return;
      state = state.copyWith(current: cur.copyWith(sessionId: next));
    });
    return const NavState();
  }

  /// Record-only: the calling user-intent site has already written the
  /// underlying providers; this just appends to history. No-op when [loc] names
  /// the destination history is already at (avoids duplicate entries on
  /// re-taps). An earlier entry for the same destination is dropped, so
  /// bouncing between sessions leaves each one in `past` once and back() never
  /// walks the same place twice.
  void commit(NavLocation loc) {
    if (_namesCurrentDestination(loc)) return;
    final trail = state.current == null
        ? <NavLocation>[]
        : [...state.past, state.current!];
    final past = _isPlainLocation(loc)
        ? [
            for (final entry in trail)
              if (!(_isPlainLocation(entry) && _sameDestination(entry, loc)))
                entry,
          ]
        : trail;
    final capped = past.length > kNavHistoryCap
        ? past.sublist(past.length - kNavHistoryCap)
        : past;
    state = NavState(past: capped, current: loc, future: const []);
  }

  /// A location that asks for nothing beyond its destination — see
  /// [_namesCurrentDestination] for why the others are distinct requests.
  bool _isPlainLocation(NavLocation loc) =>
      loc.view == null && loc.settingsSection == null && loc.file == null;

  bool _sameDestination(NavLocation a, NavLocation b) =>
      a.target == b.target &&
      a.surface == b.surface &&
      a.sessionId == b.sessionId;

  /// Whether [loc] is the place `current` already is.
  ///
  /// The dedupe keys on target/surface/sessionId, not on the whole location:
  /// view/settingsSection/file are things a link ASKS FOR at a destination, and
  /// only the deep-link codec ever sets them. Comparing them would let one link
  /// carrying a view turn every later re-tap of the same session into a
  /// duplicate entry that back() then answers by re-applying the view. A
  /// location that itself names one is a distinct request and always records.
  bool _namesCurrentDestination(NavLocation loc) {
    final cur = state.current;
    if (cur == null) return false;
    if (loc.view != null || loc.settingsSection != null || loc.file != null) {
      return cur == loc;
    }
    return cur.target == loc.target &&
        cur.surface == loc.surface &&
        cur.sessionId == loc.sessionId;
  }

  /// Records the place the app opened on as `current`, so the first navigation
  /// after launch has somewhere for back() to return to.
  ///
  /// Called by the shell once it is up, never from [build]: the controller is
  /// first read by whichever site navigates first, which has already written
  /// the providers this snapshots — the landing taken there would be the
  /// destination. A no-op once anything is recorded: a link that landed first
  /// already is where the app opened.
  void recordLanding() {
    if (state.current != null) return;
    final target = ref.read(selectedTargetProvider);
    final surface = ref.read(workbenchSurfaceProvider);
    state = NavState(
      current: NavLocation(
        target: target,
        // With nothing focused AppShell renders New session over a surface
        // that still reads its `workspace` default, and only rewrites it a
        // frame later. Record the screen the user is looking at.
        surface:
            target == null &&
                (surface == WorkbenchSurface.workspace ||
                    surface == WorkbenchSurface.remoteDevices)
            ? WorkbenchSurface.newSession
            : surface,
        sessionId: ref.read(activeSessionIdProvider),
      ),
    );
  }

  /// Steps back to the newest entry that is not on [surface], in one move, so
  /// closing an overlay returns to whatever it was opened over rather than to
  /// a fixed screen. The overlay entries skipped over go to `future` with it,
  /// so forward() reopens the overlay.
  ///
  /// False when `current` is not on [surface] or nothing before it is
  /// elsewhere (the overlay was the first thing recorded, e.g. a cold-start
  /// link) — the caller picks the destination then.
  bool backOutOf(WorkbenchSurface surface) {
    final cur = state.current;
    if (cur == null || cur.surface != surface) return false;
    final i = state.past.lastIndexWhere((e) => e.surface != surface);
    if (i < 0) return false;
    final dest = state.past[i];
    state = NavState(
      past: state.past.sublist(0, i),
      current: dest,
      future: [...state.past.sublist(i + 1), cur, ...state.future],
    );
    _apply(dest);
    return true;
  }

  /// Drop the whole history, at both edges of a scope that is entered and left
  /// rather than navigated through. The demo is the one such scope: its entries
  /// name a project that does not exist outside it, and the real app's entries
  /// name machines that must not be reachable from inside it.
  void reset() => state = const NavState();

  void back() {
    if (!state.canBack) return;
    final prev = state.past.last;
    state = NavState(
      past: state.past.sublist(0, state.past.length - 1),
      current: prev,
      future: [state.current!, ...state.future],
    );
    _apply(prev);
  }

  void forward() {
    if (!state.canForward) return;
    final next = state.future.first;
    state = NavState(
      past: [...state.past, state.current!],
      current: next,
      future: state.future.sublist(1),
    );
    _apply(next);
  }

  /// Apply a deep-linked location: write the providers AND record history.
  /// (User-intent in-app sites instead write providers themselves + call
  /// [commit]; a deep link has no such site, so it must do both.)
  void applyDeepLink(NavLocation loc) {
    _apply(loc);
    // A link naming a session and no tab asks for that session's conversation,
    // as a notification route of the same shape does (`_handOverSurface`).
    // Not in [_apply]: back()/forward() mean "as I left it", which is the
    // session's own restored page. Session-less links get no stamp — nothing
    // queued holds the drain back, so it would be spent before the bootstrap's
    // default pick restores that session's layout over it.
    if (loc.surface == WorkbenchSurface.workspace &&
        loc.target != null &&
        loc.sessionId != null &&
        loc.view == null &&
        loc.file == null) {
      ref
          .read(pendingAgentPageProvider.notifier)
          .set((target: ref.read(selectedTargetProvider), value: true));
    }
    // The composer's draft target is not focus, so focusing the project alone
    // leaves New session on "Select project…". A link naming a project is a
    // pick, so it retargets a draft left on another one — the same rule as a
    // drawer row's `+`. Not in [_apply] either: back()/forward() return to a
    // draft the user may have edited since, which keeps its own target.
    if (loc.surface == WorkbenchSurface.newSession && loc.target != null) {
      seedNewSessionDraftFromFocus(ref.container, retarget: true);
    }
    commit(loc);
  }

  /// The ONLY path that writes the nav providers during navigation. User-intent
  /// sites do their own writes + call [commit]; back/forward call this.
  void _apply(NavLocation loc) {
    ref.read(workbenchSurfaceProvider.notifier).set(loc.surface);

    final currentTarget = ref.read(selectedTargetProvider);
    if (loc.target != null && loc.target != currentTarget) {
      ref.read(selectedTargetProvider.notifier).set(loc.target);
      // Project switch: hand the session to _bootstrapSessions to resolve once
      // the new project's session list lands (workspace_shell.dart drains it).
      // Writing loc.sessionId (possibly null) both seeds the pending id AND
      // clears any stale pending from an earlier switch, so the new project's
      // bootstrap can't consume a session id meant for a different project.
      ref.read(pendingActiveSessionIdProvider.notifier).set(loc.sessionId);
      // Cleared with the id it qualifies, never left behind: back()/forward()
      // and a deep link all mean "resume this", and a suppressor outliving the
      // queue it was written for would silently re-pair with a later
      // Recent-list tap on the same session and eat the start that tap IS.
      ref.read(pendingSessionStartSuppressedIdProvider.notifier).set(null);
    } else if (loc.target == currentTarget && loc.sessionId != null) {
      // Same project: bootstrap won't re-run, so select directly.
      ref.read(activeSessionIdProvider.notifier).set(loc.sessionId);
    }
    // A null target is a surface-only location (e.g. a `nav/settings` deep
    // link). It overlays whatever project is focused and must NOT deselect it,
    // so we never write selectedTargetProvider in that case.

    // The rest of the location is handed to its destination screen as pending
    // state instead of called from here: none of those screens is guaranteed
    // mounted (a link can land at launch, and the FileService behind one of them
    // does not exist until the project's session finishes constructing), and the
    // shell's reveal callback is null on mobile regardless.
    //
    // AFTER the focus write above, and stamped with the focus it leaves behind,
    // because both halves are read by the drains: a drain that runs off one of
    // these writes must see the project the location names, and one that runs
    // much later must be able to tell that it no longer does.
    //
    // Each is written when null too — that drops a value left pending by an
    // earlier location, which this destination must not inherit. Unconditional,
    // unlike the session id above, because a link may name a tab or a file in
    // the project that is already focused.
    final pendingTarget = ref.read(selectedTargetProvider);
    ref
        .read(pendingWorkspaceViewProvider.notifier)
        .set(
          loc.view == null ? null : (target: pendingTarget, value: loc.view!),
        );
    ref
        .read(pendingSettingsSectionProvider.notifier)
        .set(
          loc.settingsSection == null
              ? null
              : (target: pendingTarget, value: loc.settingsSection!),
        );
    ref
        .read(pendingFilePathProvider.notifier)
        .set(
          loc.file == null ? null : (target: pendingTarget, value: loc.file!),
        );
    // A [NavLocation] can never ASK for the agent transcript — there is no
    // WorkspaceView for it — so this is only ever the null half. It belongs
    // here all the same: the drains run in one post-frame callback with this
    // one last, so a stamp an earlier location left would otherwise override
    // the tab a back()/forward()/deep link just named.
    ref.read(pendingAgentPageProvider.notifier).set(null);
  }
}

/// Records the just-focused project as a workspace history entry from a
/// user-intent project-switch site. The single home for the rule every such
/// site must follow: skip while a cross-project session activation is in flight
/// (pendingActiveSessionId set), because _bootstrapSessions will resolve the
/// session and session_row records the precise entry — a session-less commit
/// here would double-record one tap and strand a phantom entry back() lands on.
/// Reads the already-written [selectedTargetProvider], so call AFTER the focus
/// write.
///
/// Takes the container, not a `WidgetRef`: every caller reaches here after an
/// await, by which point the row that started the activation may be gone.
void recordProjectFocus(ProviderContainer ref) {
  if (ref.read(pendingActiveSessionIdProvider) != null) return;
  ref
      .read(navControllerProvider.notifier)
      .commit(
        NavLocation(
          target: ref.read(selectedTargetProvider),
          surface: WorkbenchSurface.workspace,
        ),
      );
}

/// Closes App settings back to the place it was opened over — Memory, the
/// Scheduler, a session — via [NavController.backOutOf].
///
/// The fallback, for settings that history cannot see past, records the surface
/// actually landed on: AppShell's reconciler forces newSession straight back on
/// when no project is focused. Without a commit there `current` would still
/// name settings, and the next back press would be a silent no-op.
void closeAppSettings(ProviderContainer ref) {
  final nav = ref.read(navControllerProvider.notifier);
  if (nav.backOutOf(WorkbenchSurface.appSettings)) return;
  ref.read(workbenchSurfaceProvider.notifier).set(WorkbenchSurface.workspace);
  final target = ref.read(selectedTargetProvider);
  nav.commit(
    NavLocation(
      target: target,
      surface: target == null
          ? WorkbenchSurface.newSession
          : WorkbenchSurface.workspace,
      sessionId: ref.read(activeSessionIdProvider),
    ),
  );
}

final navControllerProvider = NotifierProvider<NavController, NavState>(
  NavController.new,
);
