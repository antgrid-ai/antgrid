// app/lib/navigation/nav_controller.dart
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/agent_transport.dart';
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
  /// re-taps).
  void commit(NavLocation loc) {
    if (_namesCurrentDestination(loc)) return;
    final past = state.current == null
        ? <NavLocation>[]
        : [...state.past, state.current!];
    final capped = past.length > kNavHistoryCap
        ? past.sublist(past.length - kNavHistoryCap)
        : past;
    state = NavState(past: capped, current: loc, future: const []);
  }

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

final navControllerProvider = NotifierProvider<NavController, NavState>(
  NavController.new,
);
