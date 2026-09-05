import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/session_entry.dart';
import '../services/sessions_service.dart';
import 'agent_transport.dart';
import 'cached_sessions.dart';
import 'providers.dart';
import 'seeded_stream.dart';
import 'value_controller.dart';

/// Streamed view of the agent's session list. Driven by the `SessionsService`
/// state stream (which reflects `session:list:result` snapshots and
/// `session:updated` pushes).
final sessionsStateProvider = StreamProvider<SessionsState>((ref) {
  // Source from the (non-throwing) session, not sessionsServiceProvider: the
  // façade throws while the session resolves, and a `watch` on a throwing sync
  // provider surfaces as an unhandled exception on the next project switch.
  final service = focusedSessionOrNull(ref)?.sessionsService;
  if (service == null) return const Stream<SessionsState>.empty();
  return seededStream(() => service.currentState, service.stateStream);
});

/// [sessionsStateProvider] gated on `state.projectId == selectedRegistrationId`,
/// returning `null` when stale or absent.
///
/// Riverpod retains the previous `AsyncData` while `sessionsStateProvider`
/// re-subscribes after a project switch (the underlying `SessionsService`
/// instance was swapped). Without this guard, `value` would briefly
/// return the previous project's sessions and leak them into every consumer
/// — drawer rows, workspace shell's `reconcileActiveSession`, terminal
/// screen's empty-state CTA. All "for the active project" consumers should
/// read this instead of `sessionsStateProvider` directly.
final freshSessionsStateProvider = Provider<SessionsState?>((ref) {
  final selectedId = ref.watch(selectedRegistrationIdProvider);
  final state = ref.watch(sessionsStateProvider).value;
  if (state == null || state.projectId != selectedId) return null;
  return state;
});

/// All non-archived sessions for the active project, sorted by lastUsedAt desc.
///
/// Sorted here rather than trusted from the wire: the bridge orders its own
/// `session:list`, but this list is also served from the persisted cache, whose
/// order is whatever was written last — and `reconcileActiveSession` picks
/// `first` from it.
final activeSessionsProvider = Provider<List<SessionEntry>>((ref) {
  final state = ref.watch(freshSessionsStateProvider);
  if (state == null) return const [];
  return state.sessions.where((s) => !s.archived).toList()
    ..sort((a, b) => b.lastUsedAt.compareTo(a.lastUsedAt));
});

/// [activeSessionsProvider] minus the sessions the bridge is already removing.
///
/// A deleting session stays VISIBLE in the drawer — that is the whole point of
/// the pending state — but it must never be the selection target. Excluding it
/// here is what stops keystrokes routing into a session whose PTY is being torn
/// down, which surfaced as a run of `Terminal "…" not found for write`.
///
/// [activeSessionsProvider] deliberately stays unfiltered: `_disconnectIfEmpty`
/// reads it, and a project whose only session is mid-delete is not yet empty.
final selectableSessionsProvider = Provider<List<SessionEntry>>((ref) {
  return ref.watch(activeSessionsProvider).where((s) => !s.deleting).toList();
});

/// Archived sessions (for the optional "Archived (n)" expander in the drawer).
final archivedSessionsProvider = Provider<List<SessionEntry>>((ref) {
  final state = ref.watch(freshSessionsStateProvider);
  if (state == null) return const [];
  return state.sessions.where((s) => s.archived).toList();
});

/// Sessions for an arbitrary drawer entry: live snapshot when [entryId] is
/// the focused project, cached otherwise (or while the live stream is still
/// re-subscribing — see [freshSessionsStateProvider]). Returned unfiltered;
/// callers apply their own archived filter.
final sessionsForEntryProvider = Provider.family<List<SessionEntry>, String>((
  ref,
  entryId,
) {
  final fresh = ref.watch(freshSessionsStateProvider);
  if (fresh != null && fresh.projectId == entryId) return fresh.sessions;
  return ref.watch(cachedSessionsProvider(entryId));
});

