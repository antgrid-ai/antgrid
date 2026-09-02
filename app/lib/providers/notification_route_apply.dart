// app/lib/providers/notification_route_apply.dart
import 'dart:collection';

import 'package:flutter/widgets.dart' show BuildContext;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/session_target.dart';
import '../navigation/nav_controller.dart';
import '../navigation/nav_location.dart';
import '../navigation/notification_route.dart';
import '../navigation/root_navigator.dart';
import '../widgets/drawer_entry_row.dart' show activateDrawerEntryById;
import 'agent_transport.dart';
import 'demo_mode.dart';
import 'device_provisioning.dart';
import 'recent_sessions.dart';
import 'sessions.dart';
import 'ui_attention_providers.dart';
import 'visible_surface.dart';

/// Upper bound on remembered routes. Insertion-ordered eviction, the same shape
/// as WorkspaceShell's notification dedup — this is a duplicate suppressor, not
/// a ledger.
const int _kMaxAppliedRoutes = 128;

/// Routes this container has already applied.
///
/// Deliberately NOT WorkspaceShell's `_notifiedIds`: that set has already
/// consumed every id it surfaced by the time the user can tap the toast, so
/// sharing it would make every tappable notification's id already-present and
/// the tap a permanent no-op. Keys are namespaced for the same reason — the two
/// stores must stay unable to answer for each other even if they ever meet.
class _AppliedRoutes {
  final LinkedHashSet<String> _keys = LinkedHashSet<String>();

  /// True while an apply is between its first read and its last write.
  ///
  /// The dedup only closes IDENTICAL routes, and two different ones overlapping
  /// is what breaks: `activateDrawerEntryById` saves and restores a prior target
  /// around a ~30s cold open, so the second apply's restore hands back a target
  /// the first one had already left — including null, which focuses no project
  /// at all. An 8s toast and a stacked second one make that window ordinary.
  bool inFlight = false;

  /// Records [route] as applied, or returns false when it already was.
  ///
  /// Two keys, because neither alone covers the producers: a sealed push and a
  /// live stream both carry an id worth trusting, but `sourceMessageId` is
  /// nullable by design, and the two iOS cold-start entries can deliver ONE tap
  /// twice as two equal-valued routes.
  bool claim(NotificationRoute route) {
    final keys = _keysOf(route);
    if (keys.any(_keys.contains)) return false;
    for (final key in keys) {
      _keys.add(key);
      if (_keys.length > _kMaxAppliedRoutes) _keys.remove(_keys.first);
    }
    return true;
  }

  /// Forgets a claim that never became a navigation.
  ///
  /// The claim is taken before anything can fail, because it doubles as the
  /// in-flight guard — so every path that ends without moving the user has to
  /// give it back, a THROW included. A burnt claim is permanent: the toast
  /// stays on screen and offering a retry that can only ever return false is
  /// worse than no chip.
  ///
  /// What the retry window actually is: the toast's own duration, and nothing
  /// longer. A failure slower than that — the shape the asleep machine makes,
  /// where `activateDrawerEntryById`'s cold open can outlive the chip — is
  /// refused by [inFlight] rather than retried, because the press that would
  /// retry it arrives while the first attempt is still running. The two
  /// durations are coupled: lengthening the cold-open bound past the toast, or
  /// shortening the toast, moves failures out of the retryable window.
  void release(NotificationRoute route) => _keys.removeAll(_keysOf(route));

  /// The canonical encoding, never `hashCode`: `Object.hash` over six nullable
  /// strings collides, and a collision here is the failure this whole store
  /// exists to remove — the colliding route's chip becomes a permanently dead
  /// no-op, and [release] hands back the other route's claim.
  List<String> _keysOf(NotificationRoute route) {
    final sourceMessageId = route.sourceMessageId;
    return <String>[
      if (sourceMessageId != null) 'route:id:$sourceMessageId',
      'route:value:${encodeNotificationRoute(route)}',
    ];
  }
}

final _appliedRoutesProvider = Provider<_AppliedRoutes>(
  (ref) => _AppliedRoutes(),
);

