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
/// stays that way: the fire-and-forget `session:focus` ping is a no-op on the
/// current bridge (`SessionManager.focus`), so the agent's own `lastUsedAt`
/// ordering records ACTIVITY and never learns what the user is looking at.
/// Nothing may re-derive a deliberate focus from that ordering.
final activeSessionIdProvider =
    NotifierProvider<ValueController<String?>, String?>(
      () => ValueController(null),
    );

/// Carries the user's intended active-session id across a project switch
/// initiated by clicking a session row in an inactive panel. Consumed (and
/// cleared) by `_bootstrapSessions` in `workspace_shell.dart` once the new
/// agent's session list lands. Cleared on consumption even if the id is no
/// longer present (the session was deleted on the agent since the cache
/// write).
final pendingActiveSessionIdProvider =
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
/// Must be registered via `ref.listen` in a top-level widget (WorkspaceShell)
/// so it runs for the lifetime of a project open. Not a provider value — just
/// a reusable callback.
void reconcileActiveSession(WidgetRef ref, List<SessionEntry> available) {
  final current = ref.read(activeSessionIdProvider);
  if (current == null) {
    if (available.isNotEmpty) {
      ref.read(activeSessionIdProvider.notifier).set(available.first.id);
    }
    return;
  }
  final stillValid = available.any((s) => s.id == current);
  if (stillValid) return;
  ref
      .read(activeSessionIdProvider.notifier)
      .set(available.isEmpty ? null : available.first.id);
}