/// Which session is currently in focus in the workspace. App-local, and it
/// stays that way: the fire-and-forget `session:focus` ping feeds the bridge's
/// READ state only (unread vs done — see `sessionFocus` in work-status.ts) and
/// never `lastUsedAt`, whose ordering records ACTIVITY and so still cannot say
/// what the user is looking at. Nothing may re-derive a deliberate focus from
/// that ordering.
///
/// Declared as the base [ValueController] rather than [ActiveSessionId] so a
/// test can override this with a pre-seeded controller; [ActiveSessionId.set]
/// is virtual, so production still gets the guard either way.
final activeSessionIdProvider =
    NotifierProvider<ValueController<String?>, String?>(ActiveSessionId.new);

/// The active-session id, refusing any session the bridge is already deleting.
///
/// The guard lives on the WRITE rather than at the call sites because there are
/// eight of them and only some are reachable from a drawer row: a Back press
/// replaying nav history, a deep link naming the session, and the handler
/// screen's in-session escalation all write the id directly.
/// [reconcileActiveSession] cannot cover those — it is registered on
/// [selectableSessionsProvider], so it fires when the LIST changes, and an
/// id-only write into an unchanged list never wakes it.
///
/// Only a session this app can SEE as deleting is refused; an id it does not
/// recognise is written through untouched. That is the ordinary bootstrap case
/// — the id is chosen before the project's session list has landed — and a
/// guard demanding presence would drop every one of those.
///
/// Keyed on the wire flag alone, never the app-local mark: that mark is armed
/// on the user's confirm, and the bridge can still refuse the delete at its
/// preflight, so letting it drive selection would step off a session that is
/// not being deleted while the user is still answering the second dialog.
class ActiveSessionId extends ValueController<String?> {
  ActiveSessionId() : super(null);

  @override
  void set(String? value) {
    if (value != null) {
      for (final s
          in ref.read(freshSessionsStateProvider)?.sessions ??
              const <SessionEntry>[]) {
        if (s.id == value && s.deleting) return;
      }
    }
    super.set(value);
  }
}

/// Carries the user's intended active-session id across a project switch
/// initiated by clicking a session row in an inactive panel. Consumed (and
/// cleared) by `_bootstrapSessions` in `workspace_shell.dart` once the new
/// agent's session list lands. Cleared on consumption even if the id is no
/// longer present (the session was deleted on the agent since the cache
/// write).
///
/// While set it is the answer to "what is selected", not a hint: every default
/// pick — [reconcileActiveSession]'s `first`, the nav layer's session-less
/// entry, the explorer's checkout — defers to it, because the list it will be
/// resolved against lands in stages (persisted cache, then the wire) and a
/// default taken from an early stage is a visible wrong session.
final pendingActiveSessionIdProvider =
    NotifierProvider<ValueController<String?>, String?>(
      () => ValueController(null),
    );

/// The queued session id whose auto-start [pendingActiveSessionIdProvider]'s
/// drain must skip, or null.
///
/// The drain starts a stopped session and speaks its refusal
/// (`_bootstrapSessions` in workspace_shell.dart) because a Recent-list tap
/// means "resume this". A notification tap means "show me what happened":
/// restarting an agent the user let finish spends tokens nobody asked for.
///
/// Holds the ID rather than a bare flag, and the drain only honours it when it
/// EQUALS the id being resolved. Five other sites queue a pending id without
/// knowing this provider exists, and the bootstrap has early returns past the
/// point one is set — a flag surviving any of those would silently suppress an
/// unrelated later Recent-list tap's resume, which is the one thing that tap
/// means.
///
/// What that buys, precisely: a leftover value can only ever answer for a
/// PAIR that survived together — this provider and the pending id both left
/// set by a run that returned early, or both left by the three sites that null
/// the pending id on a failed activation without seeing this one. A pair like
/// that eats one auto-start: the Recent-list tap on that same session, or the
/// default pick the bootstrap falls through to when that session is gone from
/// the list. One tap, self-clearing on the next drain — the price of keeping
/// those five sites ignorant of this provider, which is what makes them safe.
final pendingSessionStartSuppressedIdProvider =
    NotifierProvider<ValueController<String?>, String?>(
      () => ValueController(null),
    );