/// Takes the user to what a tapped notification named. Returns whether the
/// route was applied — false covers both "already applied" and "names nothing
/// this install can address".
///
/// Takes the [ProviderContainer], never a caller's `WidgetRef`: a cross-project
/// route runs `activateDrawerEntryById`, which can spend ~30s opening a cold
/// remote project and tears down the toast that started it on the way. The
/// [context] is optional for the same reason — an OS-level tap has no widget at
/// all — and falls back to the app's root navigator.
Future<bool> applyNotificationRoute(
  BuildContext? context,
  ProviderContainer ref,
  NotificationRoute route,
) async {
  final applied = ref.read(_appliedRoutesProvider);
  // Before anything starts, not after it resolves: `activateDrawerEntryById`
  // saves and restores a prior target around the cold open, so two applies
  // overlapping there restore a stale one. The claim is also the in-flight
  // guard for two DIFFERENT routes, which the dedup cannot see.
  if (applied.inFlight) return false;
  if (!applied.claim(route)) return false;
  applied.inFlight = true;
  try {
    return await _apply(context, ref, route);
  } catch (_) {
    // A throw is a non-success exit like any other, and this one is reachable:
    // `localDeviceUuidProvider` is built to REJECT rather than stall on a
    // keychain read error. The toast runs this call detached, so the throw is
    // only logged — leaving a claim burnt here would make every later press,
    // of this route and of every route equal to it, a silent no-op for the
    // life of the container.
    applied.release(route);
    rethrow;
  } finally {
    applied.inFlight = false;
  }
}

Future<bool> _apply(
  BuildContext? context,
  ProviderContainer ref,
  NotificationRoute route,
) async {
  // The demo's candidate universes are the sample project alone, so a real
  // route resolves to nothing until it is left. Leaving also clears the focused
  // target and the nav history, which is why every read below happens after.
  //
  // Unconditional and deliberate, ahead of every branch that can still return
  // false, so a route that turns out to be unroutable has still ended the demo.
  // That is the acceptable half of the trade: a notification the user tapped is
  // real traffic from a real machine, and the demo is a scope entered and left
  // rather than state worth protecting. Deferring it until a branch is known to
  // navigate is only blocked for the terminalId-only rule, which resolves out of
  // `recentSessionsProvider` and would answer for the sample project — every
  // producer today names a registrationId, which resolves without it.
  if (ref.read(demoModeProvider)) exitDemoMode(ref);

  // `.value` is null on mobile by design — there is no local host there — so
  // the future is what tells locality apart from "not loaded yet".
  final localDeviceUuid = await ref.read(localDeviceUuidProvider.future);

  final loc = resolveNotificationRoute(
    route,
    known: ref.read(recentSessionsProvider),
    localDeviceUuid: localDeviceUuid,
  );
  // Nothing was addressed, so nothing was spent: the Recent rows a terminalId
  // is matched against hydrate asynchronously, and the toast outlives that.
  if (loc == null) {
    ref.read(_appliedRoutesProvider).release(route);
    return false;
  }
  final target = loc.target!;

  if (target != ref.read(selectedTargetProvider)) {
    // The tapped widget is transient — a toast entry, and one this very route
    // tears down — so a dead one falls through to the app's single Navigator,
    // which outlives every route.
    BuildContext? navContext;
    if (context != null && context.mounted) navContext = context;
    navContext ??= ref.read(rootNavigatorKeyProvider).currentContext;
    if (navContext == null) {
      // Nothing can dial the project from here, so the queued state below would
      // be seeded and taken back in the same breath — over whatever another
      // site had already queued.
      ref.read(_appliedRoutesProvider).release(route);
      return false;
    }
    // Checked on the line above, or freshly read off the root navigator key;
    // `activateDrawerEntryById` re-guards each of its own context uses. The lint
    // cannot follow either through the nullable.
    // ignore: use_build_context_synchronously
    return _applyAcrossProjects(navContext, ref, route, loc, target);
  }
  return _applyInFocusedProject(ref, loc);
}

/// The project the route names is not the focused one.
///
/// The session is queued rather than written: the new project's session list
/// has not landed, and `_bootstrapSessions` is what resolves the id against it.
/// The suppression id rides with it — a tap means "show me what happened",
/// never "restart this agent".
Future<bool> _applyAcrossProjects(
  BuildContext navContext,
  ProviderContainer ref,
  NotificationRoute route,
  NavLocation loc,
  SessionTarget target,
) async {
  final sessionId = loc.sessionId;
  // Saved, not assumed absent: another site's queued pick is state this route
  // is borrowing, and an activation that fails owes it back untouched.
  final priorPendingId = ref.read(pendingActiveSessionIdProvider);
  final priorSuppressedId = ref.read(pendingSessionStartSuppressedIdProvider);
  ref.read(pendingActiveSessionIdProvider.notifier).set(sessionId);
  // Names the id it suppresses, so a run that never consumes it leaves a value
  // that answers for nobody rather than a flag that answers for everyone.
  ref.read(pendingSessionStartSuppressedIdProvider.notifier).set(sessionId);

  // A cold remote project needs its machine dialled and promoted before it can
  // be focused, and this is the one path that does that and reports its typed
  // failures.
  bool ok;
  try {
    ok = await activateDrawerEntryById(navContext, ref, target.registrationId);
  } catch (_) {
    // The activation speaks for itself; here it is a route that did not land,
    // and the queued state below must not outlive it.
    ok = false;
  }
  if (!ok) {
    ref.read(pendingActiveSessionIdProvider.notifier).set(priorPendingId);
    ref
        .read(pendingSessionStartSuppressedIdProvider.notifier)
        .set(priorSuppressedId);
    // The machine was asleep or the open was refused; the toast is still up and
    // its retry has to be able to reach here again.
    ref.read(_appliedRoutesProvider).release(route);
    return false;
  }

  ref.read(workbenchSurfaceProvider.notifier).set(WorkbenchSurface.workspace);
  _handOverSurface(ref, loc);
  ref.read(navControllerProvider.notifier).commit(loc);
  return true;
}