/// The currently focused session entry, or null if none.
final activeSessionProvider = Provider<SessionEntry?>((ref) {
  final id = ref.watch(activeSessionIdProvider);
  if (id == null) return null;
  final state = ref.watch(freshSessionsStateProvider);
  if (state == null) return null;
  for (final s in state.sessions) {
    if (s.id == id) return s;
  }
  return null;
});

/// The focused session's row, falling back to the persisted cache while the
/// live stream is absent or re-subscribing (see [freshSessionsStateProvider],
/// which reports null through that whole window).
///
/// **Read only fields that are fixed for the life of a session** — id, mode,
/// checkoutId, tool. The cache loads `running` as false and carries no work
/// status, so anything branching on live state must keep using
/// [activeSessionProvider] and treat null as "not known yet".
final activeSessionOrCachedProvider = Provider<SessionEntry?>((ref) {
  final fresh = ref.watch(activeSessionProvider);
  if (fresh != null) return fresh;
  final id = ref.watch(activeSessionIdProvider);
  final entryId = ref.watch(selectedRegistrationIdProvider);
  if (id == null || entryId == null) return null;
  for (final s in ref.watch(sessionsForEntryProvider(entryId))) {
    if (s.id == id) return s;
  }
  return null;
});

/// Filesystem checkout currently represented by the active session. Old or
/// not-yet-decoded sessions remain safely bound to main.
///
/// Resolved through [activeSessionOrCachedProvider] because the fallback is not
/// neutral: every checkout-scoped service (files, tree, search, git, commands,
/// terminals) routes off this, so answering `main` for an isolated session
/// while its row re-resolves points the whole workspace at the wrong worktree.
/// A checkout binding never changes for a given session, so the cached row is
/// as good as the live one here.
final focusedCheckoutIdProvider = Provider<String>((ref) {
  return ref.watch(activeSessionOrCachedProvider)?.checkoutId ?? 'main';
});

/// Side-effect listener: keep `activeSessionIdProvider` valid as the session
/// list churns. If the active session is deleted or archived, advance to the
/// most-recently-used non-archived sibling. If the list is empty, clear the
/// active id so the workspace falls back to the "+ new session" empty state.
///
/// Fed [selectableSessionsProvider], so the advance fires the moment the
/// `deleting` flag ARRIVES rather than at the very end of a 3–15s delete when
/// the list identity finally changes. The bridge only sets that flag past its
/// preflight, so a delete that is still refusable can never navigate.
///
/// Must be registered via `ref.listen` in a top-level widget (WorkspaceShell)
/// so it runs for the lifetime of a project open. Not a provider value — just
/// a reusable callback.
void reconcileActiveSession(WidgetRef ref, List<SessionEntry> available) {
  final current = ref.read(activeSessionIdProvider);
  if (current != null && available.any((s) => s.id == current)) return;

  // A queued deliberate pick outranks `first`. The first list a project switch
  // delivers is the persisted cache, seeded the instant its SessionsService
  // constructs — long before `_bootstrapSessions` gets its `session:list`
  // reply back over the wire (seconds, on a relay). Taking `first` here
  // renders that session in full, and the bootstrap then visibly switches
  // away from it. If the queued id is in this list, it IS the selection; if it
  // is not yet (a session the cache predates), select nothing rather than
  // something the user did not ask for — the bootstrap resolves it against the
  // live list and falls back itself when the id turns out stale.
  final pending = ref.read(pendingActiveSessionIdProvider);
  final String? next;
  if (pending != null) {
    next = available.any((s) => s.id == pending) ? pending : null;
  } else {
    next = available.isEmpty ? null : available.first.id;
  }
  if (next != current) ref.read(activeSessionIdProvider.notifier).set(next);
}