/// The project the route names is already focused.
///
/// The session id is written straight through and never queued: nothing would
/// drain a pending id here (the bootstrap's listener returns on an unchanged
/// project), and while one is set `reconcileActiveSession` selects null instead
/// of falling back once the current session leaves the list.
bool _applyInFocusedProject(ProviderContainer ref, NavLocation loc) {
  final sessionId = loc.sessionId;
  // Only ever true for a route that NAMED a session and did not get it. A route
  // that names none is a project destination and keeps its surface.
  var sessionRefused = false;
  if (sessionId != null) {
    ref.read(activeSessionIdProvider.notifier).set(sessionId);
    // Read back: the write is silently refused for a session the bridge is
    // deleting, and revealing that session's surface afterwards would aim the
    // workspace at a transcript nobody is going to be shown.
    //
    // Only that refusal, never a presence test of our own: an id this app does
    // not recognise is written through by design (see [ActiveSessionId]),
    // because the list for a project lands in stages and a guard demanding
    // presence drops every selection made before it does — which is most of
    // them. A session deleted while the toast was up is corrected by
    // [reconcileActiveSession] on the next list change.
    sessionRefused = ref.read(activeSessionIdProvider) != sessionId;
  }
  // Even a route that lost its session still moves the user to the workspace:
  // the project is a real destination, and reporting success from the settings
  // surface without leaving it is the one outcome a tap cannot explain.
  ref.read(workbenchSurfaceProvider.notifier).set(WorkbenchSurface.workspace);
  if (sessionRefused) {
    // No session-scoped reveal, but the peers still get their null write — this
    // destination must not inherit a surface an earlier navigation left
    // pending.
    _clearSurfaceHandovers(ref);
    // Only the SESSION-scoped half of this route was dropped; the project and
    // the workspace surface are still where the user now is, and history has
    // to say so or `back()` re-applies the entry before this one and silently
    // discards the move. Carries the session actually in focus rather than
    // none: that is the true destination, it dedupes to a no-op when the user
    // was already here, and a session-less entry would instead be FILLED by
    // [NavController]'s activeSessionId listener with whatever is selected
    // next.
    ref
        .read(navControllerProvider.notifier)
        .commit(
          NavLocation(
            target: loc.target,
            surface: WorkbenchSurface.workspace,
            sessionId: ref.read(activeSessionIdProvider),
          ),
        );
    return true;
  }
  _handOverSurface(ref, loc);
  ref.read(navControllerProvider.notifier).commit(loc);
  return true;
}

/// Hands the destination surface to WorkspaceShell as pending state.
///
/// Never `revealHandlerTabProvider` / `switchToAgentProvider`: those act on the
/// frame they are called, and the per-session UI restore that a focus change
/// arms re-applies the target session's own saved tab a frame later, silently
/// undoing them. Called AFTER the focus write and stamped with the focus it
/// leaves behind, so a drain running much later can tell it no longer applies.
///
/// Both are written when null too, dropping a value an earlier navigation left
/// pending that this destination must not inherit.
///
/// A route that names no session hands over neither: it asks for a project, and
/// a project opens in the layout its own last session was left in. The drains
/// hold a stamp back until the queued session id resolves, and a session-less
/// route queues none — so a stamp here would be spent on the frame it lands,
/// before the bootstrap's own default pick arms the restore that undoes it.
void _handOverSurface(ProviderContainer ref, NavLocation loc) {
  final target = ref.read(selectedTargetProvider);
  final view = loc.view;
  final agentPage = view == null && loc.sessionId != null;
  ref
      .read(pendingWorkspaceViewProvider.notifier)
      .set(view == null ? null : (target: target, value: view));
  ref
      .read(pendingAgentPageProvider.notifier)
      .set(agentPage ? (target: target, value: true) : null);
}

/// Drops both handovers without naming a destination — the route reached the
/// project but not the session, so it may neither reveal that session's surface
/// nor leave an earlier navigation's pending one to be drained in its place.
void _clearSurfaceHandovers(ProviderContainer ref) {
  ref.read(pendingWorkspaceViewProvider.notifier).set(null);
  ref.read(pendingAgentPageProvider.notifier).set(null);
}
